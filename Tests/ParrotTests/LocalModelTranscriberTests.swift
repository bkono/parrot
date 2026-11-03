import Foundation
import XCTest
@testable import ParrotCore

final class LocalModelTranscriberTests: XCTestCase {
    func testOnboardingPreservesAnExplicitImportedModel() {
        var settings = Settings()
        settings.model.id = "parakeet-unified"
        settings.model.modelFolder = "/fixture/unified"
        let next = Onboarding.apply(hotkey: .fn, languages: ["en", "es"], preferred: ["en", "es"], to: settings)
        XCTAssertEqual(next.model, settings.model)
        XCTAssertTrue(next.onboarding.completed)
    }

    func testModelOverrideKeepsOnlyMatchingPaths() {
        var settings = ModelSettings()
        settings.id = "whisper-small"
        settings.modelFolder = "/fixture/small"
        settings.tokenizerFolder = "/fixture/tokenizer"
        XCTAssertEqual(settings.selecting("whisper-small"), settings)
        let changed = settings.selecting("parakeet-unified")
        XCTAssertEqual(changed.id, "parakeet-unified")
        XCTAssertNil(changed.modelFolder)
        XCTAssertNil(changed.tokenizerFolder)
    }

    func testMissingImportedModelsFailWithoutCreatingCacheOrFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["parakeet-v2", "parakeet-v3", "parakeet-redux", "parakeet-unified", "whisper-small"] {
            var settings = ModelSettings()
            settings.id = id
            settings.modelFolder = root.appendingPathComponent(id).path
            settings.tokenizerFolder = root.appendingPathComponent("tokenizer").path
            let model = try XCTUnwrap(ModelRegistry.find(id))
            let transcriber = TranscriberFactory.make(model: model, settings: settings)
            XCTAssertFalse(TranscriberFactory.isCached(model, settings: settings))
            do {
                try await transcriber.warmUp()
                XCTFail("missing explicit assets must fail")
            } catch {
                XCTAssertTrue(error is MuesliImportError)
            }
            await transcriber.unload()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRetiredTranscribersDoNotReload() async throws {
        for id in ["parakeet-unified", "whisper-small"] {
            var settings = ModelSettings()
            settings.id = id
            settings.modelFolder = "/nonexistent/retired-model"
            let transcriber = TranscriberFactory.make(model: try XCTUnwrap(ModelRegistry.find(id)), settings: settings)
            await transcriber.unload()
            try await transcriber.warmUp()
        }
    }

    func testWhisperSpecialTokenContractForEnglishMultilingualAndV3() throws {
        for (english, v3) in [(false, false), (true, false), (false, true)] {
            let shift = english ? -1 : 0
            let v3Shift = v3 ? 1 : 0
            let noSpeechKey = v3 ? "<|nospeech|>" : "<|nocaptions|>"
            let vocab = [
                "<|endoftext|>": 50257 + shift,
                "<|en|>": 50259 + shift,
                "<|startoftranscript|>": 50258 + shift,
                "<|translate|>": 50358 + shift + v3Shift,
                "<|transcribe|>": 50359 + shift + v3Shift,
                "<|startofprev|>": 50361 + shift + v3Shift,
                noSpeechKey: 50362 + shift + v3Shift,
                "<|notimestamps|>": 50363 + shift + v3Shift,
                "<|0.00|>": 50364 + shift + v3Shift,
                "Ġ": 220,
            ]
            let tokens = try LocalWhisperTokenizer.makeSpecialTokens { vocab[$0] }
            XCTAssertEqual(tokens.noSpeechToken, vocab[noSpeechKey])
            XCTAssertEqual(tokens.endToken, vocab["<|endoftext|>"])
            XCTAssertEqual(tokens.timeTokenBegin, vocab["<|0.00|>"])
            XCTAssertEqual(tokens.whitespaceToken, 220)
            var incomplete = vocab
            incomplete.removeValue(forKey: noSpeechKey)
            XCTAssertThrowsError(try LocalWhisperTokenizer.makeSpecialTokens { incomplete[$0] })
        }
    }
}
