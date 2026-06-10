import Foundation

/// Converts a flag's raw string variation into a typed value, returning `nil` on a type mismatch.
typealias ValueConverter<T> = (String) -> T?

/// String → typed-value converters, matching the Kotlin `ValueConverters`.
enum ValueConverters {
    static let bool: ValueConverter<Bool> = { value in
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    static let string: ValueConverter<String> = { $0 }

    static let int: ValueConverter<Int> = { Int($0.trimmingCharacters(in: .whitespaces)) }

    static let float: ValueConverter<Float> = { Float($0.trimmingCharacters(in: .whitespaces)) }

    static let double: ValueConverter<Double> = { Double($0.trimmingCharacters(in: .whitespaces)) }
}
