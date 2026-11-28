import AppKit
import PDFKit

/// The text of a file added to a meeting's context: read once, when it is added; nothing
/// keeps a path to the original.
public enum ContextImport {
    /// File name extensions it reads.
    public static let extensions = ["pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "txt", "text", "md", "markdown"]

    /// The file's text; nil for another type, a locked PDF or a file without text (a scanned PDF).
    /// Main actor: AppKit reads HTML only on the main thread.
    @MainActor public static func text(from url: URL) -> String? {
        let text: String?
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
            text = document.string
        case "docx": text = attributed(url, .officeOpenXML)
        case "doc": text = attributed(url, .docFormat)
        case "rtf": text = attributed(url, .rtf)
        case "rtfd": text = attributed(url, .rtfd)
        case "odt": text = attributed(url, .openDocument)
        case "html", "htm": text = attributed(url, .html)
        case "txt", "text", "md", "markdown": text = try? String(contentsOf: url, encoding: .utf8)
        default: return nil
        }
        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
    }

    private static func attributed(_ url: URL, _ type: NSAttributedString.DocumentType) -> String? {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        // HTML without a charset is read as Latin-1: a file that is valid UTF-8 is read as UTF-8.
        // (The option overrides a declared charset, so a windows-1251 page keeps its own.)
        if type == .html, let data = try? Data(contentsOf: url), String(data: data, encoding: .utf8) != nil {
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        return try? NSAttributedString(url: url, options: options, documentAttributes: nil).string
    }

    /// The context with a file's text added at the end, under the file's name.
    public static func appending(_ text: String, named name: String, to context: String) -> String {
        let section = "## \(name)\n\n\(text)"
        let before = context.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        return before.isEmpty ? section : before + "\n\n" + section
    }
}
