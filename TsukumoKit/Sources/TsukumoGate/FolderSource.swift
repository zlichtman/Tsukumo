import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
import TsukumoCore
import TsukumoPolicy

// Files and folders the owner picks, as many as they like: each kept as a bookmark (security-scoped where
// the system needs it) and read on demand, only when a bot's question reaches the Gate. KemoSabe looks at
// file names and the text of text files, Markdown, PDFs, and code, and hands Apple's on-device model the few
// files that match best, each cut to the part that matches. Nothing is indexed or copied.

/// A picked file or folder, read for one question.
public struct FolderSource: PersonalSource {
    public let folder: PickedFolder
    /// At most this many files answer one question, and this many are looked at.
    public static let maxFiles = 6, maxScanned = 3000
    /// What's read of one file.
    public static let maxBytes = 256 * 1024
    static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "mdown", "org", "rtf", "csv", "tsv", "json", "yaml", "yml", "toml",
        "xml", "html", "htm", "log", "tex", "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java", "kt", "c", "h", "m", "mm", "cpp",
        "hpp", "cs", "php", "sh", "zsh", "sql", "ini", "conf", "pdf"]

    public init(folder: PickedFolder) { self.folder = folder }

    /// The bookmark's file or folder, wherever it moved to.
    public func resolve() -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        guard let root = resolve() else { return [] }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        return Self.search(root, isFolder: folder.isFolder, for: question.question).map { hit in
            PersonalItem(id: "file:" + folder.id.uuidString + ":" + hit.path, kind: .document, level: folder.setting.level,
                         title: "your file “\(hit.url.lastPathComponent)”", text: hit.text, date: hit.modified, matched: true)
        }
    }

    struct Hit { let url: URL; let path: String; let text: String; let modified: Date?; let score: Int }

    /// The files under `root` that share the most words with the question (names count double), best first.
    static func search(_ root: URL, isFolder: Bool, for question: String) -> [Hit] {
        let wanted = MessagesTerms.terms(question)
        guard !wanted.isEmpty else { return [] }
        let root = root.resolvingSymlinksInPath()
        var files: [URL] = []
        if isFolder {
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = walker?.nextObject() as? URL, files.count < maxScanned {
                if ["node_modules", "build", "DerivedData", ".build"].contains(url.lastPathComponent) { walker?.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
            }
        } else {
            files = [root]
        }
        var hits: [Hit] = []
        for url in files {
            let path = isFolder ? String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
            let nameScore = MessagesTerms.terms(path.replacingOccurrences(of: "/", with: " ")).intersection(wanted).count * 2
            let content = textExtensions.contains(url.pathExtension.lowercased()) ? read(url) : nil
            let contentScore = content.map { MessagesTerms.terms($0).intersection(wanted).count } ?? 0
            guard nameScore + contentScore > 0 else { continue }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            var text = "File: " + path
            if let modified { text += "\nModified: " + modified.formatted(date: .abbreviated, time: .shortened) }
            if let content, !content.isEmpty { text += "\n" + Extraction.focus(content, on: question, limit: 2_400) }
            hits.append(Hit(url: url, path: path, text: text, modified: modified, score: nameScore + contentScore))
        }
        return Array(hits.sorted { $0.score != $1.score ? $0.score > $1.score : ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            .prefix(maxFiles))
    }

    /// A text file's first part, or a PDF's text.
    static func read(_ url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            #if canImport(PDFKit)
            guard let document = PDFDocument(url: url) else { return nil }
            var text = ""
            for index in 0..<min(document.pageCount, 30) where text.count < maxBytes {
                text += (document.page(at: index)?.string ?? "") + "\n"
            }
            return text
            #else
            return nil
            #endif
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        if url.pathExtension.lowercased() == "rtf",
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return attributed.string
        }
        return String(decoding: data, as: UTF8.self)
    }
}
