import Foundation

/// HTTP client for the Pangram v3 synchronous detection endpoint.
/// Enforces a concurrency cap and a token-bucket rate limit so continuous
/// scanning can never stampede the (paid) API.
public actor PangramClient: AIDetector {
    public static let endpoint = URL(string: "https://text.api.pangram.com/v3")!

    private let apiKeyProvider: @Sendable () -> String?
    private let session: URLSession

    private let maxConcurrent: Int
    private var inFlight = 0

    private var tokens: Double
    private let bucketCapacity: Double
    private var refillPerSecond: Double
    private let normalRefillPerSecond: Double
    private var lastRefill: Date
    private var throttledUntil: Date?

    public init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        maxConcurrent: Int = 5,
        requestsPerMinute: Double = 20
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.maxConcurrent = maxConcurrent
        // Burst half a minute's allowance at once: a fresh page with several
        // passages scores in one parallel wave instead of serializing.
        self.bucketCapacity = requestsPerMinute / 2
        self.tokens = requestsPerMinute / 2
        self.normalRefillPerSecond = requestsPerMinute / 60
        self.refillPerSecond = requestsPerMinute / 60
        self.lastRefill = Date()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    public func detect(_ text: String) async throws -> DetectionResult {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw DetectorError.missingAPIKey
        }
        try await acquireSlot()
        defer { releaseSlot() }

        var lastError: Error = DetectorError.badResponse
        for attempt in 0..<3 {
            do {
                return try await performRequest(text: text, key: key)
            } catch DetectorError.rateLimited {
                // Halve the refill rate for 5 minutes, then back off and retry.
                refillPerSecond = normalRefillPerSecond / 2
                throttledUntil = Date().addingTimeInterval(300)
                lastError = DetectorError.rateLimited
                try await Task.sleep(nanoseconds: UInt64(Double(1 << (attempt + 1)) * 1e9
                    + Double.random(in: 0...0.5) * 1e9))
            } catch DetectorError.server(let code) {
                lastError = DetectorError.server(code)
                try await Task.sleep(nanoseconds: UInt64(Double(1 << attempt) * 1e9))
            } catch let error as DetectorError {
                throw error  // 401/402/etc: no retry
            } catch {
                lastError = DetectorError.network(error.localizedDescription)
                try await Task.sleep(nanoseconds: UInt64(Double(1 << attempt) * 1e9))
            }
        }
        throw lastError
    }

    private func performRequest(text: String, key: String) async throws -> DetectionResult {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONEncoder().encode(["text": text])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DetectorError.badResponse
        }
        switch http.statusCode {
        case 200:
            guard let parsed = try? JSONDecoder().decode(PangramResponse.self, from: data) else {
                throw DetectorError.badResponse
            }
            return DetectionResult(
                aiLikelihood: parsed.aiLikelihood,
                prediction: parsed.prediction,
                requestID: nil
            )
        case 401, 403: throw DetectorError.invalidAPIKey
        case 402: throw DetectorError.outOfCredits
        case 429: throw DetectorError.rateLimited
        case 500...599: throw DetectorError.server(http.statusCode)
        default: throw DetectorError.server(http.statusCode)
        }
    }

    // MARK: - Concurrency + rate limiting

    private func acquireSlot() async throws {
        while true {
            refillTokens()
            if inFlight < maxConcurrent, tokens >= 1 {
                inFlight += 1
                tokens -= 1
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
        }
    }

    private func releaseSlot() {
        inFlight -= 1
    }

    private func refillTokens() {
        let now = Date()
        if let until = throttledUntil, now >= until {
            throttledUntil = nil
            refillPerSecond = normalRefillPerSecond
        }
        tokens = min(bucketCapacity, tokens + now.timeIntervalSince(lastRefill) * refillPerSecond)
        lastRefill = now
    }
}
