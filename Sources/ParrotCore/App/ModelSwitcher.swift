import Foundation

/// Applies a model change while Parrot runs (#43): loads the new model behind
/// the menu bar, downloading it first if needed, while the current one keeps
/// serving presses, then swaps it into the `DictationController` between
/// dictations.
///
/// A second change while a load runs supersedes it: the first load's result
/// is dropped. A failed load logs, shows a short status, and keeps the current
/// model; the setting stays as chosen, so the next change or the next launch
/// tries again.
@MainActor
final class ModelSwitcher {
    /// The model the controller transcribes with.
    private(set) var model: TranscriptionModel
    private var transcriber: any ManagedTranscriber
    private var settings: ModelSettings
    /// Set by the daemon once the controller exists.
    weak var controller: DictationController?

    private let menuBar: MenuBarController
    private let status: ModelLoadStatus
    private var load: Task<Void, Never>?
    /// Bumped on every change, so a superseded load cannot swap or report.
    private var generation = 0

    init(model: TranscriptionModel, transcriber: any ManagedTranscriber, menuBar: MenuBarController, settings: ModelSettings = ModelSettings(), status: ModelLoadStatus? = nil) {
        self.model = model
        self.settings = settings
        self.transcriber = transcriber
        self.menuBar = menuBar
        self.status = status ?? .shared
    }

    /// Loads and swaps in `id`, a `ModelRegistry` id or nil for the
    /// recommended model.
    func select(_ settings: ModelSettings) {
        let id = settings.id
        guard let next = Daemon.knownModel(id).flatMap(ModelRegistry.find) ?? ModelRegistry.recommended() else { return }
        generation += 1
        load?.cancel()
        load = nil
        guard next.id != model.id || settings != self.settings else {
            // Back to the model already in use: nothing to load.
            status.show(nil)
            menuBar.setModel(model.id)
            return
        }

        let generation = self.generation
        let incoming = TranscriberFactory.make(model: next, settings: settings)
        report((next.engine == .parakeet || settings.modelFolder != nil || TranscriberFactory.isCached(next)) ? .loading : .downloading(nil), next, generation)
        Log.info("model: loading \(next.id) behind \(model.id)")

        // The switcher lives as long as the daemon, so the task holds it
        // strongly. It runs on the main actor except inside the awaits.
        load = Task {
            do {
                try await incoming.warmUp { fraction in
                    Task { @MainActor in
                        self.report(fraction < 1 ? .downloading(fraction) : .loading, next, generation)
                    }
                }
                report(.loading, next, generation)
                // Swap between dictations: never under one that is recording
                // or transcribing.
                while (controller?.state ?? .idle) != .idle {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                guard self.generation == generation else {
                    await incoming.unload()
                    return
                }
                swap(to: next, incoming, settings: settings)
            } catch {
                await incoming.unload()
                guard self.generation == generation, !Task.isCancelled else { return }
                Log.error("couldn't load \(next.id): \(error); keeping \(model.id)")
                report(.failed, next, generation)
            }
        }
    }

    private func swap(to next: TranscriptionModel, _ incoming: any ManagedTranscriber, settings: ModelSettings) {
        let outgoing = transcriber
        controller?.replaceTranscriber(incoming)
        transcriber = incoming
        model = next
        self.settings = settings
        generation += 1
        load = nil
        status.show(nil)
        menuBar.setModel(next.id)
        Log.info("model: \(next.id)")
        // Free the old model's memory. Nothing is transcribing with it: the
        // swap waited for the controller to go idle.
        Task { await outgoing.unload() }
    }

    private func report(_ phase: ModelLoadStatus.Phase, _ next: TranscriptionModel, _ generation: Int) {
        // A progress callback can land after the swap it belonged to.
        guard generation == self.generation else { return }
        // Downloading → loading only moves forward; a late progress callback
        // must not put "downloading" back.
        if case .downloading = phase, status.current?.modelID == next.id, status.current?.phase == .loading { return }
        let state = ModelLoadStatus.State(modelID: next.id, phase: phase)
        guard state != status.current else { return }
        status.show(state)
        menuBar.setModel("\(model.id) · \(state.text)")
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
            }
        }
    }

    /// Nil when no load is running or has just failed.
    @Published private(set) var current: State?

    func show(_ state: State?) {
        // Whole percents only: the menu and the window need no finer steps.
        if let state, let current, state.text == current.text { return }
        current = state
    }
}
