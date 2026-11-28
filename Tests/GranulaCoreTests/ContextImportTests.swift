import AppKit
import CoreText
import Foundation
import Testing
@testable import GranulaCore

/// A résumé dropped onto the meeting context: Word and PDF files become their text.
/// Without it a dropped résumé adds nothing to hints and the summary.
@Suite struct ContextImportTests {
    @Test @MainActor func wordAndPDFFilesBecomeTheirText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let docx = folder.appendingPathComponent("resume.docx")
        let word = NSAttributedString(string: "Dana Reyes\nTen years of Postgres migrations.")
        try word.data(from: NSRange(location: 0, length: word.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            .write(to: docx)

        let pdf = folder.appendingPathComponent("agenda.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let page = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        page.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Agenda: the migration in March", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        page.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, page)
        page.endPDFPage()
        page.closePDF()

        let wordText = try #require(ContextImport.text(from: docx))
        #expect(wordText.contains("Dana Reyes"))
        #expect(wordText.contains("Ten years of Postgres migrations."))
        let pdfText = try #require(ContextImport.text(from: pdf))
        #expect(pdfText.contains("Agenda: the migration in March"))

        let context = ContextImport.appending(pdfText, named: "agenda.pdf",
                                              to: ContextImport.appending(wordText, named: "resume.docx", to: "Ask about staging.\n"))
        #expect(context.hasPrefix("Ask about staging.\n\n## resume.docx\n\nDana Reyes"))
        #expect(context.hasSuffix("\n\n## agenda.pdf\n\n" + pdfText))
    }
}
