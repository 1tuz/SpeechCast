import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum DictationInsertionContext {
    /// The text immediately before and after the caret, so the formatter can join into the sentence.
    static func read(in target: DictationInsertionTarget?) -> DictationTextFormatter.Context? {
        read(in: target, reader: .accessibility)
    }

    static func read(
        in target: DictationInsertionTarget?, reader: AutoLearnFieldReader
    ) -> DictationTextFormatter.Context? {
        guard let element = target?.focusedElement,
            let caret = reader.selectedRange(element)
        else { return nil }
        // Two bounded windows, never the field: the formatter only looks at the seam.
        let beforeLocation = max(0, caret.location - 64)
        guard let before = reader.string(
            element,
            NSRange(location: beforeLocation, length: caret.location - beforeLocation))
        else { return nil }
        let afterStart = caret.upperBound
        let afterEnd = min(
            afterStart + 64, reader.numberOfCharacters(element) ?? afterStart)
        let after = afterEnd > afterStart
            ? reader.string(
                element, NSRange(location: afterStart, length: afterEnd - afterStart)) ?? ""
            : ""
        return .init(before: Substring(before), after: Substring(after))
    }
}
