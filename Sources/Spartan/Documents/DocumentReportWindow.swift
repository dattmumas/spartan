import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SpartanCore

@MainActor
final class DocumentReportWindowController {
    static let shared = DocumentReportWindowController()
    private var windows: [URL: NSWindow] = [:]

    func show(url: URL) {
        if let existing = windows[url] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let scanner = DocumentScanner(url: url)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = url.lastPathComponent
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(
            rootView: DocumentReportView(scanner: scanner)
        )
        windows[url] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await scanner.scan() }
    }
}

struct DocumentReportView: View {
    @ObservedObject var scanner: DocumentScanner

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let count = scanner.needsConfirmation {
                confirmBanner(count: count)
                Divider()
            }
            List(scanner.rows) { row in
                SectionRow(row: row)
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 520, minHeight: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(scanner.url.lastPathComponent).font(.headline)
                    if let summary = scanner.summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        Text(scanner.progressText.isEmpty
                            ? "Loading…"
                            : scanner.progressText)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if scanner.running { ProgressView() }
                Button("Export CSV…", action: exportCSV)
                    .disabled(scanner.rows.allSatisfy { $0.score == nil })
            }
        }
        .padding(12)
    }

    private func confirmBanner(count: Int) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("\(count) sections — large document. Scan all?")
                .font(.callout)
            Spacer()
            Button("Scan all") {
                Task { await scanner.confirmScan() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = scanner.url
            .deletingPathExtension().lastPathComponent + "-report.csv"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var csv = "section,words,score,headline,lowConfidence,source,text\n"
        for row in scanner.rows {
            let scoreStr = row.score.map { String(format: "%.4f", $0) } ?? ""
            csv += [
                String(row.index),
                String(row.words),
                scoreStr,
                VerdictStore.csvEscape(row.headline ?? ""),
                row.lowConfidence ? "true" : "false",
                row.source,
                VerdictStore.csvEscape(row.text),
            ].joined(separator: ",") + "\n"
        }
        try? csv.write(to: dest, atomically: true, encoding: .utf8)
    }
}

private struct SectionRow: View {
    let row: DocumentSectionRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            scoreView
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("§\(row.index)").font(.caption.monospacedDigit())
                    if let headline = row.headline {
                        Text(headline).font(.callout.bold())
                    }
                    Spacer()
                    Text("\(row.words)w · \(row.source)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(row.preview)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                if let error = row.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var scoreView: some View {
        if let score = row.score {
            let pct = Int((score * 100).rounded())
            let color: Color = score >= 0.5 ? .red : .green
            Text("\(pct)%")
                .font(.caption.monospacedDigit().bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.85), in: Capsule())
                .frame(width: 52, alignment: .center)
        } else if row.error != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .frame(width: 52, alignment: .center)
        } else {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 52, alignment: .center)
        }
    }
}
