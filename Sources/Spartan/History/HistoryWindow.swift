import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SpartanCore

@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "Spartan History"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: HistoryView())
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HistoryView: View {
    @State private var records: [VerdictRecord] = []
    @State private var loading = true

    private let coordinator = AppCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    Task { await reload() }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button {
                    exportCSV()
                } label: { Label("Export CSV…", systemImage: "square.and.arrow.up") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([coordinator.verdictsDirectory()])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
                Spacer()
                Text("\(records.count) records")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)

            Divider()

            if loading {
                ProgressView().padding()
                Spacer()
            } else if records.isEmpty {
                Spacer()
                Text("No verdicts yet — scores will appear here as you scan.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(records) { record in
                    VerdictRow(record: record, coordinator: coordinator)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        records = await coordinator.verdictsRecent(limit: 200)
        loading = false
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "spartan-history.csv"
        if panel.runModal() == .OK, let url = panel.url {
            let csv = coordinator.verdictsCSV(records)
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct VerdictRow: View {
    let record: VerdictRecord
    let coordinator: AppCoordinator

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            scoreCapsule
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if let headline = record.headline {
                        Text(headline).font(.callout.bold())
                    }
                    Spacer()
                    Text(record.date, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("\(record.appName) · \(record.source) · \(record.words)w")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(record.text)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundColor(.primary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
            }
            if record.screenshotFile != nil {
                Button("Reveal screenshot") {
                    Task {
                        if let url = await coordinator.verdicts.url(forScreenshot: record) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
        }
    }

    private var scoreCapsule: some View {
        let pct = Int((record.score * 100).rounded())
        let color: Color = record.score >= 0.5 ? .red : .green
        return Text("\(pct)%")
            .font(.caption.monospacedDigit().bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.85), in: Capsule())
            .frame(width: 52, alignment: .center)
    }
}
