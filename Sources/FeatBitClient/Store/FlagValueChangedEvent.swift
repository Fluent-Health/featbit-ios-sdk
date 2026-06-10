import Foundation

/// Emitted when a flag's variation value changes (or a new flag appears).
public struct FlagValueChangedEvent: Equatable, Sendable {
    /// The flag key that changed.
    public let key: String
    /// The previous variation value, or `nil` if the flag is new.
    public let oldValue: String?
    /// The current variation value.
    public let newValue: String

    public init(key: String, oldValue: String?, newValue: String) {
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

/// A listener notified when a flag value changes.
public protocol FlagChangeListener: AnyObject {
    func onChange(_ event: FlagValueChangedEvent)
}
