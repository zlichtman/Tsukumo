import Foundation

/// Reading the files people bring to their profile: LinkedIn's data export (CSV), Instagram's
/// "Download your information" export (JSON), and a blog's public RSS or Atom feed. Nothing here
/// signs in anywhere or reads instagram.com or linkedin.com; the person hands over their own files,
/// and the feed is fetched only when they add it or tap Refresh.

// MARK: CSV

enum CSVParser {
    /// Rows of fields, following RFC 4180: quoted fields may hold commas, doubled quotes, and line breaks.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = String.UnicodeScalarView()
        var quoted = false, afterQuote = false
        var scalars = text.unicodeScalars[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        func endField() { row.append(String(field)); field = .init(); afterQuote = false }
        func endRow() { endField(); if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }; row = [] }
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let c = scalars[index]
            index = scalars.index(after: index)
            if quoted {
                if c == "\"" {
                    if index < scalars.endIndex, scalars[index] == "\"" { field.append("\""); index = scalars.index(after: index) }
                    else { quoted = false; afterQuote = true }
                } else { field.append(c) }
                continue
            }
            switch c {
            case "\"" where field.isEmpty && !afterQuote: quoted = true
            case ",": endField()
            case "\r":
                if index < scalars.endIndex, scalars[index] == "\n" { index = scalars.index(after: index) }
                endRow()
            case "\n": endRow()
            default: field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty || afterQuote { endRow() }
        return rows
    }

    /// The rows under the first row that has every expected column, as dictionaries keyed by column.
    /// LinkedIn puts a "Notes:" preamble above the header in some files.
    static func table(_ rows: [[String]], requiring columns: [String]) -> [[String: String]]? {
        let wanted = Set(columns.map { $0.lowercased() })
        guard let start = rows.firstIndex(where: { wanted.isSubset(of: Set($0.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })) }) else { return nil }
        let header = rows[start].map { $0.trimmingCharacters(in: .whitespaces) }
        return rows[(start + 1)...].map { row in
            var values: [String: String] = [:]
            for (column, value) in zip(header, row) where !column.isEmpty { values[column] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            return values
        }
    }
}

// MARK: LinkedIn

enum LinkedInImport {
    struct Result: Equatable {
        var experience: [WorkEntry] = []
        var education: [EducationEntry] = []
        var skills: [String] = []
        var certifications: [CertificationEntry] = []
        var languages: [LanguageEntry] = []
        var headline: String?
        var summary: String?
        /// Profile.csv's Geo Location ("San Francisco Bay Area").
        var location: String?
        var isEmpty: Bool {
            experience.isEmpty && education.isEmpty && skills.isEmpty && certifications.isEmpty && languages.isEmpty
                && headline == nil && summary == nil && location == nil
        }
    }
    /// The export's files this reads; the others (messages, connections, and so on) are never opened.
    static let knownFiles = ["profile.csv", "positions.csv", "education.csv", "skills.csv", "certifications.csv", "languages.csv"]

    /// Reads each file by its columns, so a renamed copy ("Positions (1).csv") still works. The
    /// columns are LinkedIn's own: Positions (Company Name, Title, Description, Location, Started
    /// On, Finished On), Education (School Name, Start Date, End Date, Notes, Degree Name,
    /// Activities), Skills (Name), Certifications (Name, Url, Authority, Started On, Finished On,
    /// License Number), Languages (Name, Proficiency), and Profile (First Name, Last Name, …,
    /// Headline, Summary, Industry, Zip Code, Geo Location, …).
    static func parse(_ files: [String]) -> Result {
        var result = Result()
        func value(_ row: [String: String], _ key: String) -> String? { row[key].flatMap { $0.isEmpty ? nil : $0 } }
        for text in files {
            let rows = CSVParser.rows(text)
            if let table = CSVParser.table(rows, requiring: ["Company Name", "Title"]) {
                result.experience += table.compactMap(position)
            } else if let table = CSVParser.table(rows, requiring: ["School Name"]) {
                result.education += table.compactMap(school)
            } else if let table = CSVParser.table(rows, requiring: ["First Name", "Headline"]), let first = table.first {
                result.headline = value(first, "Headline")
                result.summary = value(first, "Summary")
                result.location = value(first, "Geo Location")
            } else if let table = CSVParser.table(rows, requiring: ["Name", "Authority"]) {
                result.certifications += table.compactMap(certification)
            } else if let table = CSVParser.table(rows, requiring: ["Name", "Proficiency"]) {
                result.languages += table.compactMap { row in value(row, "Name").map { LanguageEntry(name: $0, proficiency: row["Proficiency"] ?? "") } }
            } else if rows.first(where: { $0.contains { $0.trimmingCharacters(in: .whitespaces) == "Name" } })?.filter({ !$0.isEmpty }).count == 1,
                      let table = CSVParser.table(rows, requiring: ["Name"]) {
                result.skills += table.compactMap { value($0, "Name") }
            }
        }
        result.experience.sort(by: WorkEntry.newestFirst)
        result.education.sort { ($0.end ?? $0.start ?? .init(year: 0)) > ($1.end ?? $1.start ?? .init(year: 0)) }
        result.certifications.sort { ($0.issued ?? .init(year: 0)) > ($1.issued ?? .init(year: 0)) }
        return result
    }
    static func certification(_ row: [String: String]) -> CertificationEntry? {
        let link = row["Url"].flatMap { $0.lowercased().hasPrefix("https://") ? $0 : nil }
        let entry = CertificationEntry(name: row["Name"] ?? "", authority: row["Authority"] ?? "", issued: row["Started On"].flatMap(ProfileMonth.parse),
                                       expires: row["Finished On"].flatMap(ProfileMonth.parse), link: link)
        return entry.name.isEmpty ? nil : entry
    }
    static func position(_ row: [String: String]) -> WorkEntry? {
        let entry = WorkEntry(title: row["Title"] ?? "", company: row["Company Name"] ?? "", location: row["Location"] ?? "",
                              start: row["Started On"].flatMap(ProfileMonth.parse), end: row["Finished On"].flatMap(ProfileMonth.parse),
                              summary: row["Description"] ?? "")
        return entry.title.isEmpty && entry.company.isEmpty ? nil : entry
    }
    static func school(_ row: [String: String]) -> EducationEntry? {
        let notes = [row["Notes"], row["Activities"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let entry = EducationEntry(school: row["School Name"] ?? "", degree: row["Degree Name"] ?? "",
                                   start: row["Start Date"].flatMap(ProfileMonth.parse), end: row["End Date"].flatMap(ProfileMonth.parse), notes: notes)
        return entry.school.isEmpty ? nil : entry
    }

    /// The text of the chosen CSV files, or of the known files inside a chosen folder.
    static func readFiles(_ urls: [URL]) throws -> [String] {
        var texts: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for file in ImportFiles.children(of: url) where knownFiles.contains(file.lastPathComponent.lowercased()) {
                    if let text = try? ImportFiles.text(file) { texts.append(text) }
                }
            } else {
                texts.append(try ImportFiles.text(url))
            }
        }
        return texts
    }
}

// MARK: Instagram

enum InstagramImport {
    struct Post: Equatable {
        /// Relative to the export's root folder, as Instagram writes it ("media/posts/202301/abc.jpg").
        var uri: String
        var caption: String?
        var taken: Date?
        var isVideo: Bool { ["mp4", "mov", "m4v"].contains((uri as NSString).pathExtension.lowercased()) }
    }
    static let maxPerImport = 500
    /// Where the posts list lives, newest layout first.
    static let postFolders = ["your_instagram_activity/content", "your_instagram_activity/media", "content"]

    /// Every photo and video in the posts list, one post per item (a carousel becomes several),
    /// with its caption and the day it was posted.
    static func posts(fromJSON data: Data) throws -> [Post] {
        let json = try JSONSerialization.jsonObject(with: data)
        let entries: [[String: Any]]
        if let array = json as? [[String: Any]] { entries = array }
        else if let object = json as? [String: Any] { entries = object.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 } }
        else { entries = [] }
        return entries.flatMap { entry -> [Post] in
            let postCaption = (entry["title"] as? String).map(repair)
            let postTime = timestamp(entry["creation_timestamp"])
            let media = entry["media"] as? [[String: Any]] ?? []
            return media.compactMap { item in
                guard let uri = item["uri"] as? String, !uri.isEmpty, !uri.hasPrefix("http") else { return nil }
                let caption = (item["title"] as? String).map(repair).flatMap { $0.isEmpty ? nil : $0 } ?? postCaption.flatMap { $0.isEmpty ? nil : $0 }
                return Post(uri: uri, caption: caption, taken: timestamp(item["creation_timestamp"]) ?? postTime)
            }
        }
    }
    private static func timestamp(_ value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    /// Instagram writes UTF-8 bytes as if each were its own character ("donâ\u{80}\u{99}t"). Reads the
    /// characters back as bytes and decodes them as UTF-8; text that isn't mangled that way is kept.
    static func repair(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x80 }),
              text.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) else { return text }
        let bytes = text.unicodeScalars.map { UInt8($0.value) }
        return String(data: Data(bytes), encoding: .utf8) ?? text
    }
    /// The export's root folder (the chosen folder, or one folder inside it) and its posts lists.
    static func locate(in folder: URL) -> (root: URL, lists: [URL])? {
        for root in [folder] + ImportFiles.children(of: folder).filter(\.hasDirectoryPath) {
            for sub in postFolders {
                let lists = ImportFiles.children(of: root.appendingPathComponent(sub, isDirectory: true))
                    .filter { $0.lastPathComponent.hasPrefix("posts_") && $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                if !lists.isEmpty { return (root, lists) }
            }
        }
        return nil
    }
    /// The file a post points at, only if it stays inside the export folder.
    static func file(for uri: String, in root: URL) -> URL? {
        let parts = uri.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains("."), !uri.hasPrefix("/") else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }
}

// MARK: Files

/// Reading files the person chose in Files, which may still be in iCloud Drive: each read is
/// coordinated so the file is downloaded and not read while it's being written.
enum ImportFiles {
    static func data(_ url: URL, limit: Int = 200_000_000) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordination) { readable in
            result = Result {
                let size = (try? readable.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= limit else { throw CocoaError(.fileReadTooLarge) }
                return try Data(contentsOf: readable, options: .mappedIfSafe)
            }
        }
        if let coordination { throw coordination }
        return try result.get()
    }
    static func text(_ url: URL) throws -> String {
        let data = try data(url, limit: 20_000_000)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
    /// Copies a file to a temporary one the app owns (for videos, which are copied in whole).
    static func copyToTemporary(_ url: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
        var failure: Error?, coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordination) { readable in
            do { try FileManager.default.copyItem(at: readable, to: copy) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
        return copy
    }
    /// A folder's items, with iCloud placeholders (".name.icloud") named as the files they stand for.
    static func children(of folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.map { name in
            var name = name
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return folder.appendingPathComponent(name, isDirectory: isDirectory.boolValue)
        }.filter { !$0.lastPathComponent.hasPrefix(".") }
    }
}

// MARK: Blog feeds

/// A blog's RSS or Atom feed, reduced to titles, links, dates, and short plain-text summaries.
struct ParsedFeed: Equatable {
    var title: String?
    var entries: [BlogEntry]
}

enum FeedParser {
    static let maxEntries = 50
    /// Nil when the document isn't an RSS, RDF, or Atom feed.
    static func parse(_ data: Data) -> ParsedFeed? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        guard delegate.isFeed else { return nil }
        return ParsedFeed(title: delegate.feedTitle.flatMap { clean($0, limit: 200) }, entries: Array(delegate.entries.prefix(maxEntries)))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var isFeed = false
        var feedTitle: String?
        var entries: [BlogEntry] = []
        private var path: [String] = []
        private var text = ""
        private var current: [String: String]?
        private var link: String?

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = element.lowercased()
            if path.isEmpty { isFeed = ["rss", "feed", "rdf:rdf", "rdf"].contains(name) }
            if !isFeed { parser.abortParsing(); return }
            path.append(name); text = ""
            if name == "item" || name == "entry" { current = [:]; link = nil }
            // Atom links are attributes; the alternate (or unlabeled) one is the post itself.
            if name == "link", current != nil, let href = attributes["href"], link == nil || attributes["rel"] == "alternate" {
                if attributes["rel"] == nil || attributes["rel"] == "alternate" { link = href }
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let name = element.lowercased()
            defer { if !path.isEmpty { path.removeLast() }; text = "" }
            if var entry = current {
                if name == "item" || name == "entry" {
                    let title = FeedParser.clean(entry["title"] ?? "", limit: 300) ?? ""
                    let href = (link ?? entry["link"] ?? entry["guid"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    let date = [entry["pubdate"], entry["published"], entry["updated"], entry["dc:date"]].compactMap { $0 }.lazy.compactMap(FeedParser.date).first
                    let summary = FeedParser.clean(entry["description"] ?? entry["summary"] ?? entry["content:encoded"] ?? entry["content"] ?? "", limit: 400) ?? ""
                    if entries.count < FeedParser.maxEntries, !title.isEmpty || !summary.isEmpty {
                        entries.append(BlogEntry(title: title, link: href.flatMap { $0.hasPrefix("https://") || $0.hasPrefix("http://") ? $0 : nil }, date: date, summary: summary))
                    }
                    current = nil
                } else if path.count >= 2, ["item", "entry"].contains(path[path.count - 2]), entry[name] == nil {
                    entry[name] = text; current = entry
                }
            } else if name == "title", feedTitle == nil, path.count >= 2, ["channel", "feed"].contains(path[path.count - 2]) {
                feedTitle = text
            }
        }
    }

    /// Plain text: tags removed, common entities decoded, whitespace collapsed, and cut to `limit`.
    static func clean(_ html: String, limit: Int) -> String? {
        var text = html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&hellip;": "\u{2026}", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        if let numeric = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for match in numeric.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: text), let digits = Range(match.range(at: 2), in: text) else { continue }
                let hex = match.range(at: 1).length > 0
                if let code = UInt32(text[digits], radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) { text.replaceSubrange(whole, with: String(Character(scalar))) }
            }
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : text
    }
    static func date(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = try? Date.ISO8601FormatStyle().parse(value) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

enum FeedDiscovery {
    /// Feed links a page announces with `<link rel="alternate" type="application/rss+xml">` (or Atom).
    static func alternates(inHTML html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
              let attribute = try? NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))") else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var found: [URL] = []
        for match in tag.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let element = String(html[tagRange])
            var attributes: [String: String] = [:]
            for pair in attribute.matches(in: element, range: NSRange(element.startIndex..., in: element)) {
                guard let key = Range(pair.range(at: 1), in: element) else { continue }
                let value = [2, 3, 4].lazy.compactMap { Range(pair.range(at: $0), in: element) }.first.map { String(element[$0]) } ?? ""
                attributes[element[key].lowercased()] = value
            }
            let rel = (attributes["rel"] ?? "").lowercased().split(separator: " ")
            let type = (attributes["type"] ?? "").lowercased()
            guard rel.contains("alternate"), type == "application/rss+xml" || type == "application/atom+xml",
                  let href = attributes["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL, url.scheme == "https", !found.contains(url) else { continue }
            found.append(url)
        }
        return found
    }
    static let commonPaths = ["/feed", "/rss", "/atom.xml", "/index.xml"]
    static func commonFeeds(for site: URL) -> [URL] {
        guard var components = URLComponents(url: site, resolvingAgainstBaseURL: false) else { return [] }
        components.query = nil; components.fragment = nil
        return commonPaths.compactMap { path in components.path = path; return components.url }
    }
    /// The address as typed, as an https URL. Plain http is upgraded; other schemes are refused.
    static func normalize(_ address: String) -> URL? {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        if value.lowercased().hasPrefix("http://") { value = "https://" + value.dropFirst(7) }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", let host = url.host, host.contains(".") else { return nil }
        return url
    }
}

/// Fetches a blog's feed from the address the person gave, only when they add it or tap Refresh.
/// At most six requests, each with a short timeout, over https only, with no cookies.
struct FeedFetcher {
    enum Failure: LocalizedError {
        case badAddress, notFound, unreachable
        var errorDescription: String? {
            switch self {
            case .badAddress: "Enter a web address, like example.com or example.com/feed."
            case .notFound: "No RSS or Atom feed was found at that address."
            case .unreachable: "The blog couldn't be reached. Check the address and try again."
            }
        }
    }
    static let maxRequests = 6
    static let maxBytes = 3_000_000

    func fetch(_ address: String) async throws -> (feed: URL, parsed: ParsedFeed) {
        guard let start = FeedDiscovery.normalize(address) else { throw Failure.badAddress }
        let session = URLSession(configuration: Self.configuration, delegate: HTTPSOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var requests = 0, reached = false
        func load(_ url: URL) async -> (Data, URL)? {
            guard requests < Self.maxRequests else { return nil }
            requests += 1
            guard let result = try? await session.data(from: url), let http = result.1 as? HTTPURLResponse else { return nil }
            reached = true
            guard (200..<300).contains(http.statusCode), result.0.count <= Self.maxBytes else { return nil }
            return (result.0, http.url ?? url)
        }
        guard let page = await load(start) else { throw reached ? Failure.notFound : Failure.unreachable }
        let landed = page.1
        if let parsed = FeedParser.parse(page.0) { return (landed, parsed) }
        let html = String(decoding: page.0.prefix(500_000), as: UTF8.self)
        var candidates = FeedDiscovery.alternates(inHTML: html, base: landed).prefix(2).map { $0 }
        candidates += FeedDiscovery.commonFeeds(for: landed).filter { !candidates.contains($0) }
        for candidate in candidates {
            if let found = await load(candidate), let parsed = FeedParser.parse(found.0) { return (found.1, parsed) }
        }
        throw Failure.notFound
    }
    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return configuration
    }
    /// Follows redirects only to https addresses.
    private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }
}
