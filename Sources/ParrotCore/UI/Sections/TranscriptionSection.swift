import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The model and the spoken language (#43).
struct TranscriptionSection: View {
    @ObservedObject var store: SettingsStore
    /// A model loading behind the one in use, after a change here.
    @ObservedObject private var loading = ModelLoadStatus.shared

    /// Every language Whisper knows, by name in the user's language.
    private static let languages: [(code: String, name: String)] = SpokenLanguage.whisperLanguages
        .map { (code: $0, name: SpokenLanguage.displayName($0)) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private var selectedModel: TranscriptionModel? {
        if let id = store.current.model.id { return ModelRegistry.find(id) }
        return ModelRegistry.recommended()
    }

    var body: some View {
        SettingsGroup("Transcription") {
            // Built by hand: LabeledContent aligns the menu with the first
            // line, and it should sit centered beside both.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model")
                    if let model = selectedModel, loading.current == nil {
                        Text(summary(model))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                PillMenu(title: selectedModel.map(Self.menuTitle) ?? store.current.model.id ?? "None") {
                    modelGroup("English", ModelRegistry.shared.filter { !$0.isMultilingual })
                    modelGroup("Multilingual", ModelRegistry.shared.filter(\.isMultilingual))
                }
            }

            if let state = loading.current {
                HStack(spacing: 6) {
                    switch state.phase {
                    case .downloading(let fraction?):
                        ProgressView(value: fraction).frame(width: 80)
                    case .downloading(nil), .loading:
                        ProgressView().controlSize(.small)
                    case .failed, .needsDownload:
                        EmptyView()
                    }
                    caption(Self.capitalized(state.text))
                }
            }

            languagePicker

            PillRow("Dictionary") {
                Button("Open Dictionary File") { Self.openDictionary() }
                    .buttonStyle(.pill)
            }
        }
    }

    /// One group of the Model menu, smallest first, with a checkmark on the
    /// selected model and a download arrow on each not yet on the Mac.
    @ViewBuilder
    private func modelGroup(_ title: String, _ models: [TranscriptionModel]) -> some View {
        Section(title) {
            ForEach(models.sorted { $0.sizeMB < $1.sizeMB }, id: \.id) { model in
                Toggle(isOn: Binding(
                    get: { selectedModel?.id == model.id },
                    set: { on in if on { store.update { $0.model = $0.model.selecting(model.id) } } }
                )) {
                    // A model not on the Mac yet downloads when chosen; the
                    // arrow says so without words.
                    if model.engine == .parakeet || TranscriberFactory.isCached(model) {
                        Text(Self.shortName(model))
                    } else {
                        Label(Self.shortName(model), systemImage: "arrow.down.circle")
                    }
                }
            }
        }
    }

    /// "Small" for "Whisper Small (English)": the menu's groups say the rest.
    private static func shortName(_ model: TranscriptionModel) -> String {
        model.displayName
            .replacingOccurrences(of: "Whisper ", with: "")
            .replacingOccurrences(of: " (English)", with: "")
    }

    /// The closed menu, where the groups don't show: "Base (English)".
    private static func menuTitle(_ model: TranscriptionModel) -> String {
        model.isMultilingual ? shortName(model) : "\(shortName(model)) (English)"
    }

    /// How each model trades speed for accuracy, measured with
    /// `parrot-bench transcription` on an M4 Pro (#43).
    private static let tradeOff: [String: String] = [
        "whisper-base.en": "Fastest",
        "whisper-small.en": "More accurate, slower",
        "whisper-small": "Fast",
        "whisper-large-v3-turbo": "Most accurate, slowest",
    ]

    /// "Fastest · English only · 145 MB". Not shown while the model loads:
    /// the progress line under the menu says that instead.
    private func summary(_ model: TranscriptionModel) -> String {
        let languages = model.isMultilingual ? "\(model.supportedLanguages.count) languages" : "English only"
        let size = model.sizeMB >= 1000
            ? String(format: "%.1f GB", Double(model.sizeMB) / 1000)
            : "\(model.sizeMB) MB"
        return [Self.tradeOff[model.id], languages, size]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Automatic, then every language by name. A saved code Whisper does not
    /// know shows as Automatic, which is how it is treated.
    @ViewBuilder private var languagePicker: some View {
        let multilingual = selectedModel?.isMultilingual ?? false
        let code = store.current.language.code?.lowercased()
        let supported = selectedModel?.supportedLanguages ?? SpokenLanguage.whisperLanguages
        let selected = code.flatMap { supported.contains($0) ? $0 : nil }
        PillRow("Language") {
            PillMenu(title: selected.map { SpokenLanguage.displayName($0) } ?? "Automatic") {
                languageToggle("Automatic", nil, selected: selected)
                Divider()
                ForEach(Self.languages.filter { supported.contains($0.code) }, id: \.code) { language in
                    languageToggle(language.name, language.code, selected: selected)
                }
            }
            .disabled(!multilingual)
        }

        if !multilingual, let model = selectedModel {
            let only = SpokenLanguage.displayName(model.languages.first ?? "en")
            caption("\(model.displayName) hears \(only) only; choose a multilingual model to set a language.")
        } else if selectedModel?.engine == .parakeet {
            caption("Parakeet recognizes its supported languages automatically. Language is a script hint; the Whisper spoken-language filter and example prompts do not apply. Dictionary replacements still apply.")
        } else if store.current.language.code == nil {
            PillRow("Languages") {
                SpokenLanguagesButton(store: store)
            }
        }
    }

    private func languageToggle(_ name: String, _ code: String?, selected: String?) -> some View {
        Toggle(name, isOn: Binding(
            get: { selected == code },
            set: { on in if on { store.update { $0.language.code = code } } }
        ))
    }

    /// Opens the dictionary in the default plain-text editor, creating it
    /// from the template first if it is missing. The file has no extension,
    /// so `open(_:)` alone would not know what to open it with. If the old
    /// `dictionary.json` is still there, the conversion at launch failed; that
    /// file opens instead, so the problem can be fixed and nothing is left
    /// behind by a new template.
    private static func openDictionary() {
        let unconverted = Paths.fileType(Paths.dictionaryFile.path) == nil
            && Paths.fileType(Paths.legacyDictionaryFile.path) != nil
        let file = unconverted ? Paths.legacyDictionaryFile : Paths.dictionaryFile
        if !unconverted { DictionaryStore(file: file).createIfMissing() }
        let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.warning("couldn't open \(file.path): \(error.localizedDescription)") }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The languages Automatic chooses among, as a pill that opens checkboxes.
/// Starts from the Mac's preferred languages; the first edit saves the list
/// to settings.json.
private struct SpokenLanguagesButton: View {
    @ObservedObject var store: SettingsStore
    @State private var isOpen = false

    private var spoken: [String] {
        store.current.language.spokenOrPreferred.filter(SpokenLanguage.whisperLanguages.contains)
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            PillLabel(title: Onboarding.summary(spoken.map { SpokenLanguage.displayName($0) }), chevron: true)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SpokenLanguagesList(store: store)
        }
    }
}

/// The popover's content, observing the store so ticks show as they change.
private struct SpokenLanguagesList: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let spoken = store.current.language.spokenOrPreferred.filter(SpokenLanguage.whisperLanguages.contains)
        LanguageChecklist(ticked: spoken, toggle: { code in
            var next = spoken.filter { $0 != code }
            if !spoken.contains(code) { next.append(code) }
            // Keep at least one: an empty list trusts nothing.
            guard !next.isEmpty else { return }
            store.update { $0.language.spoken = next }
        }) {
            if store.current.language.spoken != nil {
                Divider().padding(.vertical, 2)
                Button("Use the Mac's Languages") { store.update { $0.language.spoken = nil } }
                    .buttonStyle(.link)
            }
        }
    }
}
