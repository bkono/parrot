import AppKit
import SwiftUI

struct MuesliImportSection: View {
    @ObservedObject var offer: MuesliOffer

    var body: some View {
        SettingsGroup("Reuse an existing setup") {
            if offer.isInspecting {
                HStack { ProgressView().controlSize(.small); Text("Checking local models…") }
            } else if offer.status == .offered, let selection = offer.selection {
                Text("Use the dictation model selected in Muesli?").font(.headline)
                Text("Parrot will save its own settings and read the existing shared model files. No model download or changes to Muesli are needed.")
                Text(selection.id).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text(selection.modelFolder.path).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let tokenizer = selection.tokenizerFolder {
                    Text("Tokenizer: \(tokenizer.path)").font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let current = offer.replacingModelID {
                    Text("Replaces your selected model, \(current). Existing Parrot settings will be backed up.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Use This Model") { Task { await offer.accept() } }.buttonStyle(.borderedProminent)
                    Button("Keep My Selection") { offer.reject() }.buttonStyle(.pill)
                }
                Button("Not Now") { offer.dismiss() }.buttonStyle(.plain).foregroundStyle(.tint)
            } else {
                if let error = offer.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                } else if offer.status == .accepted {
                    Text("Import saved in Parrot's own configuration.").font(.callout)
                } else if offer.status == .rejected || offer.status == .dismissed {
                    Text("Your choice is saved. Parrot won't ask again automatically.").font(.callout)
                }
                HStack {
                    Button("Review Muesli Setup…") { Task { await offer.retry() } }.buttonStyle(.pill)
                    Button("Choose Muesli Config…") { chooseSource() }.buttonStyle(.pill)
                }
                if let backup = offer.backupURL {
                    Button("Reveal Settings Backup") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                }
            }
            Text("Source: \(offer.sourceURL.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose Muesli's config.json. Parrot only reads this file."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await offer.retry(sourceURL: url) }
        }
    }
}

struct ModelSourceSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var runtime: ModelLoadStatus
    @State private var selected: ModelProvenance?
    @State private var active: ModelProvenance?
    @State private var cachedModels: [MuesliModels.Selection] = []
    @State private var scanning = false
    @State private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration: Parrot's own settings").font(.subheadline.weight(.semibold))
            Text(store.file.path).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let active {
                ModelSourceDetails(source: active, title: "In use")
            } else {
                Text("No model loaded yet.").foregroundStyle(.secondary)
            }
            if let selected, selected.modelID != active?.modelID || selected.modelFolder != active?.modelFolder
                || selected.tokenizerFolder != active?.tokenizerFolder || selected.importedFromMuesli != active?.importedFromMuesli {
                ModelSourceDetails(source: selected, title: "Selected")
            }
            HStack {
                Button("Retry Selected Model") { runtime.requestLoad?(false) }.buttonStyle(.pill)
                if selected?.storage == .parrotManaged, selected?.problem != nil,
                   store.current.model.modelFolder == nil,
                   let model = store.current.model.id.flatMap(ModelRegistry.find) ?? ModelRegistry.recommended(), model.engine == .whisperKit {
                    Button("Download (\(model.sizeMB) MB)") { runtime.requestLoad?(true) }.buttonStyle(.pill)
                }
            }
            Button(scanning ? "Finding cached models…" : "Choose Another Cached Model…") {
                scanning = true
                Task {
                    cachedModels = await Task.detached {
                        MuesliModels.cachedCandidates().filter { (try? MuesliModels.validate($0)) != nil }
                    }.value
                    scanning = false
                    searched = true
                }
            }.buttonStyle(.plain).foregroundStyle(.tint).disabled(scanning)
            if searched && cachedModels.isEmpty && !scanning {
                Text("No complete compatible shared models found. Restore a cached model, or choose a Parrot model and download it explicitly.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(cachedModels, id: \.id) { candidate in
                Button(candidate.id) {
                    store.update {
                        var next = ModelSettings()
                        next.id = candidate.id
                        next.modelFolder = candidate.modelFolder.path
                        next.tokenizerFolder = candidate.tokenizerFolder?.path
                        $0.model = next
                    }
                }.buttonStyle(.pill)
            }
        }
        .task(id: store.current.model) { await refresh() }
        .task(id: runtime.activeSettings) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        let selection = store.current.model
        let running = runtime.activeSettings
        let result = await Task.detached {
            (ModelProvenance.inspect(selection), running.map { ModelProvenance.inspect($0) })
        }.value
        guard !Task.isCancelled, store.current.model == selection, runtime.activeSettings == running else { return }
        selected = result.0
        active = result.1
    }
}

struct ModelSourceDetails: View {
    let source: ModelProvenance
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title): \(source.modelID)").font(.subheadline.weight(.semibold))
            Text(source.backend).font(.caption).foregroundStyle(.secondary)
            if source.importedFromMuesli {
                Text("Selection imported from Muesli; preferences now belong to Parrot.").font(.caption)
            }
            Text(source.storage == .externalShared ? "Shared external model cache" : "Parrot-managed model cache")
                .font(.caption.weight(.semibold))
            if let folder = source.modelFolder { path(folder, label: "Model") }
            if let tokenizer = source.tokenizerFolder { path(tokenizer, label: "Tokenizer") }
            if let problem = source.problem {
                Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Text("Restore the missing assets or choose another cached model. An already loaded model may keep working until it is released.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if source.storage == .externalShared {
                Text("Removing Muesli.app alone leaves shared caches in place. Deleting those cache files, including with a cleanup tool, makes this selection unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func path(_ url: URL, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(url.path)").font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Button("Reveal \(label) Folder") {
                let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }.buttonStyle(.plain).foregroundStyle(.tint)
        }
    }

}
