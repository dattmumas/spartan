import Foundation
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable {
    case highlight = "Highlight"
    case block = "Block out"
    var id: String { rawValue }
}

enum ScanMode: String, CaseIterable, Identifiable {
    case continuous = "Continuous"
    case selection = "Selection"
    var id: String { rawValue }
}

struct ScanLogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let preview: String
    let words: Int
    let score: Double?
    let source: String  // "api" | "cache" | "fuzzy" | "error" | "info"
}

@MainActor
final class AppState: ObservableObject {
    @Published var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold") }
    }
    @Published var mode: DisplayMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var scanMode: ScanMode {
        didSet { UserDefaults.standard.set(scanMode.rawValue, forKey: "scanMode") }
    }
    @Published var paused = false
    @Published var statusText = "Starting…"
    @Published var hasScreenPermission = false
    @Published var axTrusted = false
    @Published var apiKeyPresent = false
    @Published var lastError: String?
    @Published var requestsToday: Int {
        didSet { persistDailyCount() }
    }
    @Published var log: [ScanLogEntry] = []

    let dailyCap = 500

    init() {
        let defaults = UserDefaults.standard
        threshold = defaults.object(forKey: "threshold") as? Double ?? 0.7
        mode = DisplayMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .highlight
        scanMode = ScanMode(rawValue: defaults.string(forKey: "scanMode") ?? "") ?? .continuous

        let today = Self.dayStamp()
        if defaults.string(forKey: "requestsDay") == today {
            requestsToday = defaults.integer(forKey: "requestsCount")
        } else {
            requestsToday = 0
        }
        apiKeyPresent = KeychainStore.apiKey() != nil
    }

    func addLog(_ entry: ScanLogEntry) {
        log.insert(entry, at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }

    private func persistDailyCount() {
        let defaults = UserDefaults.standard
        defaults.set(Self.dayStamp(), forKey: "requestsDay")
        defaults.set(requestsToday, forKey: "requestsCount")
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
