import Foundation

/// Inspector value parsing for the UI Canvas, ported from ECC's
/// `scripts/lib/ui-canvas/fields.js` so typed values are sanitized and clamped
/// the same way before they reach the mockup.
struct UICanvasFieldSpec: Equatable {
  var label: String
  var unit = ""
  var units: [String] = [""]
  var min = -Double.infinity
  var max = Double.infinity
  var step = 0.0
  var slider: ClosedRange<Double> = 0...1
  var sliderStep = 1.0
  var ratio = false
  var box = false
  var maxParts = 4
  var allowAuto = false
}

enum UICanvasFieldResult: Equatable {
  case ok(css: String, value: Double?)
  case error(String)

  var css: String? {
    if case .ok(let css, _) = self { return css }
    return nil
  }
}

struct UICanvasRGBA: Equatable {
  var r: Double
  var g: Double
  var b: Double
  var a: Double
}

/// One box-shadow layer, edited with sliders instead of CSS text.
struct UICanvasShadow: Equatable {
  var x = 0.0
  var y = 4.0
  var blur = 12.0
  var spread = 0.0
  var color = "rgba(0, 0, 0, 0.15)"
  var inset = false
}

/// A linear gradient with its angle and color stops, edited with an angle
/// slider and color swatches instead of CSS text.
struct UICanvasGradient: Equatable {
  struct Stop: Equatable {
    var color: String
    var position: String?
  }

  var angle = 180.0
  var stops: [Stop]
}

enum UICanvasFields {
  static let lengthUnits = ["px", "rem", "em", "%"]

  /// `step` is typed-value precision; `sliderStep` is the drag increment.
  static let numeric: [String: UICanvasFieldSpec] = [
    "font-size": .init(label: "Size", unit: "px", units: lengthUnits, min: 1, max: 999, step: 0.01, slider: 6...96),
    "font-weight": .init(label: "Weight", min: 1, max: 1000, step: 1, slider: 100...900, sliderStep: 100),
    "line-height": .init(label: "Line height", units: ["", "px", "em", "rem", "%"], min: 0, max: 999, step: 0.01,
                         slider: 0.8...3, sliderStep: 0.05),
    "border-radius": .init(label: "Radius", unit: "px", units: lengthUnits, min: 0, max: 9999, step: 0.01, slider: 0...64, box: true),
    "opacity": .init(label: "Opacity", min: 0, max: 1, step: 0.01, slider: 0...1, sliderStep: 0.01, ratio: true),
    "padding": .init(label: "Padding", unit: "px", units: lengthUnits, min: 0, max: 9999, step: 0.01, slider: 0...96, box: true),
    "margin": .init(label: "Margin", unit: "px", units: lengthUnits, min: -9999, max: 9999, step: 0.01, slider: 0...96,
                    box: true, allowAuto: true),
    "gap": .init(label: "Gap", unit: "px", units: lengthUnits, min: 0, max: 9999, step: 0.01, slider: 0...96, box: true, maxParts: 2),
  ]

  static func roundToStep(_ value: Double, _ step: Double) -> Double {
    guard step > 0 else { return value }
    let decimals = String(step).split(separator: ".").dropFirst().first.map { $0 == "0" ? 0 : $0.count } ?? 0
    let rounded = (value / step).rounded() * step
    let factor = pow(10, Double(Swift.min(decimals, 6)))
    return (rounded * factor).rounded() / factor
  }

  /// Shortest readable form: 16, 1.5, 0.25.
  static func formatNumber(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() { return String(Int(rounded)) }
    var text = String(format: "%.2f", rounded)
    while text.hasSuffix("0") { text.removeLast() }
    return text
  }

  static func sanitizeNumber(_ raw: String, _ spec: UICanvasFieldSpec) -> UICanvasFieldResult {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ",", with: ".")
    guard !text.isEmpty else { return .error("Enter a number") }
    guard let match = text.firstMatch(of: /^([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*([a-z%]*)$/),
          var value = Double(match.1), value.isFinite else { return .error("Not a number") }
    var unit = String(match.2)
    if spec.ratio {
      if unit == "%" || value > 1 { value /= 100 }
      else if !unit.isEmpty { return .error("Use a percentage, like 50%") }
      unit = ""
    } else {
      if unit.isEmpty { unit = spec.unit }
      if !spec.units.contains(unit) {
        let listed = spec.units.filter { !$0.isEmpty }
        return .error(listed.isEmpty ? "Use a plain number" : "Use " + listed.joined(separator: ", "))
      }
    }
    value = roundToStep(Swift.min(spec.max, Swift.max(spec.min, value)), spec.step)
    return .ok(css: formatNumber(value) + unit, value: value)
  }

  /// A 1-4 part box value such as padding "8 16" or margin "0 auto".
  static func sanitizeBoxList(_ raw: String, _ spec: UICanvasFieldSpec) -> UICanvasFieldResult {
    let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
    guard !parts.isEmpty else { return .error("Enter a value") }
    guard parts.count <= spec.maxParts else { return .error("Use at most \(spec.maxParts) values") }
    var output: [String] = []
    var first: Double?
    for part in parts {
      if part == "auto", spec.allowAuto { output.append("auto"); continue }
      let result = sanitizeNumber(part, spec)
      guard case .ok(let css, let value) = result else { return result }
      if first == nil { first = value }
      output.append(value == 0 ? "0" : css)
    }
    return .ok(css: output.joined(separator: " "), value: parts.count == 1 ? first : nil)
  }

  /// Free CSS text (box-shadow, background-image): rejects anything that could
  /// close the declaration or smuggle another property.
  static func sanitizeCssText(_ raw: String, maxLength: Int = 300) -> UICanvasFieldResult {
    let text = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .error("Enter a value") }
    guard text.count <= maxLength else { return .error("Too long") }
    if text.range(of: #"[;{}<>\\]|/\*|!important|expression\s*\(|javascript:"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return .error("Remove ; { } < > and comments")
    }
    return .ok(css: text, value: nil)
  }

  /// Parses #rgb(a), #rrggbb(aa), rgb()/rgba(), and transparent.
  static func parseColor(_ raw: String) -> UICanvasRGBA? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text == "transparent" { return UICanvasRGBA(r: 0, g: 0, b: 0, a: 0) }
    if let match = text.wholeMatch(of: /#?([0-9a-f]{3,8})/), [3, 4, 6, 8].contains(match.1.count) {
      var hex = String(match.1)
      if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
      func channel(_ offset: Int) -> Double {
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return Double(Int(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) ?? 0)
      }
      let alpha = hex.count == 8 ? (channel(6) / 255 * 1000).rounded() / 1000 : 1
      return UICanvasRGBA(r: channel(0), g: channel(2), b: channel(4), a: alpha)
    }
    guard let match = text.wholeMatch(of: /rgba?\(\s*([^)]*)\)/) else { return nil }
    let numbers = match.1.split(whereSeparator: { " ,/".contains($0) }).map(String.init)
    guard (3...4).contains(numbers.count) else { return nil }
    func value(_ part: String, percentScale: Double) -> Double? {
      part.hasSuffix("%") ? Double(part.dropLast()).map { $0 * percentScale } : Double(part)
    }
    let rgb = numbers.prefix(3).compactMap { value($0, percentScale: 2.55) }
    guard rgb.count == 3 else { return nil }
    let alpha = numbers.count == 4 ? value(numbers[3], percentScale: 0.01) : 1
    guard let alpha, alpha.isFinite else { return nil }
    let clamped = rgb.map { Swift.min(255, Swift.max(0, $0)).rounded() }
    return UICanvasRGBA(r: clamped[0], g: clamped[1], b: clamped[2],
                        a: (Swift.min(1, Swift.max(0, alpha)) * 1000).rounded() / 1000)
  }

  /// `#rrggbb` when opaque, else `rgba()`, so mockup CSS stays readable.
  static func formatColor(_ color: UICanvasRGBA) -> String {
    func pair(_ value: Double) -> String { String(format: "%02x", Int(Swift.min(255, Swift.max(0, value.rounded())))) }
    if color.a >= 1 { return "#" + pair(color.r) + pair(color.g) + pair(color.b) }
    return "rgba(\(Int(color.r.rounded())), \(Int(color.g.rounded())), \(Int(color.b.rounded())), \(formatNumber(color.a)))"
  }

  /// Splits the editor's border summary ("1px solid rgb(…)" or "none").
  static func borderParts(_ value: String) -> (width: Double, style: String, color: String) {
    guard value != "none", let match = value.firstMatch(of: /^([\d.]+)px\s+(\w+)\s+(.+)$/) else {
      return (0, "solid", "#000000")
    }
    return (Double(match.1) ?? 0, String(match.2), String(match.3))
  }

  // MARK: Structured values

  /// Splits on `separator` outside parentheses, so `rgba(0, 0, 0, .1)` stays whole.
  static func splitTopLevel(_ value: String, separator: Character) -> [String] {
    var parts: [String] = [], current = "", depth = 0
    for character in value {
      if character == "(" { depth += 1 } else if character == ")" { depth = Swift.max(0, depth - 1) }
      if depth == 0, character == separator || (separator == " " && character.isWhitespace) {
        if !current.isEmpty { parts.append(current) }
        current = ""
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { parts.append(current) }
    return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  /// A unitless zero or a px length.
  private static func pixels(_ token: String) -> Double? {
    if let value = Double(token), value == 0 { return 0 }
    guard token.hasSuffix("px"), let value = Double(token.dropLast(2)), value.isFinite else { return nil }
    return value
  }

  private static func isColorToken(_ token: String) -> Bool {
    parseColor(token) != nil || token.range(of: "^[a-z]+$", options: .regularExpression) != nil
  }

  private static func normalizedColor(_ token: String) -> String {
    parseColor(token).map(formatColor) ?? token
  }

  /// Every layer of a box-shadow, or nil when a layer uses something the
  /// controls cannot represent (em lengths, variables). "none" is no layers.
  static func parseShadows(_ value: String) -> [UICanvasShadow]? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.isEmpty || text == "none" { return [] }
    var shadows: [UICanvasShadow] = []
    for layer in splitTopLevel(text, separator: ",") {
      var shadow = UICanvasShadow(), lengths: [Double] = [], color: String?
      for token in splitTopLevel(layer, separator: " ") {
        if token == "inset" { shadow.inset = true }
        else if let length = pixels(token) { lengths.append(length) }
        else if color == nil, isColorToken(token) { color = token }
        else { return nil }
      }
      guard (2...4).contains(lengths.count) else { return nil }
      shadow.x = lengths[0]
      shadow.y = lengths[1]
      shadow.blur = lengths.count > 2 ? Swift.max(0, lengths[2]) : 0
      shadow.spread = lengths.count > 3 ? lengths[3] : 0
      shadow.color = normalizedColor(color ?? "currentcolor")
      shadows.append(shadow)
    }
    return shadows
  }

  static func formatShadows(_ shadows: [UICanvasShadow]) -> String {
    guard !shadows.isEmpty else { return "none" }
    return shadows.map { shadow in
      let lengths = [shadow.x, shadow.y, shadow.blur, shadow.spread].map { $0 == 0 ? "0" : formatNumber($0) + "px" }
      return (shadow.inset ? ["inset"] : []) + lengths + [shadow.color]
    }.map { $0.joined(separator: " ") }.joined(separator: ", ")
  }

  private static let sideAngles: [String: Double] = [
    "to top": 0, "to top right": 45, "to right top": 45, "to right": 90, "to bottom right": 135,
    "to right bottom": 135, "to bottom": 180, "to bottom left": 225, "to left bottom": 225,
    "to left": 270, "to top left": 315, "to left top": 315,
  ]

  /// A single linear-gradient layer, or nil for images, repeating or radial
  /// gradients, and stacked layers, which stay as text.
  static func parseGradient(_ value: String) -> UICanvasGradient? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard splitTopLevel(text, separator: ",").count == 1,
          let match = text.wholeMatch(of: /linear-gradient\((.*)\)/) else { return nil }
    var arguments = splitTopLevel(String(match.1), separator: ",")
    guard let first = arguments.first else { return nil }
    var gradient = UICanvasGradient(stops: [])
    if let angle = first.wholeMatch(of: /(-?[\d.]+)(deg|turn|rad|grad)/), let number = Double(angle.1) {
      let degrees: Double = switch angle.2 {
      case "turn": number * 360
      case "rad": number * 180 / .pi
      case "grad": number * 0.9
      default: number
      }
      gradient.angle = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
      arguments.removeFirst()
    } else if first.hasPrefix("to ") {
      guard let degrees = sideAngles[first.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)]
      else { return nil }
      gradient.angle = degrees
      arguments.removeFirst()
    }
    for argument in arguments {
      let tokens = splitTopLevel(argument, separator: " ")
      guard (1...2).contains(tokens.count), isColorToken(tokens[0]) else { return nil }
      if tokens.count == 2, tokens[1].range(of: #"^-?[\d.]+(%|px)$"#, options: .regularExpression) == nil { return nil }
      gradient.stops.append(.init(color: normalizedColor(tokens[0]), position: tokens.count == 2 ? tokens[1] : nil))
    }
    return gradient.stops.count >= 2 ? gradient : nil
  }

  static func formatGradient(_ gradient: UICanvasGradient) -> String {
    let stops = gradient.stops.map { [$0.color, $0.position].compactMap { $0 }.joined(separator: " ") }
    return "linear-gradient(\(formatNumber(gradient.angle))deg, \(stops.joined(separator: ", ")))"
  }

  /// Per-side labels for a box shorthand, in CSS order.
  static func sideLabels(_ property: String) -> [String] {
    switch property {
    case "gap": ["Row", "Column"]
    case "border-radius": ["Top left", "Top right", "Bottom right", "Bottom left"]
    default: ["Top", "Right", "Bottom", "Left"]
    }
  }

  /// Expands a 1-4 part shorthand into one value per side.
  static func boxSides(_ value: String, count: Int) -> [String]? {
    let parts = splitTopLevel(value.trimmingCharacters(in: .whitespacesAndNewlines), separator: " ")
    guard (1...count).contains(parts.count) else { return nil }
    if count == 2 { return parts.count == 1 ? [parts[0], parts[0]] : parts }
    switch parts.count {
    case 1: return Array(repeating: parts[0], count: 4)
    case 2: return [parts[0], parts[1], parts[0], parts[1]]
    case 3: return [parts[0], parts[1], parts[2], parts[1]]
    default: return parts
    }
  }

  /// The shortest shorthand for per-side values.
  static func composeBox(_ sides: [String]) -> String {
    if Set(sides).count == 1 { return sides[0] }
    guard sides.count == 4 else { return sides.joined(separator: " ") }
    if sides[0] == sides[2], sides[1] == sides[3] { return "\(sides[0]) \(sides[1])" }
    if sides[1] == sides[3] { return "\(sides[0]) \(sides[1]) \(sides[2])" }
    return sides.joined(separator: " ")
  }
}
