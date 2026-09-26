import Foundation

/// Values that an animations.xml expression can reference.
/// Mirrors the substitutions done in Xml.ParseValue() of the original C# project.
struct ExpressionContext {
    var screenW: Int = 0
    var screenH: Int = 0
    var areaW: Int = 0
    /// Bottom edge of the working area, relative to the screen top (WorkingArea.Y + WorkingArea.Height).
    var areaH: Int = 0
    var imageW: Int = 0
    var imageH: Int = 0
    /// Parent position (only meaningful for child pets; -1 otherwise).
    var imageX: Int = -1
    var imageY: Int = -1
    /// Random 0...99 drawn once per evaluation (like C# Replace("random", rand.Next(0,100))).
    var random: Int = 0
    /// Random 10...89 fixed for the life of the pet.
    var randS: Int = 0
    var scale: Int = 1
    var parentFlipped: Bool = false
}

/// Numeric value that behaves like the C# DataTable engine: Int32 arithmetic stays integer
/// (truncating division), anything touching a double promotes to double.
enum Num {
    case int(Int)
    case double(Double)

    var asDouble: Double {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        }
    }
    var asInt: Int {
        switch self {
        case .int(let i): return i
        case .double(let d):
            if d.isNaN || d.isInfinite { return 0 }
            return Int(d.rounded(.towardZero))
        }
    }

    static func binary(_ op: Character, _ a: Num, _ b: Num) -> Num {
        if case .int(let x) = a, case .int(let y) = b {
            switch op {
            case "+": return .int(x &+ y)
            case "-": return .int(x &- y)
            case "*": return .int(x &* y)
            case "/": return .int(y == 0 ? 0 : x / y)
            case "%": return .int(y == 0 ? 0 : x % y)
            default: return .int(0)
            }
        }
        let x = a.asDouble, y = b.asDouble
        switch op {
        case "+": return .double(x + y)
        case "-": return .double(x - y)
        case "*": return .double(x * y)
        case "/": return .double(y == 0 ? 0 : x / y)
        case "%": return .double(y == 0 ? 0 : x.truncatingRemainder(dividingBy: y))
        default: return .double(0)
        }
    }
}

/// Tiny recursive-descent evaluator for the arithmetic subset of DataColumn.Expression used by pets:
/// + - * / %, parentheses, unary minus, integer and decimal literals, identifiers, and Convert(x, System.Int32).
struct Expression {
    enum Token: Equatable {
        case num(Num)
        case ident(String)
        case op(Character)
        case lparen, rparen, comma

        static func == (l: Token, r: Token) -> Bool {
            switch (l, r) {
            case (.lparen, .lparen), (.rparen, .rparen), (.comma, .comma): return true
            case (.op(let a), .op(let b)): return a == b
            case (.ident(let a), .ident(let b)): return a == b
            case (.num(let a), .num(let b)): return a.asDouble == b.asDouble
            default: return false
            }
        }
    }

    /// True if the text contains anything that changes at runtime (C# TValue.IsDynamic).
    static func isDynamic(_ text: String) -> Bool {
        return text.contains("random") || text.contains("randS") || text.contains("imageX") || text.contains("imageY")
    }
    /// True if the text depends on the screen (C# TValue.IsScreen).
    static func isScreen(_ text: String) -> Bool {
        return text.contains("screen") || text.contains("area")
    }

    static func evaluate(_ source: String, _ ctx: ExpressionContext) -> Int {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        // Fast path: plain integer.
        if let i = Int(text) { return i }

        // When a child is placed relative to a flipped parent, mirror imageW (same trick as the original).
        if ctx.parentFlipped {
            if text.contains("-imageW") {
                text = text.replacingOccurrences(of: "-imageW", with: "+imageW")
            } else {
                text = text.replacingOccurrences(of: "imageW", with: "(-imageW)")
            }
        }

        var parser = Parser(tokens: tokenize(text), ctx: ctx)
        let v = parser.parseExpression()
        return v.asInt
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var s = ""
                var isDouble = false
                while i < chars.count, chars[i].isNumber || chars[i] == "." {
                    if chars[i] == "." { isDouble = true }
                    s.append(chars[i]); i += 1
                }
                if isDouble { tokens.append(.num(.double(Double(s) ?? 0))) }
                else { tokens.append(.num(.int(Int(s) ?? 0))) }
                continue
            }
            if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "." {
                    s.append(chars[i]); i += 1
                }
                tokens.append(.ident(s))
                continue
            }
            switch c {
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case ",": tokens.append(.comma)
            case "+", "-", "*", "/", "%": tokens.append(.op(c))
            default: break // ignore anything unknown
            }
            i += 1
        }
        return tokens
    }

    struct Parser {
        var tokens: [Token]
        var pos = 0
        let ctx: ExpressionContext

        init(tokens: [Token], ctx: ExpressionContext) {
            self.tokens = tokens
            self.ctx = ctx
        }

        var current: Token? { pos < tokens.count ? tokens[pos] : nil }
        mutating func advance() { pos += 1 }

        mutating func parseExpression() -> Num {
            var lhs = parseTerm()
            while let t = current, case .op(let c) = t, c == "+" || c == "-" {
                advance()
                let rhs = parseTerm()
                lhs = Num.binary(c, lhs, rhs)
            }
            return lhs
        }

        mutating func parseTerm() -> Num {
            var lhs = parseUnary()
            while let t = current, case .op(let c) = t, c == "*" || c == "/" || c == "%" {
                advance()
                let rhs = parseUnary()
                lhs = Num.binary(c, lhs, rhs)
            }
            return lhs
        }

        mutating func parseUnary() -> Num {
            if let t = current, case .op(let c) = t {
                if c == "-" { advance(); return Num.binary("-", .int(0), parseUnary()) }
                if c == "+" { advance(); return parseUnary() }
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Num {
            guard let t = current else { return .int(0) }
            switch t {
            case .num(let n):
                advance(); return n
            case .lparen:
                advance()
                let v = parseExpression()
                if current == .rparen { advance() }
                return v
            case .ident(let name):
                advance()
                if name.lowercased() == "convert" {
                    // Convert(expr, System.Int32) -> truncate to int
                    if current == .lparen { advance() }
                    let v = parseExpression()
                    if current == .comma { advance() }
                    if let tt = current, case .ident = tt { advance() }
                    if current == .rparen { advance() }
                    return .int(v.asInt)
                }
                return lookup(name)
            default:
                advance(); return .int(0)
            }
        }

        func lookup(_ name: String) -> Num {
            switch name {
            case "screenW": return .int(ctx.screenW)
            case "screenH": return .int(ctx.screenH)
            case "areaW": return .int(ctx.areaW)
            case "areaH": return .int(ctx.areaH)
            case "imageW": return .int(ctx.imageW)
            case "imageH": return .int(ctx.imageH)
            case "imageX": return .int(ctx.imageX)
            case "imageY": return .int(ctx.imageY)
            case "random": return .int(ctx.random)
            case "randS": return .int(ctx.randS)
            case "scale": return .int(ctx.scale)
            default: return .int(0)
            }
        }
    }
}
