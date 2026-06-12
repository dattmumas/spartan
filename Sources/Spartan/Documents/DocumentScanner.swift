import Foundation
import AppKit
import PDFKit
import SpartanCore

enum DocError: LocalizedError {
    case unsupported(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "Spartan can't read .\(ext) files yet."
        case .unreadable: return "The document couldn't be read."
        }
    }
}

enum DocumentText {
    /// Best-effort text extraction. PDF via PDFKit; .docx via NSAttributedString;
    /// .txt/.md via UTF-8.
    static func extract(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw DocError.unreadable }
            return doc.string ?? ""
        case "txt", "md", "markdown":
            return try String(contentsOf: url, encoding: .utf8)
        case "docx":
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.officeOpenXML
            ]
            do {
                let attr = try NSAttributedString(
                    url: url, options: opts, documentAttributes: nil
                )
                return attr.string
            } catch {
                throw DocError.unreadable
            }
        default:
            throw DocError.unsupported(ext)
        }
    }
}

struct DocumentSectionRow: Identifiable {
    let id = UUID()
    let index: Int
    let text: String
    let preview: String
    let words: Int
    var score: Double?
    var headline: String?
    let lowConfidence: Bool
    var source: String = "—"
    var error: String?
}

@MainActor
final class DocumentScanner: ObservableObject {
    @Published var rows: [DocumentSectionRow] = []
    @Published var running = false
    @Published var progressText = ""
    @Published var summary: String?
    /// Set by `scan(url:)` when the section count > 50; the UI shows a
    /// "Scan N sections?" confirmation that calls `confirmScan()`.
    @Published var needsConfirmation: Int?
    let url: URL

    private let coordinator = AppCoordinator.shared
    private var pendingSections: [DocumentChunker.Section] = []

    init(url: URL) {
        self.url = url
    }

    func scan() async {
        let text: String
        do {
            text = try DocumentText.extract(from: url)
        } catch {
            progressText = error.localizedDescription
            return
        }
        guard !text.isEmpty else {
            progressText = "No readable text in document."
            return
        }
        let sections = DocumentChunker.sections(from: text)
        guard !sections.isEmpty else {
            progressText = "No sections meet the 40-word minimum to score."
            return
        }
        rows = sections.enumerated().map { i, section in
            DocumentSectionRow(
                index: i + 1, text: section.text,
                preview: String(section.text.prefix(140)),
                words: section.text.split(whereSeparator: \.isWhitespace).count,
                lowConfidence: section.lowConfidence
            )
        }
        if sections.count > 50 {
            needsConfirmation = sections.count
            pendingSections = sections
            progressText = "\(sections.count) sections — confirm to proceed."
            return
        }
        await runScan(sections: sections)
    }

    func confirmScan() async {
        let sections = pendingSections
        pendingSections = []
        needsConfirmation = nil
        await runScan(sections: sections)
    }

    private func runScan(sections: [DocumentChunker.Section]) async {
        running = true
        defer { running = false }
        for (i, section) in sections.enumerated() {
            progressText = "Scoring \(i + 1) / \(sections.count)"
            let passage = Passage(
                text: section.text, lines: [], lowConfidence: section.lowConfidence
            )
            let lookup = await coordinator.cache.lookup(passage)
            switch lookup {
            case .exact(let r), .fuzzy(let r):
                applyResult(r, to: i, source: "cache")
                continue
            case .miss:
                break
            }
            if coordinator.state.requestsToday >= coordinator.state.dailyCap {
                rows[i].error = "Daily cap reached"
                continue
            }
            coordinator.state.requestsToday += 1
            do {
                let result = try await coordinator.detector.detect(section.text)
                await coordinator.cache.store(result, for: passage)
                applyResult(result, to: i, source: "api")
                let record = VerdictRecord(
                    appName: url.lastPathComponent, source: "document",
                    passageHash: passage.hash, text: section.text,
                    words: passage.wordCount, score: result.aiLikelihood,
                    headline: result.prediction, lowConfidence: section.lowConfidence
                )
                await coordinator.verdicts.append(record, screenshot: nil)
            } catch let error as DetectorError {
                rows[i].error = error.description
            } catch {
                rows[i].error = error.localizedDescription
            }
        }
        finalizeSummary()
        progressText = "Done — \(rows.compactMap(\.score).count) of \(rows.count) scored."
    }

    private func applyResult(_ r: DetectionResult, to index: Int, source: String) {
        rows[index].score = r.aiLikelihood
        rows[index].headline = r.prediction
        rows[index].source = source
    }

    private func finalizeSummary() {
        var totalWords = 0
        var weighted = 0.0
        var aiCount = 0
        for row in rows {
            guard let score = row.score else { continue }
            totalWords += row.words
            weighted += score * Double(row.words)
            if score >= 0.5 { aiCount += 1 }
        }
        guard totalWords > 0 else {
            summary = nil
            return
        }
        let weightedMean = weighted / Double(totalWords)
        summary = "\(aiCount) of \(rows.count) sections AI · weighted \(Int((weightedMean * 100).rounded()))% AI overall"
    }
}
