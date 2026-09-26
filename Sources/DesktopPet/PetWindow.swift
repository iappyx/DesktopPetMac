import AppKit
import QuartzCore

/// Transparent, borderless, always-on-top window that hosts one animated pet.
/// This is a port of FormPet.cs; positions are kept in global top-left coordinates
/// and converted to AppKit coordinates only when the window is moved.
final class PetWindow: NSWindow {

    // MARK: - Configuration

    let pet: PetDefinition
    let sprites: SpriteSheet
    var scale: Int
    let isChild: Bool
    let childDepth: Int
    weak var manager: PetManager?

    // MARK: - Engine state (names follow the original)

    private var animationStep = 0
    private var current: PetAnimation
    private var currentWindow: DesktopGeometry.DesktopWindow?
    private var currentWindowFrame = CGRect.zero
    private var isMovingLeft = true
    private var isDragging = false
    private var isTossing = false
    private var isLeaving = false
    private var offsetY = 0.0
    private var positionX = 0.0
    private var positionY = 0.0
    private var prevPositionX = 0.0
    private var prevPositionY = 0.0
    private var tossForce = CGVector.zero
    private var tossVertVel = 0.0
    private var displayIndex = 0
    private var killOpacity = 1.0
    private var closed = false
    private var intervalMs = 200
    private let randS = Int.random(in: 10..<90)
    private var parentX = -1
    private var parentY = -1
    private var parentFlipped = false
    private var children: [PetWindow] = []

    private var timer: Timer?
    private let spriteLayer = CALayer()
    private let petView: PetView

    // MARK: - Init

    init(pet: PetDefinition, sprites: SpriteSheet, scale: Int, manager: PetManager?,
         parent: PetWindow? = nil) {
        self.pet = pet
        self.sprites = sprites
        self.scale = max(1, scale)
        self.manager = manager
        self.isChild = parent != nil
        self.childDepth = (parent?.childDepth ?? 0) + (parent == nil ? 0 : 1)
        self.current = pet.animation(pet.animationOrder.first ?? 1)
        let sc = max(1, scale)
        let w = CGFloat(sprites.frameWidth * sc)
        let h = CGFloat(sprites.frameHeight * sc)
        petView = PetView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.borderless], backing: .buffered, defer: false)

        if let p = parent {
            displayIndex = p.displayIndex
            parentX = Int(p.positionX)
            parentY = Int(p.positionY)
            parentFlipped = !p.isMovingLeft
            isMovingLeft = p.isMovingLeft
        } else {
            displayIndex = 0
        }

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isExcludedFromWindowsMenu = true
        animationBehavior = .none

        petView.wantsLayer = true
        petView.layer?.backgroundColor = NSColor.clear.cgColor
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        spriteLayer.position = CGPoint(x: w / 2, y: h / 2)
        petView.layer?.addSublayer(spriteLayer)
        petView.owner = self
        contentView = petView

        alphaValue = 0
        updateFlip()
    }

    required init?(coder: NSCoder) {
        fatalError("PetWindow does not support init(coder:)")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Screen helpers

    private var screenBounds: CGRect { DesktopGeometry.bounds(ofScreen: displayIndex) }
    private var screenArea: CGRect { DesktopGeometry.workingArea(ofScreen: displayIndex) }
    private var petWidth: Double { Double(sprites.frameWidth * scale) }
    private var petHeight: Double { Double(sprites.frameHeight * scale) }

    /// Bottom limit for the pet at its current x (Dock top or screen bottom).
    private func floorY(dx: Double = 0) -> Double {
        return DesktopGeometry.floorY(onScreen: displayIndex, petMinX: positionX + dx, petMaxX: positionX + dx + petWidth) - petHeight
    }

    private func context() -> ExpressionContext {
        let b = screenBounds
        let a = screenArea
        var c = ExpressionContext()
        c.screenW = Int(b.width)
        c.screenH = Int(b.height)
        c.areaW = Int(a.width)
        c.areaH = Int(a.minY - b.minY + a.height)
        c.imageW = sprites.frameWidth * scale
        c.imageH = sprites.frameHeight * scale
        c.imageX = parentX
        c.imageY = parentY
        c.random = Int.random(in: 0..<100)
        c.randS = randS
        c.scale = scale
        c.parentFlipped = parentFlipped
        return c
    }

    // MARK: - Public control

    /// Port of FormPet.Play(): choose a spawn point and start.
    func play(forceSpawn: Int = -1) {
        stopTimer()
        animationStep = 0
        currentWindow = nil
        if let m = manager, m.multiscreen, NSScreen.screens.count > 1 {
            displayIndex = Int.random(in: 0..<NSScreen.screens.count)
        }
        let spawn: PetSpawn
        if forceSpawn >= 0 && forceSpawn < pet.spawns.count {
            spawn = pet.spawns[forceSpawn]
        } else {
            spawn = pet.randomSpawn()
        }
        let ctx = context()
        let b = screenBounds
        let sx = Double(spawn.x.get(ctx))
        let sy = Double(spawn.y.get(ctx))
        positionY = Double(b.minY) + sy
        if isMovingLeft {
            positionX = Double(b.minX) + sx
        } else {
            positionX = Double(b.minX) - (sx - Double(b.width)) - petWidth
        }
        offsetY = 0
        isLeaving = false
        setNewAnimation(spawn.next)
        applyPosition()
        alphaValue = 0
        orderFrontRegardless()
        scheduleTimer(ms: intervalMs)
    }

    /// Port of FormPet.PlayChild().
    func playChild(_ child: PetChild) {
        stopTimer()
        animationStep = 0
        currentWindow = nil
        let ctx = context()
        let b = screenBounds
        positionX = Double(b.minX) + Double(child.x.get(ctx))
        positionY = Double(b.minY) + Double(child.y.get(ctx))
        offsetY = 0
        isLeaving = false
        setNewAnimation(child.next)
        applyPosition()
        alphaValue = 1
        orderFrontRegardless()
        scheduleTimer(ms: intervalMs)
    }

    /// Port of FormPet.Kill(): play the kill animation if there is one, otherwise close.
    func kill() {
        for c in children { c.closePet() }
        children.removeAll()
        if pet.animationKill > 1 {
            setNewAnimation(pet.animationKill)
        } else {
            closePet()
        }
    }

    func sync() {
        if pet.animationSync > 1 { setNewAnimation(pet.animationSync) }
    }

    func setScale(_ s: Int) {
        scale = max(1, s)
        let w = petWidth, h = petHeight
        setContentSize(NSSize(width: w, height: h))
        petView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        spriteLayer.position = CGPoint(x: w / 2, y: h / 2)
        applyPosition()
    }

    func closePet() {
        if closed { return }
        closed = true
        stopTimer()
        for c in children { c.closePet() }
        children.removeAll()
        orderOut(nil)
        close()
        manager?.petClosed(self)
    }

    // MARK: - Timer

    private func scheduleTimer(ms: Int) {
        stopTimer()
        let seconds = Double(max(1, ms)) / 1000.0
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !closed else { return }
        if animationStep < 0 { animationStep = 0 }
        nextStep()
        if closed { return }
        animationStep += 1
        scheduleTimer(ms: intervalMs)
    }

    // MARK: - Animation switching

    private func setNewAnimation(_ id: Int) {
        if pet.animationKill > 0 && current.id == pet.animationKill && !closed { return }
        if id < 0 {
            play()
            return
        }
        animationStep = -1
        current = pet.animation(id)
        current.updateValues(context())

        // Child pets spawned by this animation (max 5 levels deep).
        if let infos = pet.children[id], childDepth < 5 {
            for info in infos {
                let child = PetWindow(pet: pet, sprites: sprites, scale: scale, manager: manager, parent: self)
                children.append(child)
                child.playChild(info)
            }
        }
        intervalMs = current.start.interval.value
        showFrame(index: 0)
    }

    private func showFrame(index: Int) {
        let frames = current.sequence.frames
        guard !frames.isEmpty else { return }
        let i = min(max(index, 0), frames.count - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = sprites.frame(frames[i])
        CATransaction.commit()
    }

    private func updateFlip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.transform = isMovingLeft ? CATransform3DIdentity : CATransform3DMakeScale(-1, 1, 1)
        CATransaction.commit()
    }

    private func flipImages() {
        isMovingLeft.toggle()
        updateFlip()
    }

    private func applyPosition() {
        let r = CGRect(x: positionX, y: positionY + offsetY, width: petWidth, height: petHeight)
        setFrame(DesktopGeometry.appKit(r), display: true)
    }

    /// Port of CheckFullScreen(): drop below a full-screen window instead of covering it.
    private func checkFullScreen() {
        if DesktopGeometry.hasFullscreenWindow(onScreen: displayIndex) {
            if level != .normal { level = .normal }
        } else if level != .floating {
            level = .floating
        }
    }

    // MARK: - The step function (port of NextStep)

    private func nextStep() {
        let seq = current.sequence
        let frameCount = seq.frames.count
        guard frameCount > 0 else { return }

        // Which frame to show.
        if animationStep < frameCount {
            showFrame(index: animationStep)
        } else {
            let span = max(1, frameCount - seq.repeatFrom)
            let index = ((animationStep - frameCount + seq.repeatFrom) % span) + seq.repeatFrom
            showFrame(index: index)
        }

        let total = max(1, seq.totalSteps)
        if !isTossing {
            intervalMs = current.start.interval.value +
                ((current.end.interval.value - current.start.interval.value) * animationStep / total)
        }
        alphaValue = CGFloat(current.start.opacity + (current.end.opacity - current.start.opacity) * Double(animationStep) / Double(total))
        offsetY = Double(current.start.offsetY + ((current.end.offsetY - current.start.offsetY) * animationStep / total))

        // Dragging: follow the mouse.
        if isDragging {
            prevPositionX = positionX
            prevPositionY = positionY
            let m = DesktopGeometry.mouseLocation
            positionX = Double(m.x) - petWidth / 2
            positionY = Double(m.y) - 2
            applyPosition()
            return
        }

        let area = screenArea

        // Toss physics.
        if isTossing {
            let hittingLeft = positionX + Double(tossForce.dx) <= Double(area.minX)
            let hittingRight = positionX + Double(tossForce.dx) >= Double(area.maxX) - petWidth
            let hittingTaskbar = positionY + tossVertVel >= floorY(dx: Double(tossForce.dx))
            let windowTop = fallDetect(Int(tossVertVel))

            if hittingLeft || hittingRight {
                tossForce.dx = -tossForce.dx * 0.3
                positionX = hittingLeft ? Double(area.minX) : Double(area.maxX) - petWidth
                applyPosition()
                return
            }
            if hittingTaskbar || windowTop > 0 {
                positionY = hittingTaskbar ? floorY(dx: Double(tossForce.dx)) : Double(windowTop) - petHeight
                if (tossForce.dx < 0 && !isMovingLeft) || (tossForce.dx > 0 && isMovingLeft) {
                    flipImages()
                }
                setNewAnimation(tossVertVel < 40 ? pet.animationFallSoft : pet.animationFallHard)
                showFrame(index: 0)
                isTossing = false
                applyPosition()
                return
            }
            positionX = (positionX + Double(tossForce.dx)).rounded(.towardZero)
            positionY = (positionY + tossVertVel).rounded(.towardZero)
            tossVertVel += 1.5
            applyPosition()
            return
        }

        var x = Double(current.start.x.value)
        var y = Double(current.start.y.value)
        if total > 1 {
            x += Double(current.end.x.value - current.start.x.value) * Double(animationStep) / (Double(total) - 1.0)
            y += Double(current.end.y.value - current.start.y.value) * Double(animationStep) / (Double(total) - 1.0)
        }

        var newAnimation = false
        var leavingScreen = false

        if !isMovingLeft { x = -x }

        // ---- Horizontal borders ----
        if x < 0 {
            if currentWindow == nil {
                checkFullScreen()
                if positionX + x < Double(area.minX) {
                    let next = pet.nextBorderAnimation(current.id, where: .vertical)
                    if next >= 0 {
                        positionX = Double(area.minX)
                        x = 0
                        setNewAnimation(next)
                        newAnimation = true
                    } else {
                        leavingScreen = true
                    }
                }
            } else if let rct = DesktopGeometry.frame(ofWindow: currentWindow!.id) {
                if positionX + x < Double(rct.minX) {
                    let next = pet.nextBorderAnimation(current.id, where: .window)
                    if next >= 0 {
                        positionX = Double(rct.minX)
                        x = 0
                        setNewAnimation(next)
                        newAnimation = true
                    } else {
                        currentWindow = nil
                    }
                }
            } else {
                currentWindow = nil
            }
        } else if x > 0 {
            if currentWindow == nil {
                checkFullScreen()
                if positionX + x + petWidth > Double(area.maxX) {
                    let next = pet.nextBorderAnimation(current.id, where: .vertical)
                    if next >= 0 {
                        positionX = Double(area.maxX) - petWidth
                        x = 0
                        setNewAnimation(next)
                        newAnimation = true
                    } else {
                        leavingScreen = true
                    }
                }
            } else if let rct = DesktopGeometry.frame(ofWindow: currentWindow!.id) {
                if positionX + x + petWidth > Double(rct.maxX) {
                    let next = pet.nextBorderAnimation(current.id, where: .window)
                    if next >= 0 {
                        positionX = Double(rct.maxX) - petWidth
                        x = 0
                        setNewAnimation(next)
                        newAnimation = true
                    } else {
                        currentWindow = nil
                    }
                }
            } else {
                currentWindow = nil
            }
        }

        // ---- Vertical borders ----
        if newAnimation || leavingScreen {
            // nothing more to check
        } else if y > 0 {
            let floor = floorY(dx: x)
            if positionY + y > floor {
                let next = pet.nextBorderAnimation(current.id, where: .taskbar)
                if next >= 0 {
                    positionY = floor
                    offsetY = 0
                    y = 0
                    setNewAnimation(next)
                    newAnimation = true
                }
            } else {
                let windowTop = fallDetect(Int(y))
                if windowTop > 0 {
                    let next = pet.nextBorderAnimation(current.id, where: .window)
                    if next >= 0 {
                        positionY = Double(windowTop) - petHeight
                        offsetY = 0
                        y = 0
                        setNewAnimation(next)
                        newAnimation = true
                        if current.start.y.value != 0 { currentWindow = nil }
                    }
                }
            }
        } else if y < 0 {
            if positionY + y < Double(area.minY) {
                let next = pet.nextBorderAnimation(current.id, where: .horizontal)
                if next >= 0 {
                    positionY = Double(area.minY)
                    y = 0
                    setNewAnimation(next)
                    newAnimation = true
                } else {
                    leavingScreen = true
                }
            }
        }

        // ---- End of sequence ----
        if animationStep >= seq.totalSteps {
            var nextAni: Int
            if seq.action == "flip" { flipImages() }

            if currentWindow != nil {
                nextAni = pet.nextSequenceAnimation(current.id, where: .window)
            } else {
                let b = screenBounds
                if positionX < Double(b.minX) - petWidth || positionX > Double(b.maxX) {
                    nextAni = -1
                } else if positionY < Double(b.minY) - petHeight || positionY > Double(b.maxY) {
                    nextAni = -1
                } else {
                    let onTaskbar = positionY + y >= floorY() - 2
                    nextAni = pet.nextSequenceAnimation(current.id, where: onTaskbar ? .taskbar : .anywhere)
                }
            }

            if pet.animationKill > 0 && current.id == pet.animationKill {
                killOpacity -= 0.1
                alphaValue = CGFloat(max(0, killOpacity))
                if killOpacity <= 0.1 {
                    closePet()
                    return
                }
            } else if nextAni >= 0 {
                setNewAnimation(nextAni)
                newAnimation = true
            } else if isChild {
                closePet()
                return
            } else {
                play()
                return
            }
        }
        // ---- Gravity ----
        else if current.hasGravity {
            if currentWindow == nil {
                let floor = floorY(dx: x)
                if positionY + y < floor {
                    if positionY + y + 3 >= floor {
                        y = floor - positionY
                    } else {
                        setNewAnimation(pet.nextGravityAnimation(current.id, where: .anywhere))
                        newAnimation = true
                    }
                }
            } else if animationStep > 0 {
                if let rct = DesktopGeometry.frame(ofWindow: currentWindow!.id) {
                    if rct != currentWindowFrame {
                        // The window we stand on moved or resized: follow it.
                        if current.start.x.value != 0 || abs(x) > 0 {
                            followWindow(newFrame: rct)
                            applyPosition()
                            return
                        }
                        currentWindow = nil
                        setNewAnimation(pet.nextGravityAnimation(current.id, where: .window))
                        newAnimation = true
                    } else if DesktopGeometry.isTopEdgeCovered(of: currentWindow!, atX: positionX, width: petWidth) {
                        currentWindow = nil
                        setNewAnimation(pet.nextGravityAnimation(current.id, where: .window))
                        newAnimation = true
                    }
                } else {
                    // Window disappeared.
                    currentWindow = nil
                    setNewAnimation(pet.nextGravityAnimation(current.id, where: .window))
                    newAnimation = true
                }
            }
        }

        if newAnimation {
            intervalMs = 1
            showFrame(index: 0)
        }

        positionX += x
        positionY += y
        isLeaving = leavingScreen
        applyPosition()
    }

    // MARK: - Window interaction (ports of FallDetect / FollowWindow)

    /// Returns the top edge (global y) of a window the pet would land on while moving down by `dy`, or -1.
    private func fallDetect(_ dy: Int) -> Int {
        checkFullScreen()
        let area = screenArea
        let bottom = positionY + petHeight
        for w in DesktopGeometry.otherWindows() {
            let rct = w.frame
            if bottom < Double(rct.minY) && bottom + Double(dy) >= Double(rct.minY) &&
                positionX >= Double(rct.minX) - petWidth / 2 && positionX + petWidth <= Double(rct.maxX) + petWidth / 2 &&
                positionY > 20 + Double(area.minY) {
                if !DesktopGeometry.isTopEdgeCovered(of: w, atX: positionX, width: petWidth) {
                    currentWindow = w
                    currentWindowFrame = rct
                    return Int(rct.minY)
                }
            }
        }
        return -1
    }

    private func followWindow(newFrame rct: CGRect) {
        let old = currentWindowFrame
        positionY -= Double(old.minY - rct.minY)
        if rct.width == old.width || old.width == 0 {
            positionX -= Double(old.minX - rct.minX)
        } else {
            positionX = Double(rct.minX) + (positionX - Double(old.minX)) * Double(rct.width) / Double(old.width)
        }
        currentWindowFrame = rct
    }

    // MARK: - Mouse (called by PetView)

    func petMouseDown(_ event: NSEvent) {
        guard !isChild else { return }
        currentWindow = nil
        isDragging = true
        isTossing = false
        setNewAnimation(pet.animationDrag)
        orderFrontRegardless()
    }

    func petMouseDragged(_ event: NSEvent) {
        guard isDragging else { return }
        let m = DesktopGeometry.mouseLocation
        let r = CGRect(x: Double(m.x) - petWidth / 2, y: Double(m.y) - 2 + offsetY, width: petWidth, height: petHeight)
        setFrame(DesktopGeometry.appKit(r), display: true)
    }

    func petMouseUp(_ event: NSEvent) {
        guard !isChild, isDragging else { return }
        let ms = Double(max(1, intervalMs))
        let fx = (positionX - prevPositionX) / ms * 10
        let fy = (positionY - prevPositionY) / ms * 10
        tossForce = CGVector(dx: CGFloat(fx), dy: CGFloat(fy))
        let length = (fx * fx + fy * fy).squareRoot()
        if length > 5 {
            if pet.animationToss != -1 { setNewAnimation(pet.animationToss) }
            isTossing = true
            tossVertVel = Double(tossForce.dy)
            intervalMs = 30
        } else {
            setNewAnimation(pet.animationFall)
        }
        // Adopt the screen the pet was dropped on.
        let center = CGPoint(x: positionX + petWidth / 2, y: positionY + petHeight / 2)
        if let idx = DesktopGeometry.screenIndex(containing: center) { displayIndex = idx }
        isDragging = false
    }

    func petRightClick(_ event: NSEvent) {
        let menu = NSMenu()
        let title = NSMenuItem(title: "\(pet.petName) – \(current.name) (#\(current.id))", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove this pet", action: #selector(menuRemove), keyEquivalent: "").target = self

        let debug = NSMenu()
        let add: (String, [PetNext]) -> Void = { name, list in
            let sub = NSMenu()
            for n in list {
                let label = "#\(n.id) \(self.pet.animation(n.id).name)  (p=\(n.probability))"
                let item = NSMenuItem(title: label, action: #selector(self.menuJump(_:)), keyEquivalent: "")
                item.target = self
                item.tag = n.id
                sub.addItem(item)
            }
            let entry = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            entry.submenu = sub
            entry.isEnabled = !list.isEmpty
            debug.addItem(entry)
        }
        add("Next", current.endAnimation)
        add("Border", current.endBorder)
        add("Gravity", current.endGravity)
        let spawnMenu = NSMenu()
        for (i, s) in pet.spawns.enumerated() {
            let item = NSMenuItem(title: "Spawn #\(s.id) → \(pet.animation(s.next).name) (p=\(s.probability))",
                                  action: #selector(menuSpawn(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            spawnMenu.addItem(item)
        }
        let spawnEntry = NSMenuItem(title: "Spawns", action: nil, keyEquivalent: "")
        spawnEntry.submenu = spawnMenu
        debug.addItem(spawnEntry)
        let debugEntry = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugEntry.submenu = debug
        menu.addItem(debugEntry)

        NSMenu.popUpContextMenu(menu, with: event, for: petView)
    }

    @objc private func menuRemove() { kill() }
    @objc private func menuJump(_ sender: NSMenuItem) { setNewAnimation(sender.tag) }
    @objc private func menuSpawn(_ sender: NSMenuItem) { play(forceSpawn: sender.tag) }
}

/// Content view forwarding mouse events to the pet window.
final class PetView: NSView {
    weak var owner: PetWindow?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { owner?.petMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { owner?.petMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { owner?.petMouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { owner?.petRightClick(event) }
}
