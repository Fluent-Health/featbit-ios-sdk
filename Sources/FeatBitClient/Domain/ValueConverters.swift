import Foundation

/// Converts a flag's raw string variation into a typed value, returning `nil` on a type mismatch.
typealias ValueConverter<T> = (String) -> T?

/// String → typed-value converters, matching the Kotlin `ValueConverters`.
enum ValueConverters {
    static let bool: ValueConverter<Bool> = { value in
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // Alloc-free case-insensitive compare — .lowercased() allocates a fresh
        // String whenever any character has an uppercase counterpart; compare(_:options:)
        // handles the case fold in-place.
        if trimmed.compare("true", options: .caseInsensitive) == .orderedSame { return true }
        if trimmed.compare("false", options: .caseInsensitive) == .orderedSame { return false }
        return nil
    }

    static let string: ValueConverter<String> = { $0 }

    static let int: ValueConverter<Int> = { Int($0.trimmingCharacters(in: .whitespaces)) }

    static let float: ValueConverter<Float> = { Float($0.trimmingCharacters(in: .whitespaces)) }

    static let double: ValueConverter<Double> = { Double($0.trimmingCharacters(in: .whitespaces)) }
}
