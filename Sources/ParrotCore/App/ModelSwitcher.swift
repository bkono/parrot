import Foundation

/// Owns startup and subsequent model loads. A newer selection cancels the old
/// attempt; only a successful load may change the active model, between dictations.
@MainActor
final class ModelSwitcher {
    private(set) var model: TranscriptionModel
    private var transcriber: any ManagedTranscriber
    private var settings: ModelSettings
    weak var controller: DictationController?
    var onReady: (() -> Void)?
    private(set) var ready = false

    private let menuBar: MenuBarController?
    private let status: ModelLoadStatus
    private let make: (TranscriptionModel, ModelSettings, Bool) -> any ManagedTranscriber
    private let cached: (TranscriptionModel, ModelSettings) -> Bool
    private let idle: (() -> Bool)?
    private var load: Task<Void, Never>?
    private var generation = 0
    private var pendingSettings: ModelSettings?

    init(model: TranscriptionModel, transcriber: any ManagedTranscriber,
         menuBar: MenuBarController? = nil, settings: ModelSettings = ModelSettings(),
         status: ModelLoadStatus? = nil,
         make: @escaping (TranscriptionModel, ModelSettings, Bool) -> any ManagedTranscriber = TranscriberFactory.make,
         cached: @escaping (TranscriptionModel, ModelSettings) -> Bool = TranscriberFactory.isCached,
         idle: (() -> Bool)? = nil) {
        self.model = model
        self.settings = settings
        self.transcriber = transcriber
        self.menuBar = menuBar
        self.status = status ?? .shared
        self.make = make
        self.cached = cached
        self.idle = idle
    }

    /// Existing assets may load automatically. Downloading requires a separate
    /// explicit UI action; selecting a missing imported cache never downloads.
    func select(_ settings: ModelSettings, allowDownload: Bool = false, force: Bool = false) {
        var settings = settings
        if settings.id == nil { settings.id = ModelRegistry.recommended()?.id }
        if !force, pendingSettings == settings { return }
        generation += 1
        load?.cancel()
        load = nil
        pendingSettings = nil
        guard let next = settings.id.flatMap(ModelRegistry.find) ?? (settings.id == nil ? ModelRegistry.recommended() : nil) else {
            status.show(.init(modelID: settings.id ?? "", phase: .failed))
            if !ready { menuBar?.setHotkeyHealth(.modelFailed) }
            return
        }
        settings.id = next.id
        if ready && next.id == model.id && settings == self.settings && !force {
            status.show(nil)
            menuBar?.setModel(model.id)
            return
        }
        let isCached = cached(next, settings)
        let external = next.engine == .parakeet || settings.modelFolder != nil
        guard isCached || (allowDownload && !external) else {
            report(external ? .failed : .needsDownload, next, generation)
            return
        }
        let generation = self.generation
        let incoming = make(next, settings, allowDownload && !isCached)
        report(isCached ? .loading : .downloading(nil), next, generation)
        pendingSettings = settings
        load = Task {
            do {
                try Task.checkCancellation()
                try await incoming.warmUp { fraction in
                    Task { @MainActor in
                        self.report(fraction < 1 ? .downloading(fraction) : .loading, next, generation)
                    }
                }
                report(.loading, next, generation)
                while !(idle?() ?? ((controller?.state ?? .idle) == .idle)) {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                guard self.generation == generation else { await incoming.unload(); return }
                let outgoing = transcriber
                controller?.replaceTranscriber(incoming)
                transcriber = incoming
                model = next
                self.settings = settings
                ready = true
                self.generation += 1
                load = nil
                pendingSettings = nil
                status.setActive(settings)
                status.show(nil)
                menuBar?.setModel(next.id)
                Task { await outgoing.unload() }
                onReady?()
            } catch {
                await incoming.unload()
                guard self.generation == generation, !Task.isCancelled else { return }
                load = nil
                pendingSettings = nil
                Log.error("couldn't load \(next.id): \(error)")
                report(.failed, next, generation)
            }
        }
    }

    private func report(_ phase: ModelLoadStatus.Phase, _ next: TranscriptionModel, _ generation: Int) {
        guard generation == self.generation else { return }
        if case .downloading = phase, status.current?.modelID == next.id, status.current?.phase == .loading { return }
        status.show(.init(modelID: next.id, phase: phase))
        if !ready {
            menuBar?.setHotkeyHealth(phase == .failed || phase == .needsDownload ? .modelFailed : .modelLoading)
        }
        menuBar?.setModel(ready ? "\(model.id) · \(status.current?.text ?? "")" : (status.current?.text ?? next.id))
    }
}

/// A model loading behind the one in use, for the Settings window and the
/// menu. One daemon, one status: `shared` is the only instance the app uses.
@MainActor
final class ModelLoadStatus: ObservableObject {
    static let shared = ModelLoadStatus()

    enum Phase: Equatable {
        /// Fraction done, 0 to 1, once the download reports one.
        case downloading(Double?)
        case loading
        case failed
        case needsDownload
    }

    struct State: Equatable {
        var modelID: String
        var phase: Phase

        /// For example "downloading whisper-large-v3-turbo… 42%".
        var text: String {
            switch phase {
            case .downloading(let fraction?):
                return "downloading \(modelID)… \(Int((fraction * 100).rounded(.down)))%"
            case .downloading(nil):
                return "downloading \(modelID)…"
            case .loading:
                return "loading \(modelID)…"
            case .failed:
                return "couldn't load \(modelID)"
            case .needsDownload:
                return "choose or download \(modelID)"
            }
        }
    }

    /// Nil when no load is running or has just failed.
    @Published private(set) var current: State?
    @Published private(set) var activeSettings: ModelSettings?
    /// true permits an explicit download of a Parrot-managed Whisper model.
    var requestLoad: ((Bool) -> Void)?

    func setActive(_ settings: ModelSettings) { activeSettings = settings }

    func show(_ state: State?) {
        // Whole percents only: the menu and the window need no finer steps.
        if let state, let current, state.text == current.text { return }
        current = state
    }
}
