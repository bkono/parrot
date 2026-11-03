import Foundation

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained — no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
package enum ModelRegistry {
    static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "whisper-base.en",
            displayName: "Whisper Base (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base.en",
            sizeMB: 145,
            languages: ["en"],
            recommended: true
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
            sizeMB: 1620,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small.en",
            sizeMB: 488,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small",
            displayName: "Whisper Small",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small",
            sizeMB: 490,
            languages: ["multi"],
            recommended: false
        ),
    ] + reusableModels

    /// Distinct IDs keep Muesli's compressed turbo separate from our original
    /// 1.6 GB variant. Parakeet entries always load existing assets in place.
    private static let reusableModels: [TranscriptionModel] = [
        TranscriptionModel(id: "parakeet-v2", displayName: "Parakeet v2", engine: .parakeet, whisperKitID: nil, sizeMB: 450, languages: ["en"], recommended: false),
        TranscriptionModel(id: "parakeet-v3", displayName: "Parakeet v3", engine: .parakeet, whisperKitID: nil, sizeMB: 450, languages: parakeetLanguages, recommended: false),
        TranscriptionModel(id: "parakeet-redux", displayName: "Parakeet Redux", engine: .parakeet, whisperKitID: nil, sizeMB: 220, languages: parakeetLanguages, recommended: false),
        TranscriptionModel(id: "parakeet-unified", displayName: "Parakeet Unified", engine: .parakeet, whisperKitID: nil, sizeMB: 565, languages: ["en"], recommended: false),
        TranscriptionModel(id: "whisper-tiny", displayName: "Whisper Tiny", engine: .whisperKit, whisperKitID: "openai_whisper-tiny", sizeMB: 153, languages: ["multi"], recommended: false),
        TranscriptionModel(id: "whisper-tiny.en", displayName: "Whisper Tiny (English)", engine: .whisperKit, whisperKitID: "openai_whisper-tiny.en", sizeMB: 153, languages: ["en"], recommended: false),
        TranscriptionModel(id: "whisper-medium.en", displayName: "Whisper Medium (English)", engine: .whisperKit, whisperKitID: "openai_whisper-medium.en", sizeMB: 1500, languages: ["en"], recommended: false),
        TranscriptionModel(id: "whisper-large-v3-turbo-626mb", displayName: "Whisper Large v3 Turbo (626 MB)", engine: .whisperKit, whisperKitID: "openai_whisper-large-v3-v20240930_626MB", sizeMB: 626, languages: ["multi"], recommended: false),
    ]

    private static let parakeetLanguages = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"]

    package static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    package static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }
}
