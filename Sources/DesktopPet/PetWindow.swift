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
    private var dragAnchor = CGPoint.zero
    private var dragVelocity = DragVelocity()
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
    var childPets: [PetWindow] { children }

    private var timer: Timer?

    // Smooth presentation (upstream #161): the engine moves positionX/Y once per animation frame; the window
    // glides between those positions on a separate ~60 Hz timer. Tossing and window following run there too.
    private var motion = MotionTrack()
    private var motionTimer: Timer?
    private var tossUpdatedAt = 0.0
    private var lastFollowCheck = 0.0
    private var lastWindowMove = -1000.0
    private static func now() -> Double { CACurrentMediaTime() * 1000 }
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

    /// Called when displays are added, removed or rearranged (port of upstream RecoverDisplayLayout, #161):
    /// re-resolve the display index and bring a pet that ended up off-screen back onto the desktop.
    func recoverDisplayLayout() {
        guard !closed else { return }
        let frame = CGRect(x: positionX, y: positionY + offsetY, width: petWidth, height: petHeight)
        displayIndex = DesktopGeometry.nearestScreenIndex(to: frame)
        let area = screenArea
        if isDragging || frame.intersects(area) { return }
        currentWindow = nil
        isLeaving = false
        let x = min(max(frame.minX, area.minX), area.maxX - petWidth)
        let y = min(max(frame.minY, area.minY), area.maxY - petHeight)
        positionX = x
        positionY = y - offsetY
        applyPosition()
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
        stopMotionTimer()
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
        pet.startSound(id)

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

    /// Places the window at the engine position immediately (spawn, drag, resize, recovery).
    private func applyPosition() {
        motion.reset(CGPoint(x: positionX, y: positionY + offsetY), now: Self.now())
        render(Self.now())
    }

    /// Glides the window to the engine position over `ms` milliseconds (one animation step).
    private func queueMotion(_ ms: Int) {
        let now = Self.now()
        if !motion.initialized { motion.reset(CGPoint(x: frame.minX, y: DesktopGeometry.topLeft(frame).minY), now: now) }
        motion.move(to: CGPoint(x: positionX, y: positionY + offsetY), now: now, milliseconds: Double(ms))
        startMotionTimer()
    }

    private func render(_ now: Double) {
        let p = motion.sample(now)
        let r = CGRect(x: p.x.rounded(), y: p.y.rounded(), width: petWidth, height: petHeight)
        let target = DesktopGeometry.appKit(r)
        if frame != target { setFrame(target, display: false) }
    }

    private func startMotionTimer() {
        guard motionTimer == nil, !closed else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.motionTick() }
        RunLoop.main.add(t, forMode: .common)
        motionTimer = t
    }

    private func stopMotionTimer() {
        motionTimer?.invalidate()
        motionTimer = nil
    }

    private func motionTick() {
        guard !closed else { stopMotionTimer(); return }
        let now = Self.now()
        if isDragging { return }                  // drag positions come from mouse events
        if isTossing {
            advanceToss(now)
        } else {
            if currentWindow != nil && !isLeaving { followWindowIfMoved(now) }
            render(now)
        }
        // Keep running while gliding, flying, or standing on a window that might move.
        if !isTossing && !motion.isMoving(now) && currentWindow == nil { stopMotionTimer() }
    }

    /// Tracks the window the pet stands on. Polls fast while it is moving, slowly while it is still.
    private func followWindowIfMoved(_ now: Double) {
        let interval = now - lastWindowMove < 500 ? 0.0 : 100.0
        guard now - lastFollowCheck >= interval, let w = currentWindow else { return }
        lastFollowCheck = now
        guard let rct = DesktopGeometry.frame(ofWindow: w.id) else { return }   // gone: nextStep handles it
        if rct != currentWindowFrame {
            followWindow(newFrame: rct)
            lastWindowMove = now
        }
    }

    /// Time-based toss physics (port of upstream AdvanceToss, #161). Force units stay "pixels per 30 ms";
    /// pauses are capped at 50 ms so a stalled UI cannot teleport the pet.
    private func advanceToss(_ now: Double) {
        let dt = max(0, min(50, now - tossUpdatedAt)) / 30.0
        tossUpdatedAt = now
        if dt == 0 { return }
        let area = screenArea
        var nextX = positionX + Double(tossForce.dx) * dt
        let left = Double(area.minX), right = Double(area.maxX) - petWidth
        if nextX < left || nextX > right {
            // Bounce, and use up the remaining travel instead of pausing a frame.
            let edge = nextX < left ? left : right
            nextX = edge - (nextX - edge) * 0.3
            tossForce.dx *= -0.3
        }
        positionX = max(left, min(right, nextX))
        let dy = tossVertVel * dt + 0.75 * dt * dt
        tossVertVel += 1.5 * dt
        var ground = floorY()
        var land = positionY + dy >= ground
        let windowTop = dy > 0 ? fallDetect(Int(dy.rounded(.up))) : -1
        if windowTop != -1 && Double(windowTop) - petHeight <= ground {
            ground = Double(windowTop) - petHeight
            land = true
        } else {
            currentWindow = nil
        }
        positionY = land ? ground : positionY + dy
        offsetY = 0
        applyPosition()
        if land {
            if (tossForce.dx < 0 && !isMovingLeft) || (tossForce.dx > 0 && isMovingLeft) {
                flipImages()
            }
            isTossing = false
            setNewAnimation(tossVertVel < 40 ? pet.animationFallSoft : pet.animationFallHard)
            showFrame(index: 0)
        }
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
        let movementDuration = intervalMs
        alphaValue = CGFloat(current.start.opacity + (current.end.opacity - current.start.opacity) * Double(animationStep) / Double(total))
        offsetY = Double(current.start.offsetY + ((current.end.offsetY - current.start.offsetY) * animationStep / total))

        // Dragging: the position follows mouse events (petMouseDragged), not animation frames.
        if isDragging {
            offsetY = 0
            return
        }

        let area = screenArea

        // Toss physics run on the motion timer (advanceToss), not on animation frames.
        if isTossing { return }

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
                        // The window we stand on moved or resized: follow it (usually the motion timer already did).
                        followWindow(newFrame: rct)
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
        queueMotion(movementDuration)
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
        let ratio = old.width > 0 ? Double(rct.width / old.width) : 1
        let dy = Double(rct.minY - old.minY)
        positionX = Double(rct.minX) + (positionX - Double(old.minX)) * ratio
        positionY += dy
        motion.follow(oldLeft: Double(old.minX), newLeft: Double(rct.minX), ratio: ratio, dy: dy)
        render(Self.now())
        currentWindowFrame = rct
        if let w = currentWindow {
            currentWindow = DesktopGeometry.DesktopWindow(id: w.id, ownerPID: w.ownerPID, ownerName: w.ownerName,
                                                          title: w.title, frame: rct)
        }
    }

    // MARK: - Mouse (called by PetView)

    func petMouseDown(_ event: NSEvent) {
        guard !isChild else { return }
        currentWindow = nil
        isDragging = true
        isTossing = false
        // Keep the exact grab point, like dragging a normal window (upstream #161).
        positionY += offsetY
        offsetY = 0
        let m = DesktopGeometry.mouseLocation
        dragAnchor = CGPoint(x: Double(m.x) - positionX, y: Double(m.y) - positionY)
        dragVelocity.reset(x: positionX, y: positionY, at: event.timestamp)
        setNewAnimation(pet.animationDrag)
        orderFrontRegardless()
    }

    func petMouseDragged(_ event: NSEvent) {
        guard isDragging else { return }
        updateDragPosition(at: event.timestamp)
    }

    private func updateDragPosition(at time: TimeInterval) {
        let m = DesktopGeometry.mouseLocation
        positionX = Double(m.x - dragAnchor.x)
        positionY = Double(m.y - dragAnchor.y)
        offsetY = 0
        dragVelocity.add(x: positionX, y: positionY, at: time)
        applyPosition()
    }

    func petMouseUp(_ event: NSEvent) {
        guard !isChild, isDragging else { return }
        updateDragPosition(at: event.timestamp)
        tossForce = dragVelocity.tossForce(at: event.timestamp)
        let fx = Double(tossForce.dx), fy = Double(tossForce.dy)
        let length = (fx * fx + fy * fy).squareRoot()
        if length > 5 {
            if pet.animationToss != -1 { setNewAnimation(pet.animationToss) }
            isTossing = true
            tossVertVel = Double(tossForce.dy)
            tossUpdatedAt = Self.now()
            intervalMs = 30
            startMotionTimer()
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

/// Release velocity from recent timestamped drag samples (port of upstream DragVelocity, #161).
/// Force units match the original: pixels per millisecond × 10.
struct DragVelocity {
    private var samples: [(time: Double, x: Double, y: Double)] = []

    mutating func reset(x: Double, y: Double, at seconds: TimeInterval) {
        samples.removeAll()
        add(x: x, y: y, at: seconds)
    }

    mutating func add(x: Double, y: Double, at seconds: TimeInterval) {
        let now = seconds * 1000
        if let last = samples.last, now <= last.time { return }
        samples.append((now, x, y))
        while samples.count > 2 && samples[1].time <= now - 80 { samples.removeFirst() }
    }

    func tossForce(at seconds: TimeInterval) -> CGVector {
        let now = seconds * 1000
        guard samples.count >= 2, let first = samples.first, let last = samples.last else { return .zero }
        let elapsed = last.time - first.time
        // Too short to measure, or the mouse stopped before release: no toss.
        if elapsed < 8 || now - last.time > 80 { return .zero }
        return CGVector(dx: (last.x - first.x) / elapsed * 10, dy: (last.y - first.y) / elapsed * 10)
    }
}

/// Interpolates the window position between engine positions (port of upstream MotionTrack, #161).
/// Coordinates are global top-left; times are milliseconds.
struct MotionTrack {
    private var from = CGPoint.zero, to = CGPoint.zero
    private var started = 0.0, duration = 0.0
    private(set) var initialized = false

    mutating func reset(_ p: CGPoint, now: Double) {
        from = p; to = p
        started = now; duration = 0; initialized = true
    }

    func sample(_ now: Double) -> CGPoint {
        let t = duration <= 0 ? 1 : max(0, min(1, (now - started) / duration))
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    mutating func move(to p: CGPoint, now: Double, milliseconds: Double) {
        guard initialized else { reset(p, now: now); return }
        from = sample(now); to = p
        started = now; duration = max(1, milliseconds)
    }

    func isMoving(_ now: Double) -> Bool {
        return initialized && now < started + duration && from != to
    }

    /// Shifts the whole glide along with the window the pet stands on.
    mutating func follow(oldLeft: Double, newLeft: Double, ratio: Double, dy: Double) {
        from.x = newLeft + (from.x - oldLeft) * ratio
        to.x = newLeft + (to.x - oldLeft) * ratio
        from.y += dy; to.y += dy
    }
}
