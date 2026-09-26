import Foundation

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
    }

    private var indexURL: URL { cacheRoot.appendingPathComponent("pets.json") }

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
                _ = try PetXML.load(data: data)           // only cache files that actually parse
                let dir = self.folderURL(folder)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let xml = dir.appendingPathComponent("animations.xml")
                try data.write(to: xml, options: .atomic)
                if let e = self.entry(folder) {
                    try e.lastupdate.write(to: dir.appendingPathComponent("lastupdate"), atomically: true, encoding: .utf8)
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
