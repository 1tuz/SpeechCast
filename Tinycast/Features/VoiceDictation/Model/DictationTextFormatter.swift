import Foundation

struct DictationCleanupOptions: Equatable, Sendable {
    var spacing: Bool
    var capitalization: Bool
    var punctuation: Bool

    static let off = DictationCleanupOptions(spacing: false, capitalization: false, punctuation: false)

    /// Spacing + capitalization on, punctuation off: never invents terminal punctuation by default.
    static let conservative = DictationCleanupOptions(spacing: true, capitalization: true, punctuation: false)
}

enum DictationTextFormatter {
    struct Context: Equatable, Sendable {
        let trailing: Character?
        let lastNonWhitespace: Character?
        let newParagraph: Bool
        let following: Character?

        init(before: Substring, after: Substring) {
            trailing = before.last
            following = after.first
            var last: Character?
            var paragraph = false
            for character in before.reversed() {
                if !character.isWhitespace {
                    last = character
                    break
                }
                if character.isNewline { paragraph = true }
            }
            lastNonWhitespace = last
            newParagraph = paragraph
        }
    }

    /// Deterministic. `context == nil` means nothing is known about the field: trim only.
    static func format(
        _ text: String, context: Context?, options: DictationCleanupOptions
    ) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, let context else { return result }
        if options.capitalization, let first = result.first, first.isLetter {
            let replacement: String
            if context.lastNonWhitespace == nil || context.newParagraph
                || context.lastNonWhitespace.map({ ".!?".contains($0) }) == true {
                replacement = String(first).uppercased()
            } else {
                replacement = String(first).lowercased()
            }
            result.replaceSubrange(result.startIndex...result.startIndex, with: replacement)
        }
        if options.spacing {
            if let trailing = context.trailing, !trailing.isWhitespace,
               !"([{/\"'‘’“—-".contains(trailing),
               let leading = result.first, !".,!?;:)]}/\"'”".contains(leading) {
                result = " " + result
            }
            if let leading = context.following, !leading.isWhitespace,
               let trailing = result.last, !trailing.isWhitespace,
               !".,!?;:)]}/\"'”".contains(leading) {
                result += " "
            }
        }
        if options.punctuation, let last = result.last,
           !".!?…".contains(last) {
            result += "."
        }
        return result
    }
}
