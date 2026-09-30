import AppKit
import UniformTypeIdentifiers

/// Owns the loaded pet definition and every live pet window; drives the menu-bar item.
final class PetManager: NSObject {
    private(set) var definition: PetDefinition?
    private(set) var sheet: SpriteSheet?
    private(set) var pets: [PetWindow] = []
    private var statusItem: NSStatusItem?
    private let defaults = UserDefaults.standard

    var scale: Int {
        get { let v = defaults.integer(forKey: "scale"); return v == 0 ? 1 : max(1, min(4, v)) }
        set { defaults.set(newValue, forKey: "scale"); pets.forEach { $0.setScale(newValue) } }
    }
    var multiscreen: Bool {
        get { defaults.bool(forKey: "multiscreen") }
        set { defaults.set(newValue, forKey: "multiscreen") }
    }
    var soundEnabled: Bool {
        get { defaults.object(forKey: "sound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sound"); SoundPlayer.shared.enabled = newValue }
    }
    var currentPetFolder: String {
        get { defaults.string(forKey: "petFolder") ?? "esheep64" }
        set { defaults.set(newValue, forKey: "petFolder") }
    }

    // MARK: - Pet catalog (downloaded from the upstream repository)

    let catalog = PetCatalog()
    /// Shown as the menu header while something is downloading.
    private var status: String?
    private var indexFailed = false

    func refreshCatalog(completion: (() -> Void)? = nil) {
        status = "Updating pet list…"
        rebuildMenu()
        catalog.refreshIndex { [weak self] result in
            guard let self = self else { return }
            self.status = nil
            if case .failure(let error) = result {
                NSLog("DesktopPet: cannot refresh pet list: \(error)")
                self.indexFailed = true
            } else {
                self.indexFailed = false
            }
            self.rebuildMenu()
            completion?()
        }
    }

    /// Loads a pet from the catalog (downloading it if needed) and adds one instance of it.
    func selectPet(_ folder: String, onFailure: ((Error) -> Void)? = nil) {
        status = "Downloading \(folder)…"
        rebuildMenu()
        catalog.fetchPet(folder) { [weak self] result in
            guard let self = self else { return }
            self.status = nil
            do {
                try self.loadPet(at: result.get())
                self.currentPetFolder = folder
                self.addPet()
            } catch {
                self.rebuildMenu()
                if let onFailure = onFailure { onFailure(error) } else { self.presentError(error) }
            }
        }
    }

    // MARK: - Loading

    func loadPet(at url: URL) throws {
        let data = try Data(contentsOf: url)
        let def = try PetXML.load(data: data)
        let sh = try SpriteSheet(pet: def)
        removeAllPets()
        definition = def
        sheet = sh
        rebuildMenu()
    }

    func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not load pet"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Pets

    @discardableResult
    func addPet() -> PetWindow? {
        guard let def = definition, let sh = sheet else { return nil }
        let w = PetWindow(pet: def, sprites: sh, scale: scale, manager: self)
        pets.append(w)
        w.play()
        return w
    }

    func removeAllPets() {
        let list = pets
        pets.removeAll()
        list.forEach { $0.closePet() }
    }

    func killAllPets() {
        pets.forEach { $0.kill() }
    }

    func syncAllPets() {
        pets.forEach { $0.sync() }
    }

    func petClosed(_ w: PetWindow) {
        pets.removeAll { $0 === w }
    }

    // MARK: - Menu bar

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        rebuildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// A display was added, removed or rearranged: keep every pet (children too) on a screen that exists.
    @objc private func screensChanged() {
        func recover(_ w: PetWindow) {
            w.recoverDisplayLayout()
            w.childPets.forEach(recover)
        }
        pets.forEach(recover)
    }

    private func rebuildMenu() {
        guard let item = statusItem else { return }
        if let icon = sheet?.icon {
            icon.size = NSSize(width: 18, height: 18)
            item.button?.image = icon
            item.button?.image?.isTemplate = false
        } else if let img = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Desktop Pet") {
            item.button?.image = img
        } else {
            item.button?.title = "🐑"
        }

        let menu = NSMenu()
        let name = status ?? definition?.petName ?? "Desktop Pet"
        let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Add pet", action: #selector(menuAddPet), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Sync pets", action: #selector(menuSync), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove all pets", action: #selector(menuRemoveAll), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let petsMenu = NSMenu()
        if catalog.entries.isEmpty {
            let title = indexFailed ? "Pet list unavailable (offline?)" : "Loading pet list…"
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            petsMenu.addItem(mi)
        }
        for e in catalog.entries {
            let mi = NSMenuItem(title: e.folder, action: #selector(menuSelectPet(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = e.folder
            mi.state = (e.folder == currentPetFolder) ? .on : .off
            mi.toolTip = "by \(e.author), updated \(e.lastupdate)"
                + (catalog.cachedXML(for: e.folder) == nil ? " (will be downloaded)" : "")
            petsMenu.addItem(mi)
        }
        petsMenu.addItem(.separator())
        petsMenu.addItem(withTitle: "Refresh pet list", action: #selector(menuRefresh), keyEquivalent: "").target = self
        petsMenu.addItem(withTitle: "Open animations.xml…", action: #selector(menuOpenXML), keyEquivalent: "o").target = self
        let petsEntry = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        petsEntry.submenu = petsMenu
        menu.addItem(petsEntry)

        let scaleMenu = NSMenu()
        for s in 1...4 {
            let mi = NSMenuItem(title: "\(s)×", action: #selector(menuScale(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = s
            mi.state = (s == scale) ? .on : .off
            scaleMenu.addItem(mi)
        }
        let scaleEntry = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        scaleEntry.submenu = scaleMenu
        menu.addItem(scaleEntry)

        let sound = NSMenuItem(title: "Sounds", action: #selector(menuToggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = soundEnabled ? .on : .off
        menu.addItem(sound)

        let multi = NSMenuItem(title: "Use all displays", action: #selector(menuToggleMultiscreen), keyEquivalent: "")
        multi.target = self
        multi.state = multiscreen ? .on : .off
        menu.addItem(multi)

        menu.addItem(.separator())
        if let d = definition {
            let about = NSMenuItem(title: "About \(d.petName)…", action: #selector(menuAbout), keyEquivalent: "")
            about.target = self
            menu.addItem(about)
        }
        menu.addItem(withTitle: "Quit", action: #selector(menuQuit), keyEquivalent: "q").target = self
        item.menu = menu
    }

    @objc private func menuAddPet() { addPet() }
    @objc private func menuSync() { syncAllPets() }
    @objc private func menuRemoveAll() { killAllPets() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuSelectPet(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        selectPet(folder)
    }

    @objc private func menuRefresh() { refreshCatalog() }

    @objc private func menuOpenXML() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.xml]
        panel.message = "Choose a desktopPet animations.xml"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try loadPet(at: url)
                currentPetFolder = url.path
                addPet()
            } catch {
                presentError(error)
            }
        }
    }

    @objc private func menuScale(_ sender: NSMenuItem) {
        scale = sender.tag
        rebuildMenu()
    }

    @objc private func menuToggleSound() {
        soundEnabled.toggle()
        rebuildMenu()
    }

    @objc private func menuToggleMultiscreen() {
        multiscreen.toggle()
        rebuildMenu()
    }

    @objc private func menuAbout() {
        guard let d = definition else { return }
        let alert = NSAlert()
        alert.messageText = "\(d.title) \(d.version)"
        let info = d.info
            .replacingOccurrences(of: "[br]", with: "\n")
            .replacingOccurrences(of: "[link:", with: "")
            .replacingOccurrences(of: "]", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        alert.informativeText = "by \(d.author)\n\n\(info)"
        alert.accessoryView = appCreditView()
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "License…")
        if let icon = sheet?.icon { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { showLicense() }
    }

    /// LICENSE is hard-wrapped at ~78 columns; join those lines so the text view can wrap it to its own width.
    /// Copyright lines (and their indented continuation) keep their line breaks.
    static func reflow(_ text: String) -> String {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return paragraphs.map { para -> String in
            let lines = para.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if lines.first?.hasPrefix("Copyright") == true { return lines.joined(separator: "\n") }
            return lines.joined(separator: " ")
        }
        .joined(separator: "\n\n")
    }

    /// Shows the MIT license bundled in the app (build-app.sh copies LICENSE into Contents/Resources).
    private func showLicense() {
        let licenseURL = URL(string: "https://github.com/iappyx/DesktopPetMac/blob/main/LICENSE")!
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSWorkspace.shared.open(licenseURL)          // e.g. `swift run`, where there is no app bundle
            return
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.string = Self.reflow(text)
        view.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        view.isEditable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = view

        let alert = NSAlert()
        alert.messageText = "License"
        alert.window.initialFirstResponder = nil
        alert.informativeText = "Desktop Pet for macOS is licensed under the MIT License."
        alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// The app's own credit, set apart from the pet's info text by a divider.
    private func appCreditView() -> NSView {
        let width: CGFloat = 260
        let text = NSMutableAttributedString(
            string: "Desktop Pet for macOS\ngithub.com/iappyx/DesktopPetMac\n\n"
                + "Port of Adriano Petrucci's desktopPet.\n\n"
                + "MIT License\n"
                + "© Adriano Petrucci and the desktopPet contributors\n"
                + "© 2026 iappyx",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                          range: NSRange(location: 0, length: "Desktop Pet for macOS".count))
        let link = (text.string as NSString).range(of: "desktopPet")
        text.addAttribute(.link, value: URL(string: "https://github.com/Adrianotiger/desktopPet")!, range: link)
        let repo = (text.string as NSString).range(of: "github.com/iappyx/DesktopPetMac")
        text.addAttribute(.link, value: URL(string: "https://github.com/iappyx/DesktopPetMac")!, range: repo)

        let label = NSTextField(labelWithAttributedString: text)
        label.isSelectable = true               // needed for the link to be clickable
        label.allowsEditingTextAttributes = true
        label.preferredMaxLayoutWidth = width
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        let labelHeight = label.fittingSize.height

        let gap: CGFloat = 10
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: labelHeight + gap + 1))
        let divider = NSBox(frame: NSRect(x: 0, y: labelHeight + gap, width: width, height: 1))
        divider.boxType = .separator
        label.frame = NSRect(x: 0, y: 0, width: width, height: labelHeight)
        container.addSubview(divider)
        container.addSubview(label)
        return container
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = PetManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SoundPlayer.shared.enabled = manager.soundEnabled
        manager.installStatusItem()

        // Optional: path to an animations.xml as the first argument; otherwise the last used pet.
        let args = CommandLine.arguments.dropFirst()
        var localPath: String?
        if let path = args.first(where: { $0.hasSuffix(".xml") }) {
            localPath = path
        } else if manager.currentPetFolder.hasPrefix("/") {
            localPath = manager.currentPetFolder
        }
        if let path = localPath {
            do {
                try manager.loadPet(at: URL(fileURLWithPath: path))
            } catch {
                // An explicit argument deserves an error; a remembered file that has since moved does not.
                if path != manager.currentPetFolder { manager.presentError(error) }
                NSLog("DesktopPet: cannot load \(path): \(error)")
            }
        }

        if manager.definition != nil {
            manager.addPet()
            manager.refreshCatalog()
            return
        }

        // Catalog pet: start right away from the cache, then check for a newer version in the background
        // (used from the next launch or selection on).
        let folder = PetCatalog.isValidFolder(manager.currentPetFolder) ? manager.currentPetFolder : Self.defaultPet
        if let cached = manager.catalog.cachedXML(for: folder), (try? manager.loadPet(at: cached)) != nil {
            manager.addPet()
            manager.refreshCatalog { [manager] in
                if !manager.catalog.isUpToDate(folder) { manager.catalog.fetchPet(folder) { _ in } }
            }
            return
        }

        // Nothing cached yet (first launch): download the pet list, then the pet.
        manager.refreshCatalog { [manager] in
            let pick = manager.catalog.entry(folder) != nil ? folder : Self.defaultPet
            manager.selectPet(pick) { error in
                let alert = NSAlert()
                alert.messageText = "No pet could be loaded"
                alert.informativeText = "Pets are downloaded from github.com/Adrianotiger/desktopPet, "
                    + "which failed: \(error.localizedDescription)\n\n"
                    + "Check your internet connection and use the menu bar icon → Pet → Refresh pet list, "
                    + "or open a local animations.xml."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    static let defaultPet = "esheep64"

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
enum DesktopPetApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
