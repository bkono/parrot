import CoreML
import Foundation
import WhisperKit

package actor WhisperKitTranscriber: ManagedTranscriber {
    let modelID: String
    private let model: TranscriptionModel
    let tuning: WhisperTuning
    private var pipeline: WhisperKit?
    /// Set by `unload`: this transcriber was replaced and loads nothing more.
    private var retired = false
    private let localSettings: ModelSettings?

    package init(model: TranscriptionModel, tuning: WhisperTuning = .standard) {
        self.modelID = model.id
        self.model = model
        self.tuning = tuning
        self.localSettings = nil
    }

    init(model: TranscriptionModel, settings: ModelSettings) {
        self.modelID = model.id
        self.model = model
        self.tuning = .standard
        self.localSettings = settings
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load. `progress` gets the download's fraction done, 0 to 1,
    /// when there is anything to download.
    package func warmUp(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if pipeline != nil || retired { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        if let settings = localSettings {
            let selection = try MuesliModels.resolve(
                id: model.id, modelFolder: settings.modelFolder,
                tokenizerFolder: settings.tokenizerFolder
            )
            try MuesliModels.validate(selection)
            guard let tokenizerFolder = selection.tokenizerFolder else {
                throw LocalModelError.missingTokenizer
            }
            let local = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)
            let tokenizer = try LocalWhisperTokenizer(local)
            let loaded = try await WhisperKit(WhisperKitConfig(
                modelFolder: selection.modelFolder.path,
                computeOptions: ModelComputeOptions(
                    melCompute: tuning.melCompute,
                    audioEncoderCompute: tuning.encoderCompute,
                    textDecoderCompute: tuning.decoderCompute
                ),
                verbose: false, prewarm: false, load: false, download: false
            ))
            // download:false alone does not prevent tokenizer network fallback.
            // Supplying a locally parsed tokenizer bypasses that fallback.
            loaded.tokenizer = tokenizer
            do {
                try await loaded.loadModels()
                try Task.checkCancellation()
                loaded.textDecoder.isModelMultilingual = loaded.textDecoder.logitsSize != 51864
                if retired { await loaded.unloadModels(); return }
                pipeline = loaded
            } catch {
                await loaded.unloadModels()
                throw error
            }
            return
        }
        Log.info("loading \(model.id)...")
        // Explicit downloadBase: the HubApi default is ~/Documents/huggingface,
        // which the launchd daemon can't read and iCloud may evict. The
        // tokenizer folder follows downloadBase.
        let base = try Paths.prepareDirectory(Paths.appSupport)
        // The same download WhisperKit's init would run, called here to see
        // its progress. Files already on disk are not fetched again.
        let folder = try await WhisperKit.download(variant: whisperKitID, downloadBase: base) { p in
            progress?(p.fractionCompleted)
        }
        try Task.checkCancellation()
        let config = WhisperKitConfig(
            model: whisperKitID,
            downloadBase: base,
            modelFolder: folder.path,
            computeOptions: ModelComputeOptions(
                melCompute: tuning.melCompute,
                audioEncoderCompute: tuning.encoderCompute,
                textDecoderCompute: tuning.decoderCompute
            ),
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        let loaded = try await WhisperKit(config)
        // Replaced while loading (a model change during startup): drop it.
        if retired {
            await loaded.unloadModels()
            return
        }
        pipeline = loaded
        Log.info("✓ \(model.id) ready")
    }

    /// Frees the model after a swap to another one (#43). A load still running
    /// finishes and is dropped, and a later `warmUp` returns at once.
    package func unload() async {
        retired = true
        guard let pipeline else { return }
        self.pipeline = nil
        await pipeline.unloadModels()
    }

    /// Uses `context.language` and `context.prompt`, or with no language
    /// (Automatic) detects one and takes its sentence from `context.examples`;
    /// see `SpokenLanguage`. `context.vocabulary` is ignored: Whisper takes no
    /// word list, and a list given as a prompt scores no better than nothing
    /// (#23).
    package func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> Transcript {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let started = CFAbsoluteTimeGetCurrent()
        let input = tuning.prepare(audio)
        let trimTime = CFAbsoluteTimeGetCurrent() - started

        let detectStarted = CFAbsoluteTimeGetCurrent()
        let (language, prompt, detected) = await chooseLanguage(input, context: context, pipeline: pipeline)
        let detectTime = detected ? CFAbsoluteTimeGetCurrent() - detectStarted : 0

        let options = tuning.decodingOptions(
            language: language,
            promptTokens: Self.promptTokens(for: prompt, tokenizer: pipeline.tokenizer),
            audioSeconds: Double(input.count) / Double(WhisperKit.sampleRate)
        )
        let results = try await pipeline.transcribe(audioArray: input, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
        let text = Self.sanitize(raw)
        var timings = Self.timings(
            from: results.map(\.timings),
            audioSeconds: Double(input.count) / Double(WhisperKit.sampleRate),
            preprocessing: trimTime,
            languageDetection: detectTime,
            total: CFAbsoluteTimeGetCurrent() - started
        )
        timings.language = language ?? DictionaryContext.knownLanguage(of: model)
        return Transcript(text: text, timings: timings)
    }

    /// The language to decode `input` in, or nil for none; the prompt to go
    /// with it; and whether detection ran. Logs what detection heard and what
    /// was chosen, as codes, never text.
    private func chooseLanguage(
        _ input: [Float],
        context: TranscriptionContext,
        pipeline: WhisperKit
    ) async -> (language: String?, prompt: String?, detected: Bool) {
        let spoken = context.spokenLanguages.isEmpty ? SpokenLanguage.preferredCodes() : context.spokenLanguages
        switch SpokenLanguage.plan(setting: context.language, spoken: spoken, model: model) {
        case .none:
            return (nil, context.prompt, false)
        case .fixed(let code):
            // An explicit Language setting fills the prompt already; a single
            // spoken language comes here with it still unset.
            return (code, context.prompt ?? Self.example(in: context.examples, for: code), false)
        case .detect(let candidates):
            let among = candidates.isEmpty ? Array(model.supportedLanguages) : candidates
            let fallback = candidates.first
            guard !input.isEmpty else { return (fallback, Self.example(in: context.examples, for: fallback), false) }
            do {
                let ranked = try await LanguageDetector.detect(input, among: among, pipeline: pipeline)
                let chosen = ranked[0].code
                Log.info("language: \(chosen) (" + ranked.prefix(3).map {
                    String(format: "%@ %.2f", $0.code, $0.probability)
                }.joined(separator: " · ") + ")")
                return (chosen, Self.example(in: context.examples, for: chosen), true)
            } catch {
                Log.warning("language detection failed: \(error); using \(fallback ?? "the model's default")")
                return (fallback, Self.example(in: context.examples, for: fallback), true)
            }
        }
    }

    /// The example sentence in `examples` for `language`, matched as the
    /// dictionary matches it.
    static func example(in examples: [String: String], for language: String?) -> String? {
        examples.isEmpty ? nil : UserDictionary(examples: examples).example(for: language)
    }

    /// WhisperKit's per-stage timings folded into Parrot's stages. The decoder
    /// is what the pipeline spent outside preprocessing, the encoder and
    /// windowing; post-processing is the rest of the call. `ownPreprocessing` is
    /// time Parrot spent on the audio before handing it to WhisperKit.
    static func timings(
        from results: [TranscriptionTimings],
        audioSeconds: TimeInterval,
        preprocessing ownPreprocessing: TimeInterval,
        languageDetection: TimeInterval = 0,
        total: TimeInterval
    ) -> TranscriberTimings {
        var out = TranscriberTimings(
            audioSeconds: audioSeconds,
            preprocessing: ownPreprocessing,
            languageDetection: languageDetection,
            total: total
        )
        for t in results {
            let preprocessing = t.audioProcessing + t.logmels
            out.preprocessing += preprocessing
            out.encoder += t.encoding
            out.decoder += max(0, t.fullPipeline - preprocessing - t.encoding - t.decodingWindowing)
            out.windows += Int(t.totalEncodingRuns)
            out.tokens += Int(t.totalDecodingLoops)
            // WhisperKit records the index of the last failed attempt, so one
            // fallback reads 0; any fallback time means at least one happened.
            if t.decodingFallback > 0 { out.fallbacks += Int(t.totalDecodingFallbacks) + 1 }
        }
        out.postprocessing = max(0, total - out.preprocessing - out.languageDetection - out.encoder - out.decoder)
        return out
    }

    /// `prompt` as Whisper prompt tokens, or nil for none. Whisper reads them as
    /// the text spoken just before the audio. Special tokens are dropped: the
    /// decoder builds its own control sequence around the prompt, and a stray
    /// one there desynchronizes it.
    static func promptTokens(for prompt: String?, tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer,
              let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        // A leading space, as the text would appear mid-transcript.
        let tokens = tokenizer.encode(text: " " + text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - On-disk cache

extension WhisperKitTranscriber {
    /// True if `model`'s weights are already under `Paths.appSupport`.
    package static func isCached(_ model: TranscriptionModel) -> Bool {
        guard let variant = model.whisperKitID else { return false }
        let dir = Paths.appSupport.appendingPathComponent(folders(for: variant)[0])
        return FileManager.default.fileExists(atPath: dir.path)
    }

    /// True if any registry model is still in the pre-0.0.6 ~/Documents cache.
    /// Reads ~/Documents, so foreground commands only.
    static func hasLegacyModels() -> Bool {
        ModelRegistry.shared.contains { m in
            guard let variant = m.whisperKitID else { return false }
            return FileManager.default.fileExists(atPath: Paths.legacyModels.appendingPathComponent(folders(for: variant)[0]).path)
        }
    }

    /// Hub-relative folders WhisperKit writes for `variant`: the weights, their
    /// download metadata, and the tokenizer. The weights folder comes first.
    private static func folders(for variant: String) -> [String] {
        let repo = "models/argmaxinc/whisperkit-coreml"
        return [
            "\(repo)/\(variant)",
            "\(repo)/.cache/huggingface/download/\(variant)",
            "models/openai/\(tokenizerName(for: variant))",
        ]
    }

    /// Mirrors WhisperKit's tokenizer choice for the registry's variants:
    /// "openai_whisper-base.en" → "whisper-base.en"; every large-v3 build,
    /// including turbo, uses "whisper-large-v3".
    private static func tokenizerName(for variant: String) -> String {
        let name = variant.replacingOccurrences(of: "openai_", with: "")
        return name.hasPrefix("whisper-large-v3") ? "whisper-large-v3" : name
    }


}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
