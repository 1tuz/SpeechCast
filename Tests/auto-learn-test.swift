import Foundation

@main
@MainActor
struct AutoLearnTest {
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

    static let sessionA = UUID()
    static let sessionB = UUID()

    static func observation(
        inserted: String, observed: String, session: UUID, bundleID: String? = "com.apple.TextEdit"
    ) -> ObservedCorrection {
        ObservedCorrection(
            inserted: inserted, observed: observed, bundleID: bundleID,
            at: Date(timeIntervalSince1970: 1_000), sessionID: session)
    }

    static func decide(
        _ inserted: String, _ observed: String, session: UUID? = nil,
        prior: [ObservedCorrection] = [], existing: [DictationEntry] = []
    ) -> AutoLearnDecision {
        AutoLearnPolicy.decide(
            observation(inserted: inserted, observed: observed, session: session ?? sessionA),
            prior: prior, existing: existing)
    }

    static func main() {
        suggestOnOneSession()
        autoApplyAfterTwoIndependentSessions()
        rejections()
        ambiguousAndRewrites()
        acceptedShapes()
        previouslyFailedScenarios()

        let failSummary = failures == 0 ? "all \(passes) assertions passed" : "\(failures) FAILED"
        print("Auto Learn policy: \(failSummary)")
        if failures > 0 { exit(1) }
    }

    /// The acceptance failures, pinned: meaning changes, app boundaries, a term inside a sentence.
    static func previouslyFailedScenarios() {
        let approve = observation(inserted: "approve", observed: "reject", session: sessionB)
        expect(decide("approve", "reject", session: sessionA, prior: [approve]),
               .rejected(.common), "a meaning-changing swap never promotes, even twice")

        let persisted = DictationEntry(
            spoken: "approve", replacement: "reject", kind: .spelling,
            approval: .suggested, isEnabled: false, scopeBundleID: "com.apple.TextEdit",
            origin: .autoLearn, evidence: 1, lastSessionID: sessionB)
        expect(decide("approve", "reject", session: sessionA, existing: [persisted]),
               .rejected(.common),
               "a persisted suggestion does not turn a meaning change into a rule")

        let elsewhere = observation(
            inserted: "кубер нетис", observed: "Kubernetes", session: sessionB,
            bundleID: "com.apple.Safari")
        expect(decide("кубер нетис", "Kubernetes", session: sessionA, prior: [elsewhere]),
               .suggest(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "Kubernetes",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "another app's correction is not the second signal")

        var dictionary = DictationDictionary()
        expect(dictionary.observe(elsewhere),
               .suggest(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "Kubernetes",
                   scopeBundleID: "com.apple.Safari", observations: 1)),
               "the first app suggests its own scoped pair")
        expect(dictionary.observe(observation(
                   inserted: "кубер нетис", observed: "Kubernetes", session: sessionA)),
               .suggest(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "Kubernetes",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "a second app is a first observation there, not a promotion")
        expect(dictionary.entries.count, 2, "each app keeps its own suggestion")
        expect(dictionary.entries.map(\.scopeBundleID),
               ["com.apple.Safari", "com.apple.TextEdit"],
               "both suggestions stay scoped to the app that made them")
        expect(dictionary.entries.allSatisfy { $0.approval == .suggested },
               "a cross-app repeat never promotes")

        let inserted = "нужно запустить кубер нетис в тестовом окружении"
        let observed = "нужно запустить Kubernetes в тестовом окружении"
        expect(decide(inserted, observed, session: sessionA,
                      prior: [observation(inserted: inserted, observed: observed, session: sessionB)]),
               .autoApply(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "Kubernetes",
                   scopeBundleID: "com.apple.TextEdit", observations: 2)),
               "a term inside a long dictation learns only the changed phrase")

        var learned = DictationDictionary()
        learned.observe(observation(inserted: inserted, observed: observed, session: sessionB))
        expect(learned.observe(observation(inserted: inserted, observed: observed, session: sessionA)),
               .autoApply(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "Kubernetes",
                   scopeBundleID: "com.apple.TextEdit", observations: 2)),
               "the second run promotes the extracted pair through observe")
        expect(learned.entries.count, 1, "promotion reuses the entry the first run made")
        expect(learned.entries.first?.spoken, "кубер нетис",
               "the stored spoken form is the phrase, never the sentence")
        expect(learned.entries.first?.replacement, "Kubernetes",
               "the stored replacement keeps its capitalization")
    }

    /// One session may only propose: the suggestion queue is the user's decision.
    static func suggestOnOneSession() {
        expect(decide("кубер нетис", "kubernetes"),
               .suggest(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "kubernetes",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "one session suggests the pair with its app scope")
    }

    /// Two independent sessions that made the same correction are the auto-apply signal.
    static func autoApplyAfterTwoIndependentSessions() {
        let earlier = observation(inserted: "харди", observed: "Hardy", session: sessionB)
        expect(decide("харди", "Hardy", session: sessionA, prior: [earlier]),
               .autoApply(AutoLearnCandidate(
                   spoken: "харди", replacement: "Hardy",
                   scopeBundleID: "com.apple.TextEdit", observations: 2)),
               "two sessions with the same correction auto-apply")

        let sameSession = observation(inserted: "харди", observed: "Hardy", session: sessionA)
        expect(decide("харди", "Hardy", session: sessionA, prior: [sameSession]),
               .suggest(AutoLearnCandidate(
                   spoken: "харди", replacement: "Hardy",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "a repeat inside one session only suggests, and is one signal")

        let unrelated = observation(inserted: "харди", observed: "Hardy2", session: sessionB)
        expect(decide("харди", "Hardy", session: sessionA, prior: [unrelated]),
               .suggest(AutoLearnCandidate(
                   spoken: "харди", replacement: "Hardy",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "a prior observation of another pair is not the second signal")
    }

    static func rejections() {
        expect(decide("кубер", "кубер"), .rejected(.notCorrection),
               "an unchanged span is not a correction")
        expect(decide("кубер", "КУБЕР"), .rejected(.notCorrection),
               "case alone is not a correction")
        expect(decide("кубер", "кубер."), .rejected(.notCorrection),
               "appended punctuation is not a correction")
        expect(decide("кубер нетис", "кубер, нетис"), .rejected(.notCorrection),
               "punctuation inside the span is not a correction")
        expect(decide("кубер", ""), .rejected(.notCorrection),
               "an empty observed side is not a correction")
        expect(decide("", "кубер"), .rejected(.notCorrection),
               "an empty inserted side is not a correction")

        expect(decide("кубер", "the"), .rejected(.common),
               "a substitution to a stop word is common, never learned")
        expect(decide("кубер", "и"), .rejected(.common),
               "a Russian stop word is common too")
        expect(decide("один два три четыре", "four"), .rejected(.unsafe),
               "more than three inserted words is unsafe")
        expect(decide("кубер", "the one two three four"), .rejected(.unsafe),
               "more than three observed words is unsafe")
        expect(decide("кубер", String(repeating: "ы", count: 25)), .rejected(.unsafe),
               "an over-long side is unsafe")
        expect(decide("кубер", "ку,бер2"), .rejected(.unsafe),
               "punctuation plus a real change is unsafe")
        expect(decide("один", "два три"), .rejected(.unsafe),
               "one word becoming two is unsafe")
        expect(decide("один два", "три четыре"), .rejected(.unsafe),
               "two of two words differing is unsafe")
        expect(decide("один два три", "два три"), .rejected(.unsafe),
               "a phrase may only collapse to one word, not to a shorter phrase")
        expect(decide("один два три", "один три"), .rejected(.unsafe),
               "dropping a middle word is unsafe")

        let existing = [DictationEntry(spoken: "харди", replacement: "Hardy")]
        expect(decide(" харди ", "hardy", existing: existing), .rejected(.duplicate),
               "a pair the dictionary already holds is a duplicate")
    }

    static func ambiguousAndRewrites() {
        expect(decide("кубер нетис", "нетис кубер"), .rejected(.ambiguous),
               "the same words reordered are ambiguous")
    }

    /// The two shapes the policy must accept: one word swapped for one, and a phrase collapsing.
    static func acceptedShapes() {
        expect(decide("кубер нетис", "kubernetes"),
               .suggest(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "kubernetes",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "two words collapsing to one term suggests")
        expect(decide("кубер нетис", "кубер netis"),
               .suggest(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "кубер netis",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "one of two words changed suggests")
        expect(decide("recieve", "receive"),
               .suggest(AutoLearnCandidate(
                   spoken: "recieve", replacement: "receive",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "a one-word spelling fix suggests")
        expect(decide("харди", "Hardy", session: sessionA,
                      prior: [observation(inserted: "харди", observed: "Hardy", session: sessionB)],
                      existing: [DictationEntry(spoken: "харди", replacement: "Hardy")]),
               .rejected(.duplicate),
               "the duplicate check runs before the auto-apply signal")
        expect(AutoLearnPolicy.maximumWindow == .seconds(60),
               "the monitor window is 60 s")
    }
}
