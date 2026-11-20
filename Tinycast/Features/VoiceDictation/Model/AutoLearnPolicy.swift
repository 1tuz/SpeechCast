import Foundation

struct ObservedCorrection: Equatable, Sendable {
    let inserted: String     // what SpeechCast inserted, in the monitored span
    let observed: String     // what the field now holds in the same span
    let bundleID: String?
    let at: Date
    let sessionID: UUID      // one monitor run = one session; two equal pairs in one session are one signal
}

struct AutoLearnCandidate: Equatable, Sendable {
    let spoken: String
    let replacement: String
    let scopeBundleID: String?
    let observations: Int
}

enum AutoLearnDecision: Equatable, Sendable {
    case rejected(Reason)
    case suggest(AutoLearnCandidate)      // review queue, disabled until the user approves
    case autoApply(AutoLearnCandidate)    // safe rule, approved + enabled, applies to dictation now

    enum Reason: Equatable, Sendable { case notCorrection, ambiguous, unsafe, common, duplicate }
}

enum AutoLearnPolicy {
    /// The monitor never observes outside this window (spec: <= 60 s).
    static let maximumWindow: Duration = .seconds(60)
    /// A replacement longer than this is a rewrite, not the term the reader meant to fix.
    static let maximumReplacementLength = 24
    /// A phrase may lose words down to one term, and never grow past this.
    static let maximumChangedWords = 3

    static let stopWords: Set<String> = [   // English + Russian function words
        "a", "an", "and", "as", "at", "be", "but", "by", "for", "from", "he", "her", "here", "hers",
        "him", "his", "i", "if", "in", "into", "is", "it", "its", "me", "my", "no", "not", "of", "on",
        "or", "our", "out", "she", "so", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "this", "those", "to", "too", "up", "us", "was", "we", "were", "what", "when",
        "where", "which", "who", "why", "will", "with", "you", "your",
        "а", "без", "более", "бы", "был", "была", "были", "было", "быть", "в", "вам", "вас", "весь",
        "во", "вот", "все", "всего", "всей", "вы", "где", "да", "даже", "для", "до", "его", "ее", "её",
        "если", "есть", "же", "за", "здесь", "и", "из", "или", "им", "их", "к", "как", "ко", "когда",
        "кто", "ли", "либо", "мне", "может", "мы", "на", "над", "надо", "наш", "не", "него", "нее", "неё",
        "нет", "ни", "них", "но", "ну", "о", "об", "однако", "он", "она", "они", "оно", "опять", "от",
        "перед", "по", "под", "при", "про", "с", "сам", "свой", "со", "так", "такой", "там", "те", "тем",
        "то", "того", "тоже", "той", "только", "тот", "ты", "у", "уже", "хоть", "через", "что", "чтобы",
        "чьё", "это"
    ]
    /// Ordinary words whose substitution changes meaning rather than vocabulary: never learnable.
    static let ordinaryWords: Set<String> = stopWords.union([
        "accept", "add", "approve", "cancel", "close", "confirm", "decline", "delete", "deny", "done",
        "next", "no", "ok", "okay", "open", "previous", "reject", "remove", "save", "start", "stop",
        "yes",
        "готово", "далее", "добавить", "закрыть", "начать", "назад", "нет", "ок", "отмена", "отклонить",
        "открыть", "подтвердить", "принять", "сохранить", "стоп", "удалить",
    ])

    /// `prior` are earlier accepted observations of the same pair, oldest first, excluding `observation`.
    /// `existing` is the whole dictionary: an approved rule blocks the pair, a suggestion is one
    /// observation already counted toward the second independent signal.
    static func decide(
        _ observation: ObservedCorrection, prior: [ObservedCorrection], existing: [DictationEntry]
    ) -> AutoLearnDecision {
        let inserted = observation.inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        let observed = observation.observed.trimmingCharacters(in: .whitespacesAndNewlines)
        if inserted.isEmpty || observed.isEmpty { return .rejected(.notCorrection) }

        // The one changed phrase between the two sides: guards are measured there, so a long
        // dictation is never rejected for being long.
        let (changedInserted, changedObserved) = difference(inserted, observed)
        if changedInserted.isEmpty && changedObserved.isEmpty { return .rejected(.notCorrection) }
        let changedSpoken = changedInserted.joined(separator: " ")
        let changedReplacement = changedObserved.joined(separator: " ")
        // Case and punctuation alone are no correction: substitution ignores case, so a rule
        // that differs only in case could not change a single character of any dictation.
        if foldedPhrase(changedSpoken) == foldedPhrase(changedReplacement) {
            return .rejected(.notCorrection)
        }

        // `.ambiguous`: the same words in another order. A rewrite, never a learned term.
        if changedInserted.count == changedObserved.count,
           changedInserted.map(folded).sorted() == changedObserved.map(folded).sorted() {
            return .rejected(.ambiguous)
        }

        // `.unsafe`: shape and content guards, measured on the changed phrase.
        if changedObserved.isEmpty || changedInserted.count > Self.maximumChangedWords
            || changedObserved.count > Self.maximumChangedWords {
            return .rejected(.unsafe)
        }
        if changedSpoken.count > Self.maximumReplacementLength
            || changedReplacement.count > Self.maximumReplacementLength {
            return .rejected(.unsafe)
        }
        // No punctuated replacement: dictation never speaks a comma, and a punctuated side
        // is a rewritten sentence rather than the term the reader was fixing.
        if changedReplacement.contains(where: { ".,;:!?\u{2026}\u{2014}".contains($0) }) {
            return .rejected(.unsafe)
        }
        if changedInserted.count == changedObserved.count {
            // A same-length swap may only change one word: one term, not a rewrite.
            if zip(changedInserted, changedObserved).filter({ $0 != $1 }).count > 1 {
                return .rejected(.unsafe)
            }
        } else if !(changedInserted.count >= 2 && changedObserved.count == 1) {
            // Only 2–3 spoken words collapsing to one term may change the count.
            return .rejected(.unsafe)
        }

        // `.common`: ordinary words either side. `approve` → `reject` is meaning, not vocabulary.
        let replacementWords = changedObserved.map(folded)
        if replacementWords.allSatisfy({ Self.stopWords.contains($0) }) { return .rejected(.common) }
        if changedInserted.map(folded).allSatisfy({ Self.ordinaryWords.contains($0) }),
           replacementWords.allSatisfy({ Self.ordinaryWords.contains($0) }) {
            return .rejected(.common)
        }

        // The whole utterance is the rule while it is short enough to be one; a longer dictation
        // yields only the phrase that changed, so a rule never pins a sentence down.
        let budget = DictationDictionary.maximumSpokenWords
        var spoken = inserted
        var replacement = observed
        if changedInserted.count > budget || changedObserved.count > budget
            || Self.tokens(inserted).count > budget || Self.tokens(observed).count > budget {
            spoken = changedSpoken
            replacement = changedReplacement
        }

        // A pair the dictionary already approved is done; a pair it only suggested is one of
        // the two observations, so this one may be the second independent signal.
        var sessions: Set<UUID> = [observation.sessionID]
        for earlier in prior
        where earlier.bundleID == observation.bundleID
            && foldedPhrase(earlier.inserted) == foldedPhrase(inserted)
            && foldedPhrase(earlier.observed) == foldedPhrase(observed) {
            sessions.insert(earlier.sessionID)
        }
        if let held = existing.first(where: { held in
            normalizeText(held.spoken) == normalizeText(spoken)
                && normalizeText(held.replacement) == normalizeText(replacement)
                && (held.scopeBundleID == nil || held.scopeBundleID == observation.bundleID)
        }) {
            if held.approval == .approved, held.isEnabled { return .rejected(.duplicate) }
            // A kept suggestion is the earlier run's independent signal.
            if let session = held.lastSessionID { sessions.insert(session) }
        }

        let candidate = AutoLearnCandidate(
            spoken: spoken, replacement: replacement,
            scopeBundleID: observation.bundleID,
            observations: sessions.count
        )
        // One session is one signal: a second correction in the same run only restates it.
        let independent = sessions.contains { $0 != observation.sessionID }
        return independent ? .autoApply(candidate) : .suggest(candidate)
    }

    /// The changed phrase either side, as raw word tokens: exact match at both ends, so a change
    /// of case is not mistaken for a change of text.
    static func difference(_ inserted: String, _ observed: String) -> ([String], [String]) {
        let lhs = tokens(inserted)
        let rhs = tokens(observed)
        var prefix = 0
        while prefix < lhs.count, prefix < rhs.count, lhs[prefix] == rhs[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < lhs.count - prefix, suffix < rhs.count - prefix,
              lhs[lhs.count - 1 - suffix] == rhs[rhs.count - 1 - suffix] {
            suffix += 1
        }
        return (Array(lhs[prefix..<(lhs.count - suffix)]), Array(rhs[prefix..<(rhs.count - suffix)]))
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// Case and punctuation folded away: the shape two sides share when only spelling differs.
    private static func folded(_ token: String) -> String {
        token.filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    private static func foldedPhrase(_ text: String) -> String {
        tokens(text).map(folded).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func normalizeText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .filter { !$0.isWhitespace }
    }
}
