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
}
