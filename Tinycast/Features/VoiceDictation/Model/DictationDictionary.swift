import Foundation

struct DictationEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable { case term, spelling, phrase }
    enum Approval: String, Codable, Sendable, CaseIterable { case approved, suggested }
    enum Origin: String, Codable, Sendable, CaseIterable { case manual, autoLearn }

    var id: UUID
    var spoken: String
    var replacement: String
    var kind: Kind
    var approval: Approval
    var isEnabled: Bool
    var scopeBundleID: String?
    var origin: Origin
    var createdAt: Date
    /// Independent observations behind a learned rule; the second one is what turns it on.
    var evidence: Int
    /// The session that last counted for this rule, so one session never counts twice.
    var lastSessionID: UUID?

    init(id: UUID = UUID(), spoken: String, replacement: String, kind: Kind = .term,
         approval: Approval = .approved, isEnabled: Bool = true,
         scopeBundleID: String? = nil, origin: Origin = .manual, createdAt: Date = Date(),
         evidence: Int = 1, lastSessionID: UUID? = nil) {
        self.id = id
        self.spoken = spoken
        self.replacement = replacement
        self.kind = kind
        self.approval = approval
        self.isEnabled = isEnabled
        self.scopeBundleID = scopeBundleID
        self.origin = origin
        self.createdAt = createdAt
        self.evidence = evidence
        self.lastSessionID = lastSessionID
    }

    /// A file written before these fields existed still loads: absence is one observation, no session.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        spoken = try container.decode(String.self, forKey: .spoken)
        replacement = try container.decode(String.self, forKey: .replacement)
        kind = try container.decode(Kind.self, forKey: .kind)
        approval = try container.decode(Approval.self, forKey: .approval)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        scopeBundleID = try container.decodeIfPresent(String.self, forKey: .scopeBundleID)
        origin = try container.decode(Origin.self, forKey: .origin)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        evidence = try container.decodeIfPresent(Int.self, forKey: .evidence) ?? 1
        lastSessionID = try container.decodeIfPresent(UUID.self, forKey: .lastSessionID)
    }
}

struct DictationDictionary: Codable, Equatable, Sendable {
    enum Rejection: Equatable, Sendable { case empty, tooLong, identical, duplicate, unsafe }

    static let maximumSpokenWords = 6
    static let maximumSpokenLength = 64

    private(set) var entries: [DictationEntry]

    init(entries: [DictationEntry] = []) {
        self.entries = entries
    }

    static func validate(spoken: String, replacement: String) -> Rejection? {
        let spokenUnits = spoken.unicodeScalars.count
        let trimmedSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if spokenUnits == 0 || trimmedSpoken.isEmpty || trimmedReplacement.isEmpty {
            return .empty
        }
        let wordCount = trimmedSpoken.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        if wordCount > maximumSpokenWords || spokenUnits > maximumSpokenLength {
            return .tooLong
        }
        if !trimmedSpoken.contains(where: { $0.isLetter || $0.isNumber }) {
            return .unsafe
        }
        if replacement.contains(where: { $0.isNewline || $0 == "\r" }) {
            return .unsafe
        }
        if normalizeText(trimmedSpoken) == normalizeText(trimmedReplacement) {
            return .identical
        }
        return nil
    }

    /// Approved + enabled + scope-matching entries, longest `spoken` first, stable order.
    func active(for bundleID: String?) -> [DictationEntry] {
        entries.filter { entry in
            guard entry.approval == .approved, entry.isEnabled else { return false }
            guard let scope = entry.scopeBundleID else { return true }
            return scope == bundleID
        }
        .sorted { lhs, rhs in
            let lhsWords = spokenWordCount(lhs.spoken)
            let rhsWords = spokenWordCount(rhs.spoken)
            if lhsWords != rhsWords { return lhsWords > rhsWords }
            let lhsLength = lhs.spoken.unicodeScalars.count
            let rhsLength = rhs.spoken.unicodeScalars.count
            if lhsLength != rhsLength { return lhsLength > rhsLength }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func entry(id: UUID) -> DictationEntry? {
        entries.first { $0.id == id }
    }

    /// Inserts a new entry, or replaces the one holding this id. Returns nil, changing nothing,
    /// when `validate` rejects the pair or another entry of the same scope already holds it.
    @discardableResult
    mutating func upsert(_ entry: DictationEntry) -> DictationEntry? {
        guard DictationDictionary.validate(spoken: entry.spoken, replacement: entry.replacement) == nil
        else { return nil }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            guard !holds(pair: entry) else { return nil }
            entries.append(entry)
        }
        return entry
    }

    /// One more independent observation: carries the count, and promotes a suggestion when asked.
    @discardableResult
    mutating func recordObservation(
        id: UUID, evidence: Int, sessionID: UUID, approve: Bool
    ) -> DictationEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[index].evidence = max(evidence, 1)
        entries[index].lastSessionID = sessionID
        if approve {
            entries[index].approval = .approved
            entries[index].isEnabled = true
        }
        return entries[index]
    }

    /// One correction: the policy decides, and only the extracted pair is ever kept.
    @discardableResult
    mutating func observe(_ observation: ObservedCorrection) -> AutoLearnDecision {
        let decision = AutoLearnPolicy.decide(observation, prior: [], existing: entries)
        switch decision {
        case .rejected(.duplicate), .rejected:
            break
        case .suggest(let candidate):
            apply(candidate, approve: false, sessionID: observation.sessionID)
        case .autoApply(let candidate):
            apply(candidate, approve: true, sessionID: observation.sessionID)
        }
        return decision
    }

    /// Updates the entry already holding the pair in place: evidence never buys a second rule.
    private mutating func apply(_ candidate: AutoLearnCandidate, approve: Bool, sessionID: UUID) {
        if let held = entry(
            matchingSpoken: candidate.spoken, replacement: candidate.replacement,
            scopeBundleID: candidate.scopeBundleID),
            let index = entries.firstIndex(where: { $0.id == held.id }) {
            entries[index].evidence = candidate.observations
            entries[index].lastSessionID = sessionID
            if approve, entries[index].approval == .suggested {
                entries[index].approval = .approved
                entries[index].isEnabled = true
            }
            return
        }
        let words = candidate.spoken.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        upsert(DictationEntry(
            spoken: candidate.spoken, replacement: candidate.replacement,
            kind: words > 1 ? .phrase : .spelling,
            approval: approve ? .approved : .suggested, isEnabled: approve,
            scopeBundleID: candidate.scopeBundleID, origin: .autoLearn,
            evidence: candidate.observations, lastSessionID: sessionID))
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    @discardableResult
    mutating func approve(id: UUID) -> DictationEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[index].approval = .approved
        return entries[index]
    }

    @discardableResult
    mutating func setEnabled(_ isEnabled: Bool, id: UUID) -> DictationEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[index].isEnabled = isEnabled
        return entries[index]
    }

    /// The entry holding this pair — a global entry covers every app, a scoped one only its own.
    func entry(
        matchingSpoken spoken: String, replacement: String, scopeBundleID: String?
    ) -> DictationEntry? {
        let spokenKey = normalizeText(spoken)
        let replacementKey = normalizeText(replacement)
        return entries.first {
            normalizeText($0.spoken) == spokenKey
                && normalizeText($0.replacement) == replacementKey
                && ($0.scopeBundleID == nil || $0.scopeBundleID == scopeBundleID)
        }
    }

    /// A pair the dictionary already holds, by normalized text rather than literal case or spacing.
    func contains(samePairAs entry: DictationEntry) -> Bool {
        self.entry(
            matchingSpoken: entry.spoken, replacement: entry.replacement,
            scopeBundleID: entry.scopeBundleID) != nil
    }

    /// A pair another entry already resolves, so one `spoken` never means two things.
    private func holds(pair entry: DictationEntry) -> Bool {
        self.entry(
            matchingSpoken: entry.spoken, replacement: entry.replacement,
            scopeBundleID: entry.scopeBundleID) != nil
    }
}

/// The Foundation-only, file-backed store: takes the directory as an injected parameter.
struct DictationDictionaryStore: Sendable {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("dictation-dictionary.json")
    }

    func load() -> DictationDictionary {
        guard let data = try? Data(contentsOf: fileURL),
              let dictionary = try? JSONDecoder().decode(DictationDictionary.self, from: data) else {
            return DictationDictionary()
        }
        return dictionary
    }

    func save(_ dictionary: DictationDictionary) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(dictionary)
        try data.write(to: fileURL, options: .atomic)
    }
}

private func normalizeText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.lowercased()
        .filter { !$0.isWhitespace }
}

private func spokenWordCount(_ spoken: String) -> Int {
    spoken.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
}
