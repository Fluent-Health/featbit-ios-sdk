import Foundation

/// Defines the attributes of a user for whom feature flags are evaluated.
///
/// An ``FBUser`` has two built-in attributes — ``key`` and ``name`` — and any number of custom
/// string attributes. The only mandatory attribute is ``key``, which must uniquely identify
/// each user. Both built-in and custom attributes can be referenced in targeting rules and are
/// included in analytics data.
///
/// Instances are created with the fluent ``Builder``:
/// ```swift
/// let user = FBUser.builder("a-unique-key-of-bob")
///     .name("bob")
///     .custom("country", "FR")
///     .build()
/// ```
public struct FBUser: Equatable, Sendable {
    public let key: String
    public let name: String
    public let custom: [String: String]

    init(key: String, name: String, custom: [String: String]) {
        self.key = key
        self.name = name
        self.custom = custom
    }

    func toEndUser() -> EndUser {
        EndUser(
            keyId: key,
            name: name,
            // Sort for deterministic payloads (Kotlin used a LinkedHashMap insertion order;
            // a stable order keeps tests and request bodies reproducible).
            customizedProperties: custom
                .sorted { $0.key < $1.key }
                .map { CustomizedProperty(name: $0.key, value: $0.value) }
        )
    }

    /// Fluent builder for ``FBUser``.
    public final class Builder {
        private let key: String
        private var name: String = ""
        private var custom: [String: String] = [:]

        public init(_ key: String) {
            self.key = key
        }

        /// Sets the full name for the user. Blank values are ignored.
        @discardableResult
        public func name(_ name: String) -> Builder {
            if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                self.name = name
            }
            return self
        }

        /// Adds a custom attribute with a string value. A blank `key` is ignored.
        @discardableResult
        public func custom(_ key: String, _ value: String) -> Builder {
            guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return self }
            custom[key] = value
            return self
        }

        /// Builds an immutable ``FBUser`` from the configured properties.
        public func build() -> FBUser {
            FBUser(key: key, name: name, custom: custom)
        }
    }

    /// Creates a ``Builder`` for constructing an ``FBUser``.
    /// - Parameter key: a string that uniquely identifies the user.
    public static func builder(_ key: String) -> Builder {
        Builder(key)
    }
}
