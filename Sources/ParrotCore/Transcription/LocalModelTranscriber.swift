import FluidAudio
import Foundation

enum LocalModelError: Error, LocalizedError {
    case missingTokenizer
    case invalidTokenizer(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .missingTokenizer: return "The selected local Whisper model needs its cached tokenizer. Load it once in Muesli, then import again."
        case .invalidTokenizer(let token): return "The cached tokenizer is missing required token \(token)."
        case .unsupported(let id): return "Unsupported local model: \(id)."
        }
    }
}

enum TranscriberFactory {
    static func make(model: TranscriptionModel, settings: ModelSettings) -> any ManagedTranscriber {
        if model.engine == .parakeet { return ParakeetTranscriber(model: model, settings: settings) }
        if settings.modelFolder != nil { return WhisperKitTranscriber(model: model, settings: settings) }
        return WhisperKitTranscriber(model: model)
    }

    static func isCached(_ model: TranscriptionModel, settings: ModelSettings = ModelSettings()) -> Bool {
        if model.engine == .parakeet || settings.modelFolder != nil {
            guard let selection = try? MuesliModels.resolve(id: model.id, modelFolder: settings.modelFolder, tokenizerFolder: settings.tokenizerFolder) else { return false }
            return (try? MuesliModels.validate(selection)) != nil
        }
        return WhisperKitTranscriber.isCached(model)
    }
}

/// Batch transcription after the existing hotkey release. The model does not
/// control capture duration, silence detection, or delivery.
actor ParakeetTranscriber: ManagedTranscriber {
    nonisolated let modelID: String
    private let settings: ModelSettings
    private var tdt: AsrManager?
    private var unified: UnifiedAsrManager?
    private var retired = false

    init(model: TranscriptionModel, settings: ModelSettings) {
        modelID = model.id
        self.settings = settings
    }

    func warmUp(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard tdt == nil, unified == nil, !retired else { return }
        let selection = try MuesliModels.resolve(id: modelID, modelFolder: settings.modelFolder, tokenizerFolder: nil)
        try MuesliModels.validate(selection)
        try Task.checkCancellation()
        if modelID == "parakeet-unified" {
            let manager = UnifiedAsrManager()
            try await manager.loadModels(from: selection.modelFolder)
            if retired || Task.isCancelled { await manager.cleanup(); try Task.checkCancellation(); return }
            unified = manager
        } else {
            let version: AsrModelVersion
            switch modelID {
            case "parakeet-v2": version = .v2
            case "parakeet-v3": version = .v3
            case "parakeet-redux": version = .redux
            default: throw LocalModelError.unsupported(modelID)
            }
            let models = try AsrModels.loadLocal(
                from: selection.modelFolder, version: version,
                encoderComputeUnits: modelID == "parakeet-redux" ? .cpuOnly : nil
            )
            let manager = AsrManager()
            try await manager.loadModels(models)
            if retired || Task.isCancelled { await manager.cleanup(); try Task.checkCancellation(); return }
            tdt = manager
        }
    }

    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> Transcript {
        guard !audio.isEmpty else { return Transcript(text: "") }
        if tdt == nil, unified == nil { try await warmUp() }
        try Task.checkCancellation()
        let started = Date()
        let text: String
        if let unified {
            text = try await unified.transcribe(audio)
        } else if let tdt {
            var state = TdtDecoderState.make(decoderLayers: await tdt.decoderLayerCount)
            text = try await tdt.transcribe(audio, decoderState: &state, language: context.language.flatMap(Language.init(rawValue:))).text
        } else {
            throw TranscriberError.notLoaded
        }
        try Task.checkCancellation()
        let elapsed = Date().timeIntervalSince(started)
        return Transcript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), timings: TranscriberTimings(
            audioSeconds: Double(audio.count) / 16_000, decoder: elapsed, total: elapsed,
            language: modelID == "parakeet-v2" || modelID == "parakeet-unified" ? "en" : nil
        ))
    }

    func unload() async {
        retired = true
        if let tdt { await tdt.cleanup() }
        if let unified { await unified.cleanup() }
        tdt = nil
        unified = nil
    }
}
