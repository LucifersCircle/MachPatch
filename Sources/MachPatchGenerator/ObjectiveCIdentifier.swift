import Foundation

enum ObjectiveCIdentifier {
    static func sanitize(_ value: String) -> String {
        var result = ""
        var previousWasUnderscore = false

        for scalar in value.unicodeScalars {
            let isASCII = scalar.value < 128
            let isLetter =
                isASCII
                && ((65...90).contains(scalar.value) || (97...122).contains(scalar.value))
            let isDigit = isASCII && (48...57).contains(scalar.value)
            let character: Character = isLetter || isDigit ? Character(String(scalar)) : "_"

            if character == "_" {
                if !previousWasUnderscore { result.append(character) }
                previousWasUnderscore = true
            } else {
                result.append(character)
                previousWasUnderscore = false
            }
        }

        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty { result = "value" }
        if result.first?.isNumber == true { result = "_\(result)" }
        return result
    }
}
