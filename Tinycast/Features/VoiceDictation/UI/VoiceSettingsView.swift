import SwiftUI

/// The one pane that owns both voice actions: dictation into the field you were in, and talking
/// to the launcher. Sharing it keeps the microphone, model and dictionary in one place.
struct VoiceSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var dictation

    @AppStorage("speechVoice.enabled") private var voiceCommandsEnabled = false
    @AppStorage("speechVoice.commandsEnabled") private var voiceRouterEnabled = true

    @State private var status: SpeechRuntimeStatus = .unknown
    @State private var models: [SpeechRuntimeModel] = []
    @State private var isSettingUp = false
    @State private var newSpoken = ""
    @State private var newReplacement = ""
    @State private var editingID: UUID?
    @State private var editedSpoken = ""
    @State private var editedReplacement = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            voiceSection($settings)
            shortcutsSection($settings)
            runtimeSection
            dictionarySection
            autoLearnSection
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.voice)
        .releasesFocusOnOutsideClick()
        .task { await refreshRuntime() }
    }

    // MARK: - Voice

    @ViewBuilder
    private func voiceSection(_ settings: Bindable<AppSettings>) -> some View {
        Section {
            Toggle(isOn: settings.dictationEnabled) {
                SettingsFeatureToggleLabel(
                    anchor: .voiceVoice, title: "Dictation",
                    subtitle: "Speak and the words land in the field you were already in.")
            }
            Toggle("Voice commands", isOn: $voiceCommandsEnabled)
                .onChange(of: voiceCommandsEnabled) { core.applyInstalledAILifecycle() }
            Toggle("Run Tinycast voice commands", isOn: $voiceRouterEnabled)
                .settingsEnabled(voiceCommandsEnabled)
            Toggle(isOn: settings.dictationAutoLearnEnabled) {
                SettingsRowTitle(.voiceAutoLearn, "Auto Learn")
                Text("Watch the line you dictated just now for a correction, and offer a rule.")
            }
            .settingsEnabled(settings.dictationEnabled.wrappedValue)
            Toggle(isOn: settings.dictationCleanupEnabled) {
                SettingsRowTitle(.voiceVoice, "Text Cleanup")
                Text("Spacing and capitalization only. Nothing is rewritten.")
            }
            .settingsEnabled(settings.dictationEnabled.wrappedValue)
        } header: {
            SettingsSectionHeader(.voiceVoice)
        } footer: {
            Text(
                """
                Speech Runtime recognizes everything locally on this Mac. Dictation types into \
                the focused field; voice commands talk to the launcher instead.
                """
            )
        }
    }

    // MARK: - Shortcuts

    @ViewBuilder
    private func shortcutsSection(_ settings: Bindable<AppSettings>) -> some View {
        Section {
            LabeledContent("Dictation") { ShortcutRecorder(action: .dictation) }
            LabeledContent("Voice commands") { ShortcutRecorder(action: .voiceAsk) }
            Picker("Dictation key behaviour", selection: settings.dictationShortcutMode) {
                ForEach(VoiceShortcutMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .settingsEnabled(settings.dictationEnabled.wrappedValue)
            Picker("Voice commands key behaviour", selection: settings.voiceShortcutMode) {
                ForEach(VoiceShortcutMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .settingsEnabled(voiceCommandsEnabled)
        } header: {
            SettingsSectionHeader(.voiceShortcuts)
        } footer: {
            Text(
                """
                Smart finishes a press the moment you let go, so a tap starts and stops. \
                Toggle starts on one press and stops on the next. Hold records while held.
                """
            )
        }
    }

    // MARK: - Speech Runtime

    private var runtimeSection: some View {
        Section {
            SettingsRow(title: "Speech Runtime", subtitle: status.summary, anchor: .voiceVoice) {
                if isSettingUp {
                    ProgressView().controlSize(.small)
                } else {
                    runtimeAction
                }
            }
            if !models.isEmpty {
                Picker(selection: modelBinding) {
                    Text("Speech Runtime default").tag("")
                    ForEach(models, id: \.model) { model in
                        Text(model.model).tag(model.model)
                    }
                } label: {
                    SettingsRowTitle(.voiceVoice, "Dictation model")
                }
                .settingsEnabled(settings.dictationEnabled)
            }
        } header: {
            Text("Speech Runtime")
        } footer: {
            Text(
                """
                Speech Runtime recognizes speech locally on this Mac. Models are downloaded \
                only in Speech Runtime.app, with your confirmation there — Tinycast never \
                downloads one, and loads a model only when you start dictating.
                """
            )
        }
    }

    @ViewBuilder
    private var runtimeAction: some View {
        switch status {
        case .unknown, .stopped:
            Button("Start Speech Runtime…") { Task { await setUp() } }
        case .notInstalled:
            Button("Get Speech Runtime…") { openRuntimeDownload() }
        case .needsModel:
            Button("Install Model in Speech Runtime…") { openRuntimeAppForModelInstall() }
        case .ready(let models) where models.isEmpty:
            Button("Install Model in Speech Runtime…") { openRuntimeAppForModelInstall() }
        case .ready, .starting:
            EmptyView()
        case .failed:
            Button("Try Again") { Task { await setUp() } }
        }
    }

    private func openRuntimeAppForModelInstall() {
        if core.speechRuntime.openRuntimeApp() { return }
        core.showMessage(
            String(localized: "Speech Runtime isn't responding. Opening the download page instead."),
            tone: .neutral)
        openRuntimeDownload()
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.dictationModel }, set: { settings.dictationModel = $0 })
    }

    private func refreshRuntime() async {
        status = await core.speechRuntime.probe(model: settings.dictationModel)
        await refreshModels()
    }

    private func setUp() async {
        guard !isSettingUp else { return }
        isSettingUp = true
        defer { isSettingUp = false }
        status = await core.speechRuntime.ensureRunning(model: settings.dictationModel)
        await refreshModels()
    }

    private func refreshModels() async {
        if case .ready(let discovered) = status {
            models = discovered
        } else if case .needsModel = status {
            models = (try? await core.speechRuntime.models()) ?? []
        }
    }

    private func openRuntimeDownload() {
        guard let url = URL(string: "https://speechruntime.app") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Dictionary

    private var dictionarySection: some View {
        Section {
            if !dictation.suggestions.isEmpty { suggestions }
            ForEach(dictation.dictionary.entries.filter { $0.approval == .approved }) { entry in
                entryRow(entry)
            }
            addRow
        } header: {
            SettingsSectionHeader(.voiceDictionary)
        } footer: {
            Text(
                """
                Corrections apply to the words you dictated, after cleanup and before insertion. \
                A rule scoped to one app only fires there.
                """
            )
        }
    }

    private var suggestions: some View {
        ForEach(dictation.suggestions) { entry in
            SettingsRow(
                title: String(localized: "\(entry.spoken) → \(entry.replacement)"),
                subtitle: String(localized: "Suggested after you corrected a dictation")
            ) {
                HStack(spacing: Theme.Spacing.md) {
                    Button("Add") { dictation.approve(id: entry.id) }
                    Button("Dismiss") { dictation.reject(id: entry.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: DictationEntry) -> some View {
        if editingID == entry.id {
            SettingsRow(title: entry.spoken, subtitle: entry.scopeDescription) {
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("Heard", text: $editedSpoken).frame(maxWidth: 130)
                    TextField("Replacement", text: $editedReplacement).frame(maxWidth: 130)
                    Button("Save") { save(entry) }
                    Button("Cancel") { editingID = nil }
                }
            }
        } else {
            SettingsRow(
                title: String(localized: "\(entry.spoken) → \(entry.replacement)"),
                subtitle: entry.scopeDescription
            ) {
                HStack(spacing: Theme.Spacing.md) {
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { entry.isEnabled },
                            set: { dictation.setEnabled($0, id: entry.id) })
                    )
                    .labelsHidden()
                    Button {
                        editedSpoken = entry.spoken
                        editedReplacement = entry.replacement
                        editingID = entry.id
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        dictation.remove(id: entry.id)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var addRow: some View {
        SettingsRow(title: String(localized: "Add a term or phrase")) {
            HStack(spacing: Theme.Spacing.sm) {
                TextField("Heard", text: $newSpoken).frame(maxWidth: 130)
                TextField("Replacement", text: $newReplacement).frame(maxWidth: 130)
                Button("Add") {
                    guard dictation.addEntry(spoken: newSpoken, replacement: newReplacement) != nil
                    else {
                        core.showMessage(
                            String(localized: "That pair cannot be used"), tone: .neutral)
                        return
                    }
                    newSpoken = ""
                    newReplacement = ""
                }
                .disabled(
                    newSpoken.trimmingCharacters(in: .whitespaces).isEmpty
                        || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save(_ entry: DictationEntry) {
        var updated = entry
        updated.spoken = editedSpoken
        updated.replacement = editedReplacement
        dictation.update(updated)
        editingID = nil
    }

    // MARK: - Auto Learn

    private var autoLearnSection: some View {
        Section {
            Text(
                """
                Auto Learn watches only the range Tinycast just typed, in a normal text field, \
                for up to a minute after insertion. It never reads the rest of the document, \
                never runs while dictation is off, and stops at a secure field or a change of focus.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let decision = dictation.lastAutoLearn {
                SettingsRow(title: String(localized: "Last result"), subtitle: decision.summary) {
                    EmptyView()
                }
            }
        } header: {
            SettingsSectionHeader(.voiceAutoLearn)
        }
    }
}

extension VoiceShortcutMode {
    var title: String {
        switch self {
        case .smart: String(localized: "Smart")
        case .toggle: String(localized: "Toggle")
        case .hold: String(localized: "Hold")
        }
    }
}

extension AutoLearnDecision {
    var summary: String {
        switch self {
        case .rejected(.notCorrection): String(localized: "No correction was seen")
        case .rejected(.ambiguous): String(localized: "Too ambiguous to learn")
        case .rejected(.unsafe): String(localized: "Too different to be a correction")
        case .rejected(.common): String(localized: "A common word, so it was left alone")
        case .rejected(.duplicate): String(localized: "Already in the dictionary")
        case .suggest(let candidate):
            String(localized: "Suggested: \(candidate.spoken) → \(candidate.replacement)")
        case .autoApply(let candidate):
            String(localized: "Added: \(candidate.spoken) → \(candidate.replacement)")
        }
    }
}

extension DictationEntry {
    /// Where a rule applies, as a sentence: the dictionary is the only place scope is stated.
    var scopeDescription: String {
        guard let scopeBundleID else { return String(localized: "Every app") }
        return String(localized: "Only in \(scopeBundleID)")
    }
}
