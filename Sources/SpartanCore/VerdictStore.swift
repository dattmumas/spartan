import Foundation

public struct VerdictRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let appName: String
    public let source: String          // "continuous" | "selection" | "document"
    public let passageHash: String
    public let text: String
    public let words: Int
    public let score: Double
    public let headline: String?
    public let lowConfidence: Bool
    /// Filename under `<store>/shots/`, or nil if no screenshot was captured.
    public let screenshotFile: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        appName: String,
        source: String,
        passageHash: String,
        text: String,
        words: Int,
        score: Double,
        headline: String?,
        lowConfidence: Bool,
        screenshotFile: String? = nil
    ) {
        self.id = id
        self.date = date
        self.appName = appName
        self.source = source
        self.passageHash = passageHash
        self.text = text
        self.words = words
        self.score = score
        self.headline = headline
        self.lowConfidence = lowConfidence
        self.screenshotFile = screenshotFile
    }
}

/// Append-only verdict history on disk: one JSONL file per calendar day in
/// `directory/`, with optional PNGs in `directory/shots/`. Same-day duplicates
/// (same `passageHash`) are silently skipped so re-scrolling doesn't bloat the
/// log. Reads parse files newest-first up to a caller-supplied limit.
public actor VerdictStore {
    private let directory: URL
    private let shotsDirectory: URL
    private var todaySeen: Set<String> = []
    private var todayKey: String = ""

    public init(directory: URL) {
        self.directory = directory
        self.shotsDirectory = directory.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: shotsDirectory, withIntermediateDirectories: true
        )
    }

    /// Returns whether the record was actually written (false = same-day dup).
    /// When `screenshot` is non-nil, the bytes are saved as
    /// `shots/<record.id>.png` and the stored record's `screenshotFile` is set
    /// to that filename regardless of what the caller supplied.
    @discardableResult
    public func append(_ record: VerdictRecord, screenshot: Data?) -> Bool {
        let day = Self.dayString(record.date)
        refreshDayIndex(for: day)
        let key = record.passageHash + "|" + day
        if todaySeen.contains(key) { return false }
        todaySeen.insert(key)

        var stored = record
        if let screenshot {
            let filename = "\(record.id.uuidString).png"
            let url = shotsDirectory.appendingPathComponent(filename)
            try? screenshot.write(to: url)
            stored = VerdictRecord(
                id: record.id, date: record.date, appName: record.appName,
                source: record.source, passageHash: record.passageHash,
                text: record.text, words: record.words, score: record.score,
                headline: record.headline, lowConfidence: record.lowConfidence,
                screenshotFile: filename
            )
        }

        guard let data = try? Self.encoder.encode(stored) else { return false }
        var line = data
        line.append(0x0A)  // newline-delimited JSON
        let fileURL = directory.appendingPathComponent("\(day).jsonl")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL, options: .atomic)
        }
        return true
    }

    /// Newest-first up to `limit`.
    public func recent(limit: Int) -> [VerdictRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
        let jsonl = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var out: [VerdictRecord] = []
        for file in jsonl {
            guard let data = try? Data(contentsOf: file) else { continue }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            // Reverse: newest within a day is the last line written.
            for line in lines.reversed() {
                if let record = try? Self.decoder.decode(VerdictRecord.self, from: Data(line)) {
                    out.append(record)
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    /// Deletes `*.jsonl` files whose date is older than `olderThanDays` and
    /// their associated screenshots.
    public func purge(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let cutoffString = Self.dayString(cutoff)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem < cutoffString else { continue }
            if let data = try? Data(contentsOf: file) {
                let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
                for line in lines {
                    if let record = try? Self.decoder.decode(VerdictRecord.self, from: Data(line)),
                       let shot = record.screenshotFile {
                        try? FileManager.default.removeItem(
                            at: shotsDirectory.appendingPathComponent(shot)
                        )
                    }
                }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func url(forScreenshot record: VerdictRecord) -> URL? {
        guard let file = record.screenshotFile else { return nil }
        let url = shotsDirectory.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public nonisolated func csv(records: [VerdictRecord]) -> String {
        var out = "date,app,source,words,score,headline,lowConfidence,text\n"
        let f = ISO8601DateFormatter()
        for r in records {
            out += [
                f.string(from: r.date),
                Self.csvEscape(r.appName),
                r.source,
                String(r.words),
                String(format: "%.4f", r.score),
                Self.csvEscape(r.headline ?? ""),
                r.lowConfidence ? "true" : "false",
                Self.csvEscape(r.text),
            ].joined(separator: ",") + "\n"
        }
        return out
    }

    public static func csvEscape(_ s: String) -> String {
        let needsQuoting = s.contains(",") || s.contains("\"") || s.contains("\n")
        let clean = s.replacingOccurrences(of: "\n", with: " ")
        if !needsQuoting { return clean }
        return "\"\(clean.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func refreshDayIndex(for day: String) {
        guard day != todayKey else { return }
        todayKey = day
        todaySeen.removeAll()
        let fileURL = directory.appendingPathComponent("\(day).jsonl")
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines {
            if let r = try? Self.decoder.decode(VerdictRecord.self, from: Data(line)) {
                todaySeen.insert(r.passageHash + "|" + day)
            }
        }
    }

    /// The canonical calendar-day key (fixed POSIX locale/Gregorian rendering
    /// so day boundaries agree everywhere: history filenames, dedupe keys,
    /// and the daily request counter).
    public static func dayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
