import AppKit

/// Pets are not shipped with the app: like the Windows version, it reads the pet list (pets.json) from the
/// upstream desktopPet repository and downloads each animations.xml on demand. Downloads are cached in
/// ~/Library/Application Support/DesktopPet/Pets/<folder>/ so pets keep working offline.
final class PetCatalog {
    struct Entry: Codable {
        let folder: String
        let author: String
        let lastupdate: String
    }
    private struct Index: Codable {
        let pets: [Entry]
    }
    /// A pet's <title>, remembered with the lastupdate it was read from.
    private struct CachedTitle: Codable {
        let title: String
        let lastupdate: String
    }

    enum CatalogError: LocalizedError {
        case badFolderName(String)
        case unknownPet(String)
        case http(Int, URL)

        var errorDescription: String? {
            switch self {
            case .badFolderName(let f): return "Invalid pet folder name \"\(f)\"."
            case .unknownPet(let f): return "The pet \"\(f)\" is not in the pet list."
            case .http(let code, let url): return "Download failed (HTTP \(code)): \(url.absoluteString)"
            }
        }
    }

    static let baseURL = URL(string: "https://raw.githubusercontent.com/Adrianotiger/desktopPet/master/Pets/")!

    let cacheRoot: URL
    private(set) var entries: [Entry] = []
    private var titles: [String: CachedTitle] = [:]
    private var iconCache: [String: NSImage] = [:]
    private let session: URLSession

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        cacheRoot = support.appendingPathComponent("DesktopPet/Pets", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)

        // Last known pet list, so the menu is filled before (or without) a network round trip.
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) {
            entries = Self.valid(index.pets)
        }
        if let data = try? Data(contentsOf: titlesURL),
           let cached = try? JSONDecoder().decode([String: CachedTitle].self, from: data) {
            titles = cached
        }
    }

    private var indexURL: URL { cacheRoot.appendingPathComponent("pets.json") }
    private var titlesURL: URL { cacheRoot.appendingPathComponent("titles.json") }

    // MARK: - Display names

    /// Menu name: the pet's title from its animations.xml, or a tidied folder name until that is known.
    func displayName(_ folder: String) -> String {
        let raw = titles[folder]?.title
            ?? folder.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return Self.capitalizeLowercaseWords(raw)
    }

    /// "fox mate" -> "Fox Mate", but leaves "gSheep Blue", "eSheep 64bit" and "SSJ Goku" alone.
    static func capitalizeLowercaseWords(_ s: String) -> String {
        return s.split(separator: " ").map { word -> String in
            word.allSatisfy { $0.isLowercase } ? word.prefix(1).uppercased() + word.dropFirst() : String(word)
        }.joined(separator: " ")
    }

    /// Reads <title> from the start of an animations.xml (the header comes before the large image data).
    static func extractTitle(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.range(of: "<title>"),
              let close = text.range(of: "</title>", range: open.upperBound..<text.endIndex) else { return nil }
        let title = String(text[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func saveTitles() {
        guard let data = try? JSONEncoder().encode(titles) else { return }
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? data.write(to: titlesURL, options: .atomic)
    }

    /// Fetches the titles that are missing or outdated. Only the first 4 KB of each animations.xml is
    /// requested (HTTP range), instead of the whole file with its sprite sheet. Completion runs on main.
    func fetchMissingTitles(completion: @escaping () -> Void) {
        let missing = entries.filter { titles[$0.folder]?.lastupdate != $0.lastupdate }
        guard !missing.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for e in missing {
            group.enter()
            var request = URLRequest(url: Self.baseURL.appendingPathComponent(e.folder).appendingPathComponent("animations.xml"))
            request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
            session.dataTask(with: request) { data, _, _ in
                let title = data.flatMap(Self.extractTitle)
                DispatchQueue.main.async {
                    if let t = title { self.titles[e.folder] = CachedTitle(title: t, lastupdate: e.lastupdate) }
                    group.leave()
                }
            }.resume()
        }
        group.notify(queue: .main) { [weak self] in
            self?.saveTitles()
            completion()
        }
    }

    // MARK: - Icons

    private func iconURL(_ folder: String) -> URL { folderURL(folder).appendingPathComponent("icon.png") }

    /// The pet's icon.png (48x48), if downloaded.
    func icon(_ folder: String) -> NSImage? {
        if let img = iconCache[folder] { return img }
        guard Self.isValidFolder(folder), let img = NSImage(contentsOf: iconURL(folder)) else { return nil }
        iconCache[folder] = img
        return img
    }

    /// Downloads the icon.png files that are missing or outdated (a few KB each, like the upstream
    /// pet chooser). Completion runs on main.
    func fetchMissingIcons(completion: @escaping () -> Void) {
        fetchMissing(file: "icon.png", maxBytes: 256 * 1024, completion: completion) { [weak self] folder, data in
            guard let img = NSImage(data: data) else { return false }
            self?.iconCache[folder] = img
            return true
        }
    }

    // MARK: - Descriptions (README.md, the pet's "about" text upstream)

    /// The pet's README.md, if downloaded.
    func readme(_ folder: String) -> String? {
        guard Self.isValidFolder(folder) else { return nil }
        return try? String(contentsOf: folderURL(folder).appendingPathComponent("README.md"), encoding: .utf8)
    }

    func fetchMissingReadmes(completion: @escaping () -> Void) {
        fetchMissing(file: "README.md", maxBytes: 64 * 1024, completion: completion) { _, data in
            String(data: data, encoding: .utf8) != nil
        }
    }

    /// First sentence of the README's "Description" section (or of its first paragraph), as plain text.
    func shortDescription(_ folder: String) -> String? {
        guard let md = readme(folder) else { return nil }
        var lines = md.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let i = lines.firstIndex(where: { $0.lowercased().hasPrefix("## description") }) {
            lines = Array(lines[(i + 1)...])
        }
        let paragraph = lines.drop { $0.isEmpty || $0.hasPrefix("#") }.prefix { !$0.isEmpty && !$0.hasPrefix("#") }
        var text = Self.plainText(paragraph.joined(separator: " "))
        // A sentence ends at . ! or ? followed by a capital letter or the end ("Negima! mascots." is one sentence).
        if let end = text.range(of: #"[.!?](?=\s+[A-Z]|\s*$)"#, options: .regularExpression) {
            text = String(text[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }
        return text.count > 140 ? String(text.prefix(139)) + "…" : text
    }

    /// Removes Markdown link and emphasis syntax: "[text](url)" -> "text", "**x**" -> "x".
    static func plainText(_ md: String) -> String {
        var s = md.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`"] { s = s.replacingOccurrences(of: mark, with: "") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Small per-pet files

    /// Downloads `file` for every pet whose copy is missing or older than its lastupdate in the pet list.
    /// `accept` validates the data (and may cache it); only accepted files are written. Completion on main.
    private func fetchMissing(file: String, maxBytes: Int, completion: @escaping () -> Void,
                              accept: @escaping (String, Data) -> Bool) {
        let stampName = file + ".lastupdate"
        let missing = entries.filter { e in
            let dir = folderURL(e.folder)
            let stamp = try? String(contentsOf: dir.appendingPathComponent(stampName), encoding: .utf8)
            return stamp != e.lastupdate || !FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path)
        }
        guard !missing.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for e in missing {
            group.enter()
            get(Self.baseURL.appendingPathComponent(e.folder).appendingPathComponent(file)) { [weak self] result in
                defer { group.leave() }
                guard let self = self, case .success(let data) = result,
                      data.count <= maxBytes, accept(e.folder, data) else { return }
                let dir = self.folderURL(e.folder)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
                try? e.lastupdate.write(to: dir.appendingPathComponent(stampName), atomically: true, encoding: .utf8)
            }
        }
        group.notify(queue: .main) { completion() }
    }

    /// Folder names come from the network and become path components, so allow only plain names.
    static func isValidFolder(_ name: String) -> Bool {
        return !name.isEmpty && name.count <= 64
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
            && name.unicodeScalars.allSatisfy { $0.isASCII }
    }

    private static func valid(_ list: [Entry]) -> [Entry] {
        return list.filter { isValidFolder($0.folder) }.sorted { $0.folder < $1.folder }
    }

    func entry(_ folder: String) -> Entry? { entries.first { $0.folder == folder } }

    // MARK: - Cache

    private func folderURL(_ folder: String) -> URL { cacheRoot.appendingPathComponent(folder, isDirectory: true) }

    /// Local animations.xml for a pet, if it was downloaded before.
    func cachedXML(for folder: String) -> URL? {
        guard Self.isValidFolder(folder) else { return nil }
        let url = folderURL(folder).appendingPathComponent("animations.xml")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// True if the cached copy matches the pet list's lastupdate (or the list does not know the pet).
    func isUpToDate(_ folder: String) -> Bool {
        guard cachedXML(for: folder) != nil else { return false }
        guard let e = entry(folder) else { return true }
        let stamp = try? String(contentsOf: folderURL(folder).appendingPathComponent("lastupdate"), encoding: .utf8)
        return stamp == e.lastupdate
    }

    // MARK: - Downloads (completions run on the main queue)

    private func get(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        session.dataTask(with: url) { data, response, error in
            let result: Result<Data, Error>
            if let error = error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(CatalogError.http(http.statusCode, url))
            } else {
                result = .success(data ?? Data())
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    func refreshIndex(completion: @escaping (Result<[Entry], Error>) -> Void) {
        get(Self.baseURL.appendingPathComponent("pets.json")) { [weak self] result in
            guard let self = self else { return }
            do {
                let data = try result.get()
                let index = try JSONDecoder().decode(Index.self, from: data)
                self.entries = Self.valid(index.pets)
                try FileManager.default.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)
                try data.write(to: self.indexURL, options: .atomic)
                completion(.success(self.entries))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Returns the local animations.xml for a pet, downloading it first when missing or outdated.
    /// If the download fails but an older copy is cached, that copy is used.
    func fetchPet(_ folder: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard Self.isValidFolder(folder) else { completion(.failure(CatalogError.badFolderName(folder))); return }
        if isUpToDate(folder), let url = cachedXML(for: folder) { completion(.success(url)); return }
        guard entry(folder) != nil else { completion(.failure(CatalogError.unknownPet(folder))); return }

        let remote = Self.baseURL.appendingPathComponent(folder).appendingPathComponent("animations.xml")
        get(remote) { [weak self] result in
            guard let self = self else { return }
            do {
                let data = try result.get()
                let def = try PetXML.load(data: data)     // only cache files that actually parse
                let dir = self.folderURL(folder)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let xml = dir.appendingPathComponent("animations.xml")
                try data.write(to: xml, options: .atomic)
                if let e = self.entry(folder) {
                    try e.lastupdate.write(to: dir.appendingPathComponent("lastupdate"), atomically: true, encoding: .utf8)
                    if !def.title.isEmpty {
                        self.titles[folder] = CachedTitle(title: def.title, lastupdate: e.lastupdate)
                        self.saveTitles()
                    }
                }
                completion(.success(xml))
            } catch {
                if let cached = self.cachedXML(for: folder) {
                    NSLog("DesktopPet: update of \(folder) failed, using cached copy: \(error)")
                    completion(.success(cached))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }
}
