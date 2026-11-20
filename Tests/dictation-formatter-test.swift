import Foundation

@main
@MainActor
struct DictationFormatterTest {
    static var failures = 0
    static var passes = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual == expected {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)\n  got  \(actual)\n  want \(expected)")
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static let conservative = DictationCleanupOptions.conservative
    static let all = DictationCleanupOptions(spacing: true, capitalization: true, punctuation: true)
    static let off = DictationCleanupOptions.off

    static func format(_ text: String, _ context: DictationTextFormatter.Context?,
                       _ options: DictationCleanupOptions) -> String {
        DictationTextFormatter.format(text, context: context, options: options)
    }

    static func main() {
        let empty = DictationTextFormatter.Context(before: "", after: "")
        let midSentence = DictationTextFormatter.Context(before: "Hello there", after: " and more")
        let afterSentence = DictationTextFormatter.Context(before: "Done. ", after: "")
        let newParagraph = DictationTextFormatter.Context(before: "Para one.\n\n", after: "")
        let noTrailingSpace = DictationTextFormatter.Context(before: "Hello there", after: " and more")
        let followingNoLeadingSpace = DictationTextFormatter.Context(before: "Word ", after: "follows")

        // Always trim first, whatever the options.
        expect(format("  hello world  ", nil, off), "hello world",
               "an unknown context trims and does nothing else")
        expect(format(" \n hello world \n ", nil, conservative), "hello world",
               "a nil context with conservative options still trims only")
        expect(format("   ", nil, off), "", "whitespace-only input becomes empty")
        expect(format("", nil, all), "", "empty input stays empty")

        // Empty field: capitalization upper-cases the first letter.
        expect(format("hello world", empty, conservative), "Hello world",
               "an empty field capitalizes the first letter")
        expect(format("hello world", empty, off), "hello world",
               "no options means no capitalization on an empty field")

        // Mid-sentence: the first letter lower-cases (the fork's prior behaviour).
        expect(format("Hello there", midSentence, conservative), " hello there",
               "a mid-sentence field lower-cases the first letter and adds a leading space")
        expect(format("Hello", DictationTextFormatter.Context(before: "Some text", after: ""), off),
               "Hello", "capitalization off leaves the letter alone mid-sentence")

        // Field text without a trailing space inserts the leading space.
        expect(format("Hello there", noTrailingSpace, conservative), " hello there",
               "field text without a trailing space gets a leading space")
        expect(format("word", followingNoLeadingSpace, conservative), "word ",
               "a missing leading space in the following text gets one after")
        expect(format("Word", followingNoLeadingSpace, conservative), "word ",
               "a capitalized input still lower-cases mid-sentence and keeps the trailing space")

        // After ". ": the first letter stays upper-cased.
        expect(format("next sentence", afterSentence, conservative), "Next sentence",
               "a trailing sentence end capitalizes and adds no leading space")
        expect(format("Next sentence", afterSentence, conservative), "Next sentence",
               "after a period the capital is kept")

        // New paragraph.
        expect(format("new paragraph", newParagraph, conservative), "New paragraph",
               "a new paragraph capitalizes the first letter")

        // Spacing off: neither join rule fires.
        expect(format("joined", DictationTextFormatter.Context(before: "Word", after: "follows"), off),
               "joined", "spacing off adds no leading or trailing space")

        // Punctuation option both ways.
        expect(format("the end", empty, all), "The end.", "punctuation on appends a period")
        expect(format("the end", empty, conservative), "The end",
               "punctuation off leaves the text unterminated by default")
        expect(format("already done.", empty, all), "Already done.",
               "terminal punctuation already present is not doubled")
        expect(format("already done!", empty, all), "Already done!",
               "an exclamation mark already terminates the text")
        expect(format("already done?", empty, all), "Already done?",
               "a question mark already terminates the text")

        // Digits and word interiors are never touched.
        expect(format("version 3 release", empty, all), "Version 3 release.",
               "digits pass through untouched")
        expect(format("on 12 Monkeys", midSentence, conservative), " on 12 Monkeys",
               "a digit-starting text is not capitalized")
        expect(format("iPhone case", midSentence, conservative), " iPhone case",
               "the inside of a word is never changed")

        // The coordinator's caret-only join of a runtime result: spacing against the field only.
        let caretOnly = DictationCleanupOptions(spacing: true, capitalization: false, punctuation: false)
        let afterHello = DictationTextFormatter.Context(before: "hello", after: "")
        expect(format("Kubernetes", afterHello, caretOnly), " Kubernetes",
               "a runtime result pasted after a word gains the missing leading space")
        let beforeWord = DictationTextFormatter.Context(before: "hello ", after: "follows")
        expect(format("Kubernetes", beforeWord, caretOnly), "Kubernetes ",
               "a runtime result before an unspaced word gains the trailing space")
        expect(format(" Kubernetes ", afterHello, caretOnly), " Kubernetes",
               "the join re-trims the runtime result before spacing it into the field")

        // The context initializer itself.
        let derived = DictationTextFormatter.Context(before: "Trailing spaces   ", after: "  leading")
        expect(derived.trailing, " ", "trailing is the last character of the before span")
        expect(derived.lastNonWhitespace, "s", "lastNonWhitespace skips trailing whitespace")
        expect(derived.newParagraph, false, "spaces only do not make a new paragraph")
        let paragraph = DictationTextFormatter.Context(before: "End.\n", after: "")
        expect(paragraph.newParagraph, true, "a newline makes a new paragraph")
        expect(paragraph.lastNonWhitespace, ".", "lastNonWhitespace stops at the period")

        let failSummary = failures == 0 ? "all \(passes) assertions passed" : "\(failures) FAILED"
        print("Dictation formatter: \(failSummary)")
        if failures > 0 { exit(1) }
    }
}
