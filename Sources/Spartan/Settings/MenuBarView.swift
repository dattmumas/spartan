import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    @State private var apiKeyInput = ""
    @State private var keySaved = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.state = coordinator.state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if !state.hasScreenPermission {
                permissionSection
                Divider()
            }
            if !state.apiKeyPresent {
                apiKeySection
                Divider()
            }
            controls
            Divider()
            logSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        DocumentReportWindowController.shared.show(url: url)
                    }
                }
            }
            return true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: state.paused ? "pause.circle.fill" : "text.viewfinder")
                    .foregroundColor(state.paused ? .orange : .accentColor)
                Text("Spartan").font(.headline)
                Spacer()
                Text(state.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    HistoryWindowController.shared.show()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .help("Open history")
            }
            if let error = state.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Screen Recording permission required", systemImage: "exclamationmark.triangle")
                .font(.callout)
            Text("Spartan reads on-screen text via screen capture. Grant access in System Settings, then relaunch.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button("Grant access…") { coordinator.requestScreenPermission() }
                Button("Relaunch") { coordinator.relaunch() }
            }
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Pangram API key", systemImage: "key")
                .font(.callout)
            HStack {
                SecureField("x-api-key value", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    if KeychainStore.setAPIKey(apiKeyInput) {
                        state.apiKeyPresent = true
                        keySaved = true
                        apiKeyInput = ""
                    }
                }
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { !state.paused },
                set: { coordinator.setPaused(!$0) }
            )) {
                Text("Scanning enabled")
            }
            .toggleStyle(.switch)

            Picker("Scan", selection: Binding(
                get: { state.scanMode },
                set: { coordinator.setScanMode($0) }
            )) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if state.scanMode == .selection {
                Text("Select 15+ words in any window — Spartan pops up the AI score.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if !state.axTrusted {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.badge.clock")
                            .foregroundColor(.orange)
                        Text("Grant Accessibility for instant, exact detection")
                            .font(.caption2)
                        Button("Grant…") { coordinator.requestAccessibility() }
                            .font(.caption2)
                    }
                }
            } else {
                HStack {
                    Text("Threshold")
                    Slider(value: $state.threshold, in: 0.1...0.99)
                    Text("\(Int(state.threshold * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }

                Picker("Mode", selection: $state.mode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Button {
                pickDocument()
            } label: {
                Label("Check a document…", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            exclusionsRow

            HStack {
                Text("\(state.requestsToday)/\(state.dailyCap) checks · ≈ $\(String(format: "%.2f", state.estimatedCostToday)) today")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if state.apiKeyPresent {
                    Button("Change key") {
                        state.apiKeyPresent = false
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            DisclosureGroup("Budget") {
                VStack(alignment: .leading, spacing: 4) {
                    Stepper("Daily cap: \(state.dailyCap)",
                            value: $state.dailyCap, in: 50...5000, step: 50)
                        .font(.caption)
                    HStack {
                        Text("$/check").font(.caption)
                        TextField("0.005", text: Binding(
                            get: { String(state.costPerCheck) },
                            set: { state.costPerCheck = Double($0) ?? state.costPerCheck }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .font(.caption)
                    }
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var exclusionsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let app = state.currentApp,
               !state.excludedBundleIDs.contains(app.bundleID) {
                Button("Exclude \(app.name) from scanning") {
                    state.excludedBundleIDs.insert(app.bundleID)
                    coordinator.reapplyExclusions()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if !state.excludedBundleIDs.isEmpty {
                DisclosureGroup("Excluded apps (\(state.excludedBundleIDs.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.excludedBundleIDs.sorted(), id: \.self) { id in
                            HStack {
                                Text(id).font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    state.excludedBundleIDs.remove(id)
                                    coordinator.reapplyExclusions()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent scans").font(.caption).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(state.log.prefix(50)) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(scoreLabel(entry))
                                .font(.caption2.monospaced())
                                .foregroundColor(scoreColor(entry))
                                .frame(width: 58, alignment: .leading)
                            Text(entry.preview)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundColor(.primary)
                        }
                    }
                    if state.log.isEmpty {
                        Text("No scans yet")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
        }
    }

    private var footer: some View {
        HStack {
            Text("Sends visible text to Pangram Labs for analysis")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    private func scoreLabel(_ entry: ScanLogEntry) -> String {
        guard let score = entry.score else {
            return entry.source == "error" ? "ERR" : "—"
        }
        let pct = String(format: "%3.0f%%", score * 100)
        switch entry.source {
        case "cache": return "\(pct) ⊙"
        case "fuzzy": return "\(pct) ≈"
        default: return pct
        }
    }

    private func pickDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.pdf, .plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            DocumentReportWindowController.shared.show(url: url)
        }
    }

    private func scoreColor(_ entry: ScanLogEntry) -> Color {
        guard let score = entry.score else {
            return entry.source == "error" ? .red : .secondary
        }
        return score >= state.threshold ? .red : .green
    }
}
