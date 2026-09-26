import Foundation

/// Minimal DOM built with Foundation's XMLParser.
final class XMLNode {
    let name: String
    var attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []
    weak var parent: XMLNode?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }
    func childText(_ name: String) -> String? {
        guard let c = child(name) else { return nil }
        return c.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func childInt(_ name: String, _ def: Int = 0) -> Int {
        guard let t = childText(name) else { return def }
        return Int(t) ?? Int(Double(t) ?? Double(def))
    }
    func childDouble(_ name: String, _ def: Double) -> Double {
        guard let t = childText(name) else { return def }
        return Double(t) ?? def
    }
    func attrInt(_ name: String, _ def: Int = 0) -> Int {
        guard let t = attributes[name] else { return def }
        return Int(t) ?? def
    }
}

final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var current: XMLNode?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        // Strip any namespace prefix ("ns:animation" -> "animation").
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let node = XMLNode(name: name, attributes: attributeDict)
        node.parent = current
        if let c = current { c.children.append(node) } else { root = node }
        current = node
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current?.text += string
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { current?.text += s }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        current = current?.parent
    }
}

enum PetXMLError: Error, LocalizedError {
    case parse(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .parse(let s): return "XML parse error: \(s)"
        case .missing(let s): return "animations.xml is missing <\(s)>"
        }
    }
}

enum PetXML {
    /// Decodes base64 that may carry a data-URL prefix and may lack padding (both occur in the wild).
    static func decodeBase64(_ raw: String) -> Data? {
        var s = raw.filter { !$0.isWhitespace }
        if let r = s.range(of: ";base64,") { s = String(s[r.upperBound...]) }
        let mod4 = s.count % 4
        if mod4 > 0 { s += String(repeating: "=", count: 4 - mod4) }
        return Data(base64Encoded: s)
    }

    static func load(data: Data, imageW: Int = 0, imageH: Int = 0) throws -> PetDefinition {
        let parser = XMLParser(data: data)
        let builder = XMLTreeBuilder()
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        if !parser.parse() {
            throw PetXMLError.parse(parser.parserError?.localizedDescription ?? "unknown")
        }
        guard let root = builder.root else { throw PetXMLError.missing("animations") }
        return try build(root: root)
    }

    private static func build(root: XMLNode) throws -> PetDefinition {
        let pet = PetDefinition()

        if let header = root.child("header") {
            pet.author = header.childText("author") ?? ""
            pet.title = header.childText("title") ?? ""
            pet.petName = String((header.childText("petname") ?? "Pet").prefix(16))
            pet.version = header.childText("version") ?? ""
            pet.info = header.childText("info") ?? ""
            if let ico = header.childText("icon") { pet.iconData = decodeBase64(ico) }
        }

        guard let image = root.child("image") else { throw PetXMLError.missing("image") }
        pet.tilesX = max(1, image.childInt("tilesx", 1))
        pet.tilesY = max(1, image.childInt("tilesy", 1))
        guard let pngText = image.childText("png"), let png = decodeBase64(pngText) else {
            throw PetXMLError.missing("image/png")
        }
        pet.pngData = png

        // Expressions are evaluated lazily against a real screen; constants are cached now.
        let ctx = ExpressionContext()

        guard let animations = root.child("animations") else { throw PetXMLError.missing("animations") }
        for node in animations.all("animation") {
            let id = node.attrInt("id")
            var ani = PetAnimation(id: id, name: node.childText("name") ?? "\(id)")
            switch ani.name {
            case "fall": pet.animationFall = id
            case "drag": pet.animationDrag = id
            case "kill": pet.animationKill = id
            case "sync": pet.animationSync = id
            case "toss": pet.animationToss = id
            case "fall soft": pet.animationFallSoft = id
            case "fall hard": pet.animationFallHard = id
            default: break
            }
            if let s = node.child("start") {
                ani.start.x = PetValue(s.childText("x"), ctx)
                ani.start.y = PetValue(s.childText("y"), ctx)
                ani.start.interval = PetValue(s.childText("interval") ?? "1000", ctx)
                ani.start.offsetY = s.childInt("offsety", 0)
                ani.start.opacity = s.childDouble("opacity", 1.0)
            }
            if let e = node.child("end") {
                ani.end.x = PetValue(e.childText("x"), ctx)
                ani.end.y = PetValue(e.childText("y"), ctx)
                ani.end.interval = PetValue(e.childText("interval") ?? "1000", ctx)
                ani.end.offsetY = e.childInt("offsety", 0)
                ani.end.opacity = e.childDouble("opacity", 1.0)
            }
            if let seq = node.child("sequence") {
                ani.sequence.repeatCount = PetValue(seq.attributes["repeat"] ?? "0", ctx)
                ani.sequence.repeatFrom = seq.attrInt("repeatfrom", 0)
                ani.sequence.action = seq.childText("action") ?? ""
                ani.sequence.frames = seq.all("frame").compactMap { Int($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                ani.endAnimation = seq.all("next").map(parseNext)
            }
            if ani.sequence.frames.isEmpty { ani.sequence.frames = [0] }
            let n = ani.sequence.frames.count
            let rep = ani.sequence.repeatCount.value
            if ani.sequence.repeatFrom > 0 {
                ani.sequence.totalSteps = n + (n - ani.sequence.repeatFrom - 1) * rep
            } else {
                ani.sequence.totalSteps = n + n * rep
            }
            ani.sequence.totalSteps = max(1, ani.sequence.totalSteps)
            if let b = node.child("border") {
                ani.hasBorder = true
                ani.endBorder = b.all("next").map(parseNext)
            }
            if let g = node.child("gravity") {
                ani.hasGravity = true
                ani.endGravity = g.all("next").map(parseNext)
            }
            pet.animations[id] = ani
            pet.animationOrder.append(id)
        }

        if let spawns = root.child("spawns") {
            for node in spawns.all("spawn") {
                var s = PetSpawn(id: node.attrInt("id"), probability: node.attrInt("probability", 100))
                s.x = PetValue(node.childText("x"), ctx)
                s.y = PetValue(node.childText("y"), ctx)
                s.next = node.childInt("next", 1)
                pet.spawns.append(s)
            }
        }

        if let childs = root.child("childs") {
            for node in childs.all("child") {
                let aid = node.attrInt("animationid")
                var c = PetChild(animationID: aid)
                c.x = PetValue(node.childText("x"), ctx)
                c.y = PetValue(node.childText("y"), ctx)
                c.next = node.childInt("next", 1)
                pet.children[aid, default: []].append(c)
            }
        }

        if let sounds = root.child("sounds") {
            for node in sounds.all("sound") {
                let aid = node.attrInt("animationid")
                guard let b64 = node.childText("base64"), let data = decodeBase64(b64) else { continue }
                pet.sounds[aid] = PetSound(animationID: aid,
                                           probability: node.childInt("probability", 100),
                                           loop: node.childInt("loop", 0),
                                           data: data)
            }
        }

        return pet
    }

    private static func parseNext(_ node: XMLNode) -> PetNext {
        let id = Int(node.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        return PetNext(id: id, probability: node.attrInt("probability", 100), only: PetOnly.parse(node.attributes["only"]))
    }
}
