import AppKit
import CoreGraphics

/// All pet logic runs in "global top-left" coordinates (same as Quartz/CGWindowList and the original
/// Windows code): origin at the top-left corner of the primary display, y grows downward.
/// AppKit uses bottom-left coordinates, so every NSWindow placement goes through these helpers.
enum DesktopGeometry {

    /// Height of the primary (menu-bar) display, needed to flip between AppKit and Quartz coordinates.
    static var primaryHeight: CGFloat {
        return NSScreen.screens.first?.frame.height ?? 0
    }

    /// Converts an AppKit (bottom-left) rect to a top-left rect.
    static func topLeft(_ r: NSRect) -> CGRect {
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Converts a top-left rect to an AppKit (bottom-left) rect.
    static func appKit(_ r: CGRect) -> NSRect {
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Mouse location in top-left coordinates.
    static var mouseLocation: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Equivalent of Screen.Bounds (whole display).
    static func bounds(ofScreen index: Int) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let s = screens[min(max(index, 0), screens.count - 1)]
        return topLeft(s.frame)
    }

    /// Equivalent of Screen.WorkingArea (display minus menu bar and Dock).
    static func workingArea(ofScreen index: Int) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let s = screens[min(max(index, 0), screens.count - 1)]
        return topLeft(s.visibleFrame)
    }

    /// Frame of the visible Dock if it sits at the bottom of the given screen, in top-left coordinates.
    /// Nil when the Dock is hidden, auto-hidden (off screen), or on the left/right edge.
    private static var cachedDock: CGRect?
    private static var cachedDockAt: TimeInterval = 0
    private static var cachedDockScreen = -1

    static func bottomDockFrame(onScreen index: Int) -> CGRect? {
        let now = Date().timeIntervalSinceReferenceDate
        if index == cachedDockScreen && now - cachedDockAt < 0.5 { return cachedDock }
        cachedDockScreen = index
        cachedDockAt = now
        cachedDock = nil

        // visibleFrame is authoritative for *whether* a Dock is reserved at the bottom and how tall it is.
        let b = bounds(ofScreen: index)
        let a = workingArea(ofScreen: index)
        let dockHeight = b.maxY - a.maxY
        guard dockHeight >= 4 else { return nil }          // hidden, auto-hidden, or on a side edge

        // Full-width fallback (what the Windows taskbar logic assumed).
        var dock = CGRect(x: b.minX, y: a.maxY, width: b.width, height: dockHeight)

        // Narrow it to the Dock's real horizontal extent if we can find its window.
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            var best: CGRect?
            for info in list {
                guard (info[kCGWindowOwnerName as String] as? String) == "Dock" else { continue }
                guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
                // Sits in the Dock band of this screen, wider than tall, but not the full screen width.
                guard r.width > r.height, r.width < b.width * 0.98, r.width > 100,
                      r.maxY >= a.maxY - 2, r.minY >= a.maxY - 80, r.minY <= a.maxY + 8,
                      r.midX > b.minX, r.midX < b.maxX else { continue }
                if best == nil || r.width > best!.width { best = r }
            }
            if let r = best {
                dock = CGRect(x: r.minX, y: a.maxY, width: r.width, height: dockHeight)
            }
        }
        cachedDock = dock
        return dock
    }

    /// The y coordinate the pet's feet rest on at the given horizontal span: the Dock's top edge when the
    /// pet is above the Dock, otherwise the bottom of the screen. (Windows' taskbar spans the full width;
    /// the macOS Dock does not, so the "taskbar" floor depends on x.)
    static func floorY(onScreen index: Int, petMinX: Double, petMaxX: Double) -> Double {
        let b = bounds(ofScreen: index)
        if let dock = bottomDockFrame(onScreen: index) {
            let w = petMaxX - petMinX
            if petMaxX > Double(dock.minX) + w * 0.3 && petMinX < Double(dock.maxX) - w * 0.3 {
                return Double(dock.minY)
            }
        }
        return Double(b.maxY)
    }

    static func screenIndex(containing p: CGPoint) -> Int? {
        for (i, _) in NSScreen.screens.enumerated() where bounds(ofScreen: i).contains(p) { return i }
        return nil
    }

    // MARK: - Other application windows

    /// A window of another application the pet may walk on.
    struct DesktopWindow {
        let id: CGWindowID
        let ownerPID: pid_t
        let ownerName: String
        let title: String
        /// Top-left global coordinates.
        let frame: CGRect
    }

    /// On-screen, normal-level windows of other apps, front-to-back (z-order), excluding our own process.
    /// Window titles require Screen Recording permission on macOS 10.15+; without it `title` is empty
    /// and detection still works on bounds alone.
    private static var cachedWindows: [DesktopWindow] = []
    private static var cachedAt: TimeInterval = 0

    static func otherWindows() -> [DesktopWindow] {
        let now = Date().timeIntervalSinceReferenceDate
        if now - cachedAt < 0.08 { return cachedWindows }
        cachedWindows = fetchWindows()
        cachedAt = now
        return cachedWindows
    }

    private static func fetchWindows() -> [DesktopWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [DesktopWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            // Skip tiny helper windows (tooltips, menu extras, etc.).
            if frame.width < 100 || frame.height < 60 { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info[kCGWindowName as String] as? String ?? ""
            let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            result.append(DesktopWindow(id: id, ownerPID: pid, ownerName: owner, title: title, frame: frame))
        }
        return result
    }

    /// Current frame of a window by id, or nil if it is gone / no longer on screen.
    static func frame(ofWindow id: CGWindowID) -> CGRect? {
        guard id != 0 else { return nil }
        return otherWindows().first { $0.id == id }?.frame
    }

    /// True if some other window in front of `window` overlaps its top edge around the pet's x position
    /// (port of CheckTopWindow's z-order walk).
    static func isTopEdgeCovered(of window: DesktopWindow, atX x: CGFloat, width: CGFloat) -> Bool {
        for w in otherWindows() {
            if w.id == window.id { return false }   // reached our window: nothing in front covers it
            let r = w.frame
            if r.minY < window.frame.minY && r.maxY > window.frame.minY {
                if r.minX < x && r.maxX > x + min(40, width) { return true }
            }
        }
        return false
    }

    /// True if the frontmost normal window fills the given screen (video playback etc.).
    static func hasFullscreenWindow(onScreen index: Int) -> Bool {
        let b = bounds(ofScreen: index)
        guard let front = otherWindows().first else { return false }
        let c = CGPoint(x: front.frame.midX, y: front.frame.midY)
        return b.contains(c) && front.frame.width >= b.width && front.frame.height >= b.height
    }
}
