import Foundation
import SwiftUI
import SpartanCore

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

struct CurrentApp: Equatable {
    let name: String
    let bundleID: String
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

    /// Frontmost app right now (drives the "Exclude X" button), not persisted.
    @Published var currentApp: CurrentApp?
    @Published var excludedBundleIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(excludedBundleIDs), forKey: "excludedApps")
        }
    }
    @Published var dailyCap: Int {
        didSet { UserDefaults.standard.set(dailyCap, forKey: "dailyCap") }
    }
    @Published var costPerCheck: Double {
        didSet { UserDefaults.standard.set(costPerCheck, forKey: "costPerCheck") }
    }
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays") }
    }

    var estimatedCostToday: Double { Double(requestsToday) * costPerCheck }

    /// Apps excluded by default on first launch: password managers, the system
    /// password app, Keychain Access, Messages. Skips both privacy-sensitive
    /// content and apps that show known passphrases in plaintext.
    private static let defaultExclusions: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.MobileSMS",
    ]

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

        if defaults.bool(forKey: "exclusionsSeeded") {
            let stored = defaults.array(forKey: "excludedApps") as? [String] ?? []
            excludedBundleIDs = Set(stored)
        } else {
            excludedBundleIDs = Self.defaultExclusions
            defaults.set(Array(Self.defaultExclusions), forKey: "excludedApps")
            defaults.set(true, forKey: "exclusionsSeeded")
        }

        dailyCap = (defaults.object(forKey: "dailyCap") as? Int) ?? 500
        costPerCheck = (defaults.object(forKey: "costPerCheck") as? Double) ?? 0.005
        retentionDays = (defaults.object(forKey: "retentionDays") as? Int) ?? 30

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
        VerdictStore.dayString()
    }
}
