import Foundation

struct MuesliImportError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Read-only discovery of the formats Muesli downloads. A model is selected
/// explicitly; incomplete or unsupported assets never trigger a fallback.
enum MuesliModels {
    struct Selection: Sendable {
        let id: String
        let modelFolder: URL
        let tokenizerFolder: URL?

        var configuration: [String: Any] {
            var result: [String: Any] = ["id": id, "modelFolder": modelFolder.path]
            if let tokenizerFolder { result["tokenizerFolder"] = tokenizerFolder.path }
            return result
        }

        var requiredFiles: [String] {
            if id == "parakeet-unified" {
                return ["parakeet_unified_encoder_int8.mlmodelc", "parakeet_unified_decoder.mlmodelc",
                        "parakeet_unified_joint_decision_single_step.mlmodelc", "vocab.json", "metadata.json"]
            }
            if id.hasPrefix("parakeet-") {
                return ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                        id == "parakeet-v2" ? "JointDecision.mlmodelc" : "JointDecisionv3.mlmodelc",
                        "parakeet_vocab.json"]
            }
            return ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
                    "config.json", "generation_config.json"]
        }
    }

    static let whisperVariants = ["tiny", "tiny.en", "small", "small.en", "medium.en", "large-v3-v20240930_626MB"]

    static func id(forWhisper variant: String) -> String {
        variant == "large-v3-v20240930_626MB" ? "whisper-large-v3-turbo-626mb" : "whisper-\(variant)"
    }

    static func cachedCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Selection] {
        let fluid = home.appendingPathComponent("Library/Application Support/FluidAudio/Models")
        var result = ["v2", "v3", "redux"].map { version in
            Selection(id: "parakeet-\(version)", modelFolder: fluid.appendingPathComponent(
                version == "redux" ? "parakeet-redux" : "parakeet-tdt-0.6b-\(version)"), tokenizerFolder: nil)
        }
        result.append(Selection(id: "parakeet-unified",
            modelFolder: fluid.appendingPathComponent("parakeet-unified-en-0.6b-coreml"), tokenizerFolder: nil))
        let whisper = home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        result += whisperVariants.map { variant in
            let folder = whisper.appendingPathComponent("openai_whisper-\(variant)")
            return Selection(id: id(forWhisper: variant), modelFolder: folder,
                             tokenizerFolder: findTokenizer(variant: variant, modelFolder: folder, home: home))
        }
        return result
    }

    static func resolve(id: String, modelFolder: String?, tokenizerFolder: String?,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Selection {
        guard let known = cachedCandidates(home: home).first(where: { $0.id == id }) else {
            throw MuesliImportError("Unsupported shared model: \(id). Run parrot models list for compatible models.")
        }
        func path(_ value: String) throws -> URL {
            let expanded = (value as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw MuesliImportError("Model and tokenizer folders must be absolute paths.") }
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let folder = try modelFolder.map(path) ?? known.modelFolder
        let tokenizer: URL?
        if id.hasPrefix("whisper-") {
            let variant = whisperVariants.first { self.id(forWhisper: $0) == id }!
            tokenizer = try tokenizerFolder.map(path) ?? findTokenizer(variant: variant, modelFolder: folder, home: home)
        } else {
            tokenizer = nil
        }
        return Selection(id: id, modelFolder: folder, tokenizerFolder: tokenizer)
    }

    static func fromMuesli(_ json: [String: Any], home: URL) throws -> Selection {
        guard let backend = json["stt_backend"] as? String,
              let model = json["stt_model"] as? String else {
            throw MuesliImportError("Muesli has no explicit dictation model selection. Select a dictation model in Muesli first.")
        }
        let id: String
        switch (backend, model) {
        case ("fluidaudio", "FluidInference/parakeet-tdt-0.6b-v2-coreml"): id = "parakeet-v2"
        case ("fluidaudio", "FluidInference/parakeet-tdt-0.6b-v3-coreml"): id = "parakeet-v3"
        case ("fluidaudio", "FluidInference/parakeet-redux-coreml"): id = "parakeet-redux"
        case ("parakeet-unified", "FluidInference/parakeet-unified-en-0.6b-coreml"): id = "parakeet-unified"
        case ("whisper", _) where whisperVariants.contains(model): id = self.id(forWhisper: model)
        default: throw MuesliImportError("Muesli dictation model \(backend)/\(model) is unsupported. No fallback was selected.")
        }
        return try resolve(id: id, modelFolder: nil, tokenizerFolder: nil, home: home)
    }

    static func validate(_ selection: Selection) throws {
        let folder = selection.modelFolder
        try requireMaterialized(folder)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".muesli-download-state.json").path) {
            throw MuesliImportError("Incomplete Muesli download at \(folder.path). Finish it in Muesli first.")
        }
        for file in selection.requiredFiles {
            let paths = file.hasSuffix(".mlmodelc")
                ? [file + "/coremldata.bin", file + "/weights/weight.bin"] : [file]
            for path in paths { try requireFile(folder.appendingPathComponent(path)) }
        }
        if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let url as URL in files {
                try requireMaterialized(url)
                if url.pathExtension == "part" {
                    throw MuesliImportError("Partial model download at \(url.path). Finish it in Muesli first.")
                }
            }
        }
        let marker = folder.appendingPathComponent(".muesli-managed-model-complete.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            struct Marker: Decodable {
                struct File: Decodable { let relativePath: String; let expectedByteCount: Int64? }
                let files: [File]
            }
            let manifest = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: marker))
            guard !manifest.files.isEmpty else { throw MuesliImportError("Empty model completion manifest.") }
            for entry in manifest.files {
                let url = folder.appendingPathComponent(entry.relativePath).standardizedFileURL
                guard url.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                    throw MuesliImportError("Invalid model completion manifest path.")
                }
                try requireFile(url)
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                if let expected = entry.expectedByteCount, size != expected {
                    throw MuesliImportError("Incomplete model file at \(url.path). Finish it in Muesli first.")
                }
            }
        }
        if selection.id.hasPrefix("whisper-") {
            guard let tokenizer = selection.tokenizerFolder else {
                throw MuesliImportError("Cached tokenizer missing for \(selection.id). Load this model once in Muesli first.")
            }
            for file in ["tokenizer.json", "tokenizer_config.json"] {
                try requireFile(tokenizer.appendingPathComponent(file))
            }
        }
    }

    private static func findTokenizer(variant: String, modelFolder: URL, home: URL) -> URL? {
        let family = variant.hasPrefix("large-v3") ? "large-v3" : variant
        let relative = "models/openai/whisper-\(family)"
        return [home.appendingPathComponent("Documents/huggingface/\(relative)"),
                modelFolder, modelFolder.appendingPathComponent(relative)].first { folder in
            ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
                (try? requireFile(folder.appendingPathComponent($0))) != nil
            }
        }
    }

    private static func requireFile(_ url: URL) throws {
        try requireMaterialized(url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value ?? 0 > 0,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw MuesliImportError("Missing, empty, or unreadable model file: \(url.path).")
        }
    }

    /// Stat flags do not materialize iCloud placeholders or fetch model bytes.
    private static func requireMaterialized(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw MuesliImportError("Missing model file: \(url.path).")
        }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw MuesliImportError("Model file is evicted by iCloud: \(url.path). Download it in Finder before using Parrot.")
        }
    }
}
