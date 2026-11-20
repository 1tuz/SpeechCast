import Foundation

@main
@MainActor
struct DictationDictionaryTest {
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

    static func validate(_ spoken: String, _ replacement: String) -> DictationDictionary.Rejection? {
        DictationDictionary.validate(spoken: spoken, replacement: replacement)
    }

    static let sessionA = UUID()
    static let sessionB = UUID()

    static func observation(
        _ inserted: String, _ observed: String, session: UUID,
        bundleID: String? = "com.apple.TextEdit"
    ) -> ObservedCorrection {
        ObservedCorrection(
            inserted: inserted, observed: observed, bundleID: bundleID,
            at: Date(timeIntervalSince1970: 1_000), sessionID: session)
    }

    static func main() throws {
        // Rejections: empty / whitespace-only sides.
        expect(validate("", "x"), .empty, "empty spoken is rejected as empty")
        expect(validate("   ", "x"), .empty, "whitespace-only spoken is rejected as empty")
        expect(validate("x", ""), .empty, "empty replacement is rejected as empty")
        expect(validate("x", " \n "), .empty, "whitespace-only replacement is rejected as empty")
        // Too long: word count and UTF-16 unit count.
        let sevenWords = (1...7).map(String.init).joined(separator: " ")
        expect(validate(sevenWords, "x"), .tooLong, "spoken with more than maximumSpokenWords words is rejected")
        expect(validate("word", String(repeating: "ы", count: 65)), nil,
               "a long replacement alone is not rejected")
        let longSpoken = String(repeating: "а", count: 65)
        expect(validate(longSpoken, "x"), .tooLong, "spoken longer than maximumSpokenLength units is rejected")
        // Identical normalized forms.
        expect(validate("кубер", "КУБЕР"), .identical, "identical after normalization is rejected")
        expect(validate("hello", "hello"), .identical, "literally identical pair is rejected")
        // Punctuation-only spoken is unsafe; newline in replacement is unsafe.
        expect(validate("...", "x"), .unsafe, "punctuation-only spoken is rejected as unsafe")
        expect(validate("«»—", "x"), .unsafe, "pure punctuation spoken is rejected as unsafe")
        expect(validate("word", "line\nbreak"), .unsafe, "newline in replacement is rejected as unsafe")
        expect(validate("word", "line\rbreak"), .unsafe, "carriage return in replacement is rejected as unsafe")
        // A valid pair passes.
        expect(validate("кубер нетис", "Kubernetes"), nil, "a valid pair is not rejected")

        // active(for:) filters by approval, enabled flag and app scope, longest spoken first.
        let now = Date()
        let single = DictationEntry(spoken: "кубер", replacement: "Kubernetes", createdAt: now)
        let phrase = DictationEntry(
            spoken: "кубер нетис", replacement: "Kubernetes",
            approval: .approved, createdAt: now.addingTimeInterval(1))
        let scoped = DictationEntry(
            spoken: "харди", replacement: "Hardy",
            scopeBundleID: "com.apple.mail", createdAt: now.addingTimeInterval(2))
        let suggested = DictationEntry(
            spoken: "заметка", replacement: "note",
            approval: .suggested, createdAt: now.addingTimeInterval(3))
        let disabled = DictationEntry(
            spoken: "таблица", replacement: "table",
            isEnabled: false, createdAt: now.addingTimeInterval(4))
        let scopedElsewhere = DictationEntry(
            spoken: "окно", replacement: "window",
            scopeBundleID: "com.apple.safari", createdAt: now.addingTimeInterval(5))
        var dictionary = DictationDictionary(entries: [single, phrase, scoped, suggested, disabled, scopedElsewhere])

        let global = dictionary.active(for: nil)
        expect(global.map(\.id), [phrase.id, single.id], "nil scope sees only global approved+enabled, longest first")
        let mail = dictionary.active(for: "com.apple.mail")
        expect(mail.map(\.id), [phrase.id, single.id, scoped.id],
               "scoped entry appears only for its bundle, ties in length keep insertion order")
        let safari = dictionary.active(for: "com.apple.safari")
        expect(safari.map(\.id), [phrase.id, single.id, scopedElsewhere.id],
               "another app's scope entry is excluded, its own stays, ties keep order")
        let wordy = DictationEntry(
            spoken: "один два три четыре пять шесть", replacement: "six", createdAt: now)
        let phrasey = DictationEntry(
            spoken: "один два три четыре", replacement: "four", createdAt: now.addingTimeInterval(1))
        var lengthOrder = DictationDictionary(entries: [wordy, phrasey, single])
        expect(lengthOrder.active(for: nil).map(\.id), [wordy.id, phrasey.id, single.id],
               "longest spoken first regardless of storage order")
        lengthOrder = DictationDictionary(entries: [single, phrasey, wordy])
        expect(lengthOrder.active(for: nil).map(\.id), [wordy.id, phrasey.id, single.id],
               "ordering is stable across insertion orders")

        // entry(id:) lookup.
        expect(dictionary.entry(id: single.id), single, "entry(id:) finds the entry")
        expect(dictionary.entry(id: UUID()), nil, "entry(id:) returns nil for an unknown id")

        // upsert: rejects validation failures and unknown ids, updates known entries.
        var update = single
        update.replacement = "k8s"
        expect(dictionary.upsert(update)?.replacement, "k8s", "upsert updates a known entry")
        expect(dictionary.entry(id: single.id)?.replacement, "k8s", "upsert persists the update")
        expect(dictionary.upsert(wordy)?.id, wordy.id, "upsert inserts an id the dictionary does not hold")
        expect(dictionary.entries.contains { $0.id == wordy.id }, true, "the insert is stored")
        expect(dictionary.upsert(DictationEntry(spoken: "кубер", replacement: "k8s")), nil,
               "upsert refuses a pair another entry already holds")
        expect(dictionary.entries.count, 7, "a refused duplicate pair inserts nothing")
        var invalid = single
        invalid.spoken = "..."
        expect(dictionary.upsert(invalid), nil, "upsert refuses a validation failure")
        expect(dictionary.entry(id: single.id)?.spoken, "кубер", "a refused upsert changes nothing")
        var rescoped = DictationEntry(
            spoken: "кубер", replacement: "k8s", scopeBundleID: "com.apple.mail")
        expect(dictionary.upsert(rescoped), nil,
               "a pair the global entry already resolves is refused under an app scope")
        rescoped.replacement = "KUBERNETES"
        expect(dictionary.upsert(rescoped)?.id, rescoped.id,
               "another replacement for the same spoken form is its own entry")
        expect(dictionary.active(for: "com.apple.mail").map(\.id),
               [wordy.id, phrase.id, single.id, rescoped.id, scoped.id],
               "every active rule for the app, longest spoken first, ties in creation order")
        dictionary.remove(id: rescoped.id)

        // recordObservation carries the count and promotes a suggestion when asked.
        var fresh = DictationDictionary(entries: [suggested])
        expect(fresh.recordObservation(id: suggested.id, evidence: 2, sessionID: sessionA, approve: true)?
            .approval, .approved, "recordObservation approves when asked")
        expect(fresh.entry(id: suggested.id)?.evidence, 2, "recordObservation carries the count")
        expect(fresh.entry(id: suggested.id)?.lastSessionID, sessionA, "recordObservation records its session")
        expect(fresh.entry(id: suggested.id)?.isEnabled, true, "an approved rule is enabled")
        expect(fresh.recordObservation(id: suggested.id, evidence: 3, sessionID: sessionB, approve: false)?
            .approval, .approved, "recordObservation leaves approval alone when not asked")
        expect(fresh.entry(id: suggested.id)?.evidence, 3, "a later count replaces the earlier one")
        var empty = DictationDictionary()
        expect(empty.recordObservation(
            id: UUID(), evidence: 1, sessionID: sessionA, approve: true), nil,
            "recordObservation of an unknown id returns nil")

        // remove / approve / setEnabled.
        dictionary.remove(id: suggested.id)
        expect(dictionary.entry(id: suggested.id), nil, "remove deletes the entry")
        expect(dictionary.approve(id: disabled.id)?.approval, .approved, "approve marks the entry approved")
        expect(dictionary.setEnabled(false, id: scoped.id)?.isEnabled, false, "setEnabled flips the flag")
        expect(dictionary.approve(id: UUID()), nil, "approve of an unknown id returns nil")
        expect(dictionary.setEnabled(true, id: UUID()), nil, "setEnabled of an unknown id returns nil")

        // contains(samePairAs:) matches the normalized pair, not the literal text.
        expect(dictionary.contains(samePairAs: DictationEntry(spoken: " КУБЕР ", replacement: "k8s")), true,
               "contains matches case and whitespace variants")
        expect(dictionary.contains(samePairAs: DictationEntry(spoken: "кубер", replacement: "Kubernetes")), false,
               "contains does not match a different replacement")

        // entry(matchingSpoken:replacement:scopeBundleID:): a global entry covers every app.
        let scopedOnly = DictationDictionary(entries: [scoped])
        expect(scopedOnly.entry(
            matchingSpoken: "ХАРДИ", replacement: "hardy", scopeBundleID: "com.apple.mail")?.id, scoped.id,
            "a scoped entry is found for its own app, case aside")
        expect(scopedOnly.entry(
            matchingSpoken: "харди", replacement: "Hardy", scopeBundleID: "com.apple.safari"), nil,
            "another app's scope entry is not the pair")
        expect(scopedOnly.entry(
            matchingSpoken: "харди", replacement: "Hardy", scopeBundleID: nil), nil,
            "a scoped entry does not cover an unscoped question")
        let globalOnly = DictationDictionary(entries: [single])
        expect(globalOnly.entry(
            matchingSpoken: "кубер", replacement: "Kubernetes", scopeBundleID: "com.apple.mail")?.id,
            single.id, "a global entry answers for any app")

        // Store round-trip, corrupt-file load, atomic overwrite — in an isolated temp directory.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-dictionary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationDictionaryStore(directory: root)

        expect(store.load().entries, [], "a missing file loads as an empty dictionary")
        let saved = DictationDictionary(entries: [single, phrase])
        try store.save(saved)
        expect(store.load(), saved, "a saved dictionary round-trips")
        expect(store.load().entries.first?.id, single.id, "the round-trip preserves entry identity")

        try Data("not json {".utf8).write(to: store.fileURL)
        expect(store.load().entries, [], "a corrupt file loads as an empty dictionary")
        try store.save(DictationDictionary(entries: [phrase]))
        expect(store.load().entries.map(\.id), [phrase.id],
               "an atomic overwrite fully replaces the previous file")

        let nested = root.appendingPathComponent("nested/deeper")
        let nestedStore = DictationDictionaryStore(directory: nested)
        try nestedStore.save(DictationDictionary(entries: [single]))
        expect(nestedStore.load().entries.count, 1, "save creates missing directories")

        // observe(): one correction stores the pair; the second run promotes it in place.
        let sentence = "нужно запустить кубер нетис в тестовом окружении"
        let corrected = "нужно запустить Kubernetes в тестовом окружении"
        var learned = DictationDictionary()
        expect(learned.observe(observation(sentence, corrected, session: sessionA)),
               .suggest(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "Kubernetes",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "a first safe correction suggests the extracted pair")
        expect(learned.entries.count, 1, "one observation stores exactly one entry")
        let stored = learned.entries[0]
        expect(stored.approval, .suggested, "a suggestion waits for the user")
        expect(stored.isEnabled, false, "a suggestion does not apply to dictation")
        expect(stored.origin, .autoLearn, "the entry records where it came from")
        expect(stored.evidence, 1, "the first observation is the first piece of evidence")
        expect(stored.lastSessionID, sessionA, "the entry remembers the session it came from")
        expect(stored.spoken, "кубер нетис", "only the changed phrase is stored, never the sentence")
        expect(stored.replacement, "Kubernetes", "the replacement keeps the case the user typed")
        expect(stored.scopeBundleID, "com.apple.TextEdit", "the entry is scoped to the observing app")
        expect(stored.kind, .phrase, "a multi-word spoken form is a phrase")

        let snapshot = learned.entries
        expect(learned.observe(observation("харди", "ХАРДИ", session: sessionB)),
               .rejected(.notCorrection), "a case-only change is not a correction")
        expect(learned.observe(observation("approve", "reject", session: sessionB)),
               .rejected(.common), "a meaning-changing swap is common")
        expect(learned.entries, snapshot, "a rejected observation changes nothing")
        expect(learned.entries.count, 1, "a rejected observation stores nothing")

        let heldID = stored.id
        expect(learned.observe(observation(sentence, corrected, session: sessionB)),
               .autoApply(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "Kubernetes",
                   scopeBundleID: "com.apple.TextEdit", observations: 2)),
               "the second independent session auto-applies")
        expect(learned.entries.count, 1, "promotion reuses the entry instead of adding one")
        expect(learned.entries[0].id, heldID, "the same entry is promoted in place")
        expect(learned.entries[0].approval, .approved, "the promoted entry is approved")
        expect(learned.entries[0].isEnabled, true, "the promoted entry applies to dictation")
        expect(learned.entries[0].evidence, 2, "both sessions count as evidence")
        expect(learned.entries[0].lastSessionID, sessionB, "the promoted entry moves to the newer session")
        expect(learned.active(for: "com.apple.TextEdit").map(\.spoken), ["кубер нетис"],
               "the promoted rule is the one dictation applies")
        expect(learned.active(for: nil), [], "an app-scoped rule never leaks into every app")

        var sameRun = DictationDictionary()
        sameRun.observe(observation("харди", "Hardy", session: sessionA))
        expect(sameRun.observe(observation("харди", "Hardy", session: sessionA)),
               .suggest(AutoLearnCandidate(
                   spoken: "харди", replacement: "Hardy",
                   scopeBundleID: "com.apple.TextEdit", observations: 1)),
               "a repeat inside one session is one signal")
        expect(sameRun.entries[0].approval, .suggested, "one session never promotes")
        expect(sameRun.entries[0].evidence, 1, "one session never doubles the evidence")
        expect(sameRun.entries.count, 1, "a repeat never adds an entry")

        var offSuggestion = DictationDictionary()
        offSuggestion.observe(observation("харди", "Hardy", session: sessionA))
        offSuggestion.setEnabled(false, id: offSuggestion.entries[0].id)
        expect(offSuggestion.observe(observation("харди", "Hardy", session: sessionB)),
               .autoApply(AutoLearnCandidate(
                   spoken: "харди", replacement: "Hardy",
                   scopeBundleID: "com.apple.TextEdit", observations: 2)),
               "a switched-off suggestion still collects its second signal")
        expect(offSuggestion.entries[0].approval, .approved, "the second signal approves the suggestion")
        expect(offSuggestion.entries[0].isEnabled, true, "a promoted suggestion is switched on")
        expect(offSuggestion.entries.count, 1, "promotion adds no second entry")

        let suppressedEntry = DictationEntry(
            spoken: "харди", replacement: "Hardy", approval: .approved, isEnabled: false,
            scopeBundleID: "com.apple.TextEdit", origin: .autoLearn,
            evidence: 1, lastSessionID: sessionA)
        var suppressed = DictationDictionary(entries: [suppressedEntry])
        expect(suppressed.observe(observation("харди", "Hardy", session: sessionB)),
               .autoApply(AutoLearnCandidate(
                   spoken: "харди", replacement: "Hardy",
                   scopeBundleID: "com.apple.TextEdit", observations: 2)),
               "a rule the user switched off is still an earlier signal")
        expect(suppressed.entries[0].isEnabled, false, "observe respects the user's disable")
        expect(suppressed.entries[0].approval, .approved, "the approval is untouched")
        expect(suppressed.entries[0].evidence, 2, "the evidence is still recorded")
        expect(suppressed.entries[0].lastSessionID, sessionB, "the session is still recorded")
        expect(suppressed.entries.count, 1, "no second entry is created")

        var complete = DictationDictionary(entries: [
            DictationEntry(spoken: "харди", replacement: "Hardy", scopeBundleID: "com.apple.TextEdit")
        ])
        expect(complete.observe(observation("харди", "Hardy", session: sessionB)),
               .rejected(.duplicate), "an approved rule that already applies is a duplicate")
        expect(complete.entries.count, 1, "a duplicate changes nothing")

        // Reload: the persisted suggestion is the first signal, so the next run promotes it.
        let learnRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-learn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: learnRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: learnRoot) }
        let learnStore = DictationDictionaryStore(directory: learnRoot)

        var persisted = DictationDictionary()
        persisted.observe(observation(sentence, corrected, session: sessionA))
        try learnStore.save(persisted)
        var reloaded = learnStore.load()
        expect(reloaded.entries.count, 1, "the suggestion survives a restart")
        let reloadedID = reloaded.entries[0].id
        expect(reloaded.observe(observation(sentence, corrected, session: sessionB)),
               .autoApply(AutoLearnCandidate(
                   spoken: "кубер нетис", replacement: "Kubernetes",
                   scopeBundleID: "com.apple.TextEdit", observations: 2)),
               "a stored suggestion promotes on the next run")
        expect(reloaded.entries.count, 1, "the reloaded entry is promoted in place")
        expect(reloaded.entries[0].id, reloadedID, "the promotion keeps the reloaded identity")
        expect(reloaded.entries[0].spoken, "кубер нетис", "the spoken form survives the round trip")
        expect(reloaded.entries[0].replacement, "Kubernetes", "the stored case survives the round trip")
        expect(reloaded.entries[0].approval, .approved, "the promoted rule is approved")
        expect(reloaded.entries[0].isEnabled, true, "the promoted rule applies after a restart")
        expect(reloaded.entries[0].evidence, 2, "the restart does not lose the first observation")
        try learnStore.save(reloaded)
        let promoted = learnStore.load()
        expect(promoted.entries.count, 1, "the promoted rule is still one entry")
        expect(promoted.entries[0].evidence, 2, "the evidence is persisted")
        expect(promoted.entries[0].lastSessionID, sessionB, "the session is persisted")

        let failSummary = failures == 0 ? "all \(passes) assertions passed" : "\(failures) FAILED"
        print("Dictation dictionary: \(failSummary)")
        if failures > 0 { exit(1) }
    }
}
