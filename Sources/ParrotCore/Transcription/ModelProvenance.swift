import Foundation

/// Ownership and health are derived from the selected paths, not the name of
/// the app that first downloaded a model. Hugging Face/FluidAudio caches are shared.
struct ModelProvenance: Sendable {
    enum Storage: Sendable, Equatable { case parrotManaged, externalShared }
    let modelID: String
    let backend: String
    let importedFromMuesli: Bool
    let storage: Storage
    let modelFolder: URL?
    let tokenizerFolder: URL?
    let problem: String?

    static func inspect(_ settings: ModelSettings,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let id = settings.id ?? ModelRegistry.recommended()?.id ?? ""
        guard let model = ModelRegistry.find(id) else {
            return Self(modelID: id, backend: "Unknown", importedFromMuesli: settings.importedFrom == "muesli",
                        storage: .externalShared, modelFolder: settings.modelFolder.map { URL(fileURLWithPath: $0) },
                        tokenizerFolder: nil, problem: "This model is not supported. Choose a compatible cached model.")
        }
        var storage: Storage = model.engine == .parakeet || settings.modelFolder != nil ? .externalShared : .parrotManaged
        var selection: MuesliModels.Selection?
        var problem: String?
        do {
            if storage == .externalShared {
                selection = try MuesliModels.resolve(id: id, modelFolder: settings.modelFolder,
                                                     tokenizerFolder: settings.tokenizerFolder, home: home)
            } else if let variant = model.whisperKitID {
                let family = variant.hasPrefix("openai_whisper-large-v3") ? "whisper-large-v3" : variant.replacingOccurrences(of: "openai_", with: "")
                let root = home.appendingPathComponent("Library/Application Support/parrot")
                selection = MuesliModels.Selection(id: id,
                    modelFolder: root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)"),
                    tokenizerFolder: root.appendingPathComponent("models/openai/\(family)"))
            }
            if let selection { try MuesliModels.validate(selection) }
        } catch { problem = error.localizedDescription }
        let canonicalFolder = selection?.modelFolder.resolvingSymlinksInPath()
        if let canonicalFolder {
            let ownedRoot = home.resolvingSymlinksInPath().appendingPathComponent("Library/Application Support/parrot").path
            storage = canonicalFolder.path.hasPrefix(ownedRoot + "/") ? .parrotManaged : .externalShared
        }
        return Self(modelID: id, backend: model.engine == .parakeet ? "FluidAudio / Parakeet" : "WhisperKit",
                    importedFromMuesli: settings.importedFrom == "muesli", storage: storage,
                    modelFolder: canonicalFolder, tokenizerFolder: selection?.tokenizerFolder?.resolvingSymlinksInPath(),
                    problem: problem)
    }
}
