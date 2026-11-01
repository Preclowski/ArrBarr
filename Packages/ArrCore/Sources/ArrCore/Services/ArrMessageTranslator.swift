import Foundation

/// The arrs send rejections and queue messages as filled-in English literals, in any UI language.
/// Text it doesn't know, such as a phrasing from another arr version, comes back unchanged.
nonisolated enum ArrMessageTranslator {
    private struct Template {
        let key: String
        /// The text around the placeholders; one more entry than there are placeholders.
        let literals: [String]
    }

    private static let table = "ArrMessages"

    /// Most literal text first, so `… %@ (for %@)` is tried before `… %@`.
    private static let templates: [Template] = ArrMessageTemplates.all
        .map { key in
            Template(key: key, literals: key.components(separatedBy: "%@").map { $0.replacingOccurrences(of: "%%", with: "%") })
        }
        .sorted { $0.literals.joined().count > $1.literals.joined().count }

    static func translate(_ message: String, locale: Locale) -> String {
        if let translated = translateWhole(message, locale: locale) { return translated }
        // `ArrCompositions.flatten` writes "file.mkv: reason", and a release name can hold a colon too.
        var rest = message.startIndex..<message.endIndex
        while let separator = message.range(of: ": ", range: rest) {
            if let translated = translateWhole(String(message[separator.upperBound...]), locale: locale) {
                return message[..<separator.upperBound] + translated
            }
            rest = separator.upperBound..<message.endIndex
        }
        return message
    }

    private static func translateWhole(_ message: String, locale: Locale) -> String? {
        for template in templates {
            guard let arguments = arguments(of: message, literals: template.literals) else { continue }
            let format = AppLocalized.string(template.key, locale: locale, table: table)
            return String(format: format, arguments: arguments)
        }
        return nil
    }

    /// Each placeholder takes the shortest text that lets the next literal follow.
    private static func arguments(of message: String, literals: [String]) -> [String]? {
        guard let first = literals.first, let last = literals.last else { return nil }
        guard literals.count > 1 else { return message == first ? [] : nil }
        guard message.hasPrefix(first), message.hasSuffix(last), message.count >= first.count + last.count else { return nil }

        var cursor = message.index(message.startIndex, offsetBy: first.count)
        let end = message.index(message.endIndex, offsetBy: -last.count)
        var arguments: [String] = []
        for literal in literals.dropFirst().dropLast() {
            guard let hit = message.range(of: literal, range: cursor..<end) else { return nil }
            arguments.append(String(message[cursor..<hit.lowerBound]))
            cursor = hit.upperBound
        }
        arguments.append(String(message[cursor..<end]))
        // Leading placeholders hold a size, quality or language. A colon means it swallowed a file name.
        if first.isEmpty, arguments[0].contains(": ") { return nil }
        return arguments
    }
}
