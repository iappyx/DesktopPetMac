import Foundation

/// A value from the XML that may be a constant or an expression (C# TValue).
struct PetValue {
    var compute: String
    var isDynamic: Bool
    var isScreen: Bool
    var value: Int

    init(_ text: String?, _ ctx: ExpressionContext) {
        let t = (text ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)
        compute = t.isEmpty ? "0" : t
        isDynamic = Expression.isDynamic(compute)
        isScreen = Expression.isScreen(compute)
        value = Expression.evaluate(compute, ctx)
    }

    static let zero = PetValue("0", ExpressionContext())

    /// Re-evaluates if dynamic / screen dependent, otherwise returns the cached value.
    func get(_ ctx: ExpressionContext) -> Int {
        if isDynamic || isScreen { return Expression.evaluate(compute, ctx) }
        return value
    }
}

struct PetMovement {
    var x = PetValue.zero
    var y = PetValue.zero
    var interval = PetValue("1000", ExpressionContext())
    var offsetY = 0
    var opacity = 1.0
}

/// Where the pet must be for a <next> to be eligible (C# TNextAnimation.TOnly).
struct PetOnly: OptionSet {
    let rawValue: Int
    static let taskbar    = PetOnly(rawValue: 0x01)
    static let window     = PetOnly(rawValue: 0x02)
    static let horizontal = PetOnly(rawValue: 0x04)
    static let horizontalPlus = PetOnly(rawValue: 0x06)
    static let vertical   = PetOnly(rawValue: 0x08)
    static let anywhere   = PetOnly(rawValue: 0x7F)

    static func parse(_ s: String?) -> PetOnly {
        switch s ?? "" {
        case "taskbar": return .taskbar
        case "window": return .window
        case "horizontal": return .horizontal
        case "horizontal+": return .horizontalPlus
        case "vertical": return .vertical
        default: return .anywhere
        }
    }
}

struct PetNext {
    var id: Int
    var probability: Int
    var only: PetOnly
}

struct PetSequence {
    var repeatCount = PetValue.zero
    var repeatFrom = 0
    var frames: [Int] = []
    var totalSteps = 1
    var action = ""

    func calculateTotalSteps(_ ctx: ExpressionContext) -> Int {
        return frames.count + (frames.count - repeatFrom) * repeatCount.get(ctx)
    }
}

struct PetAnimation {
    var id: Int
    var name: String
    var start = PetMovement()
    var end = PetMovement()
    var sequence = PetSequence()
    var endAnimation: [PetNext] = []
    var endBorder: [PetNext] = []
    var endGravity: [PetNext] = []
    var hasGravity = false
    var hasBorder = false

    /// Port of TAnimation.UpdateValues(): re-evaluate dynamic values and apply the pixel scale.
    mutating func updateValues(_ ctx: ExpressionContext) {
        if sequence.repeatCount.isDynamic {
            sequence.totalSteps = sequence.calculateTotalSteps(ctx)
        }
        if start.interval.isDynamic || start.x.isDynamic || start.y.isDynamic || start.x.isScreen || start.y.isScreen {
            start.interval.value = start.interval.get(ctx)
            start.x.value = start.x.get(ctx)
            start.y.value = start.y.get(ctx)
        }
        if end.interval.isDynamic || end.x.isDynamic || end.y.isDynamic || end.x.isScreen || end.y.isScreen {
            end.interval.value = end.interval.get(ctx)
            end.x.value = end.x.get(ctx)
            end.y.value = end.y.get(ctx)
        }
        if ctx.scale > 1 {
            let s = ctx.scale
            start.x.value *= s; start.y.value *= s
            end.x.value *= s; end.y.value *= s
            start.offsetY *= s; end.offsetY *= s
        }
    }
}

struct PetSpawn {
    var id: Int
    var probability: Int
    var x = PetValue.zero
    var y = PetValue.zero
    var next = 1
}

struct PetChild {
    var animationID: Int
    var x = PetValue.zero
    var y = PetValue.zero
    var next = 1
}

struct PetSound {
    var animationID: Int
    var probability: Int
    var loop: Int
    var data: Data
}

/// Everything parsed from one animations.xml (C# Animations + parts of Xml).
final class PetDefinition {
    var author = ""
    var title = ""
    var petName = "Pet"
    var version = ""
    var info = ""
    var iconData: Data?

    var pngData = Data()
    var tilesX = 1
    var tilesY = 1

    var animations: [Int: PetAnimation] = [:]
    var animationOrder: [Int] = []
    var spawns: [PetSpawn] = []
    var children: [Int: [PetChild]] = [:]
    var sounds: [Int: PetSound] = [:]

    var animationDrag = 1
    var animationFall = 1
    var animationKill = -1
    var animationSync = 1
    var animationToss = -1
    var animationFallSoft = 1
    var animationFallHard = 1

    // MARK: next-animation selection (C# SetNextGeneralAnimation)

    private func pick(_ list: [PetNext], where place: PetOnly) -> Int {
        guard !list.isEmpty else { return -1 }
        var total = 0
        for n in list {
            if n.only != .anywhere && n.only.intersection(place).isEmpty { continue }
            total += n.probability
        }
        guard total > 0 else { return -1 }
        let r = Int.random(in: 1...total)
        var sum = 0
        var chosen = -1
        for n in list {
            if n.only != .anywhere && n.only.intersection(place).isEmpty { continue }
            sum += n.probability
            if sum >= r { chosen = n.id; break }
        }
        if chosen > 0, let snd = sounds[chosen], Int.random(in: 0..<100) < snd.probability {
            SoundPlayer.shared.play(snd)
        }
        return chosen
    }

    func nextBorderAnimation(_ id: Int, where place: PetOnly) -> Int {
        return pick(animations[id]?.endBorder ?? [], where: place)
    }
    func nextSequenceAnimation(_ id: Int, where place: PetOnly) -> Int {
        return pick(animations[id]?.endAnimation ?? [], where: place)
    }
    func nextGravityAnimation(_ id: Int, where place: PetOnly) -> Int {
        return pick(animations[id]?.endGravity ?? [], where: place)
    }

    func randomSpawn() -> PetSpawn {
        guard !spawns.isEmpty else {
            return PetSpawn(id: 0, probability: 100, x: .zero, y: .zero, next: animationOrder.first ?? 1)
        }
        let total = spawns.reduce(0) { $0 + $1.probability }
        let r = total > 0 ? Int.random(in: 0..<total) : 0
        var sum = 0
        for s in spawns {
            sum += s.probability
            if sum >= r { return s }
        }
        return spawns[0]
    }

    func animation(_ id: Int) -> PetAnimation {
        if let a = animations[id] { return a }
        var a = PetAnimation(id: 0, name: "NULL")
        a.start.interval.value = 1000
        a.end.interval.value = 1000
        a.sequence.frames = [0]
        return a
    }
}
