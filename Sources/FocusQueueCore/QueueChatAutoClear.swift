import Foundation

/// How long a QChat conversation may sit idle before Focus Queue clears it.
/// Stored in config.json as whole minutes; nil or 0 never clears.
public struct QueueChatAutoClear: Equatable, Sendable {
  public enum Unit: String, CaseIterable, Identifiable, Sendable {
    case never, minutes, hours, days

    public var id: String { rawValue }

    public var title: String {
      switch self {
      case .never: "Never"
      case .minutes: "Minutes"
      case .hours: "Hours"
      case .days: "Days"
      }
    }

    /// Minutes in one unit; never has none.
    public var minutes: Int {
      switch self {
      case .never: 0
      case .minutes: 1
      case .hours: 60
      case .days: 1_440
      }
    }

    /// Each range stops below the next unit, so a saved value always reads
    /// back in the unit that wrote it.
    public var amountRange: ClosedRange<Int> {
      switch self {
      case .never: 0...0
      case .minutes: 1...59
      case .hours: 1...23
      case .days: 1...30
      }
    }

    /// The amount a unit starts with when the user first picks it.
    public var initialAmount: Int {
      switch self {
      case .never: 0
      case .minutes: 30
      case .hours: 1
      case .days: 1
      }
    }
  }

  public var unit: Unit
  public var amount: Int

  public init(unit: Unit, amount: Int) {
    self.unit = unit
    self.amount = unit == .never ? 0 : min(max(amount, unit.amountRange.lowerBound), unit.amountRange.upperBound)
  }

  /// Reads a stored minute count back as the largest unit that divides it.
  public init(minutes: Int?) {
    guard let minutes, minutes > 0 else {
      self.init(unit: .never, amount: 0)
      return
    }
    if minutes % Unit.days.minutes == 0 {
      self.init(unit: .days, amount: minutes / Unit.days.minutes)
    } else if minutes % Unit.hours.minutes == 0 {
      self.init(unit: .hours, amount: minutes / Unit.hours.minutes)
    } else {
      self.init(unit: .minutes, amount: minutes)
    }
  }

  /// The value to save; nil means never.
  public var minutes: Int? { unit == .never ? nil : amount * unit.minutes }

  /// Switching units keeps the amount when it fits, otherwise starts fresh.
  public func switching(to unit: Unit) -> QueueChatAutoClear {
    guard unit != self.unit else { return self }
    let amount = self.unit != .never && unit.amountRange.contains(amount) ? amount : unit.initialAmount
    return QueueChatAutoClear(unit: unit, amount: amount)
  }

  /// "Never", "1 hour", "3 days".
  public var summary: String {
    guard unit != .never else { return "Never" }
    let noun = String(unit.title.lowercased().dropLast())
    return "\(amount) \(noun)\(amount == 1 ? "" : "s")"
  }

  /// True once a conversation last active at `lastActivity` has been idle for
  /// the configured time.
  public static func isDue(lastActivity: Date, now: Date, minutes: Int?) -> Bool {
    guard let minutes, minutes > 0 else { return false }
    return now.timeIntervalSince(lastActivity) >= TimeInterval(minutes * 60)
  }
}
