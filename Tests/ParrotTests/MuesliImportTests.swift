import XCTest
@testable import ParrotCore

final class MuesliImportTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("parrot-muesli-test-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    private var muesli: [String: Any] {
        ["stt_backend": "fluidaudio", "stt_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
         "meeting_transcription_backend": "whisper", "meeting_transcription_model": "tiny.en",
         "ollama_model": "qwen3.5", "openai_api_key": "synthetic-secret"]
    }

    private func write(_ bytes: Data = Data([1]), to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    private func fill(_ selection: MuesliModels.Selection) throws {
        for file in selection.requiredFiles {
            let paths = file.hasSuffix(".mlmodelc")
                ? [file + "/coremldata.bin", file + "/weights/weight.bin"] : [file]
            for path in paths { try write(to: selection.modelFolder.appendingPathComponent(path)) }
        }
    }

    func testPreviewImportsDictationSelectionAndPreservesUnknownSettings() throws {
        let model = try MuesliModels.fromMuesli(muesli, home: home)
        try fill(model)
        let existing: [String: Any] = ["futureFeature": ["enabled": true], "model": ["custom": 7]]
        let result = try MuesliImport.proposal(muesli: muesli, existing: existing, home: home, replace: false)
        let imported = try XCTUnwrap(result["model"] as? [String: Any])
        XCTAssertEqual(imported["id"] as? String, "parakeet-v3")
        XCTAssertEqual(imported["modelFolder"] as? String, model.modelFolder.path)
        XCTAssertEqual(imported["custom"] as? Int, 7)
        XCTAssertEqual((result["futureFeature"] as? [String: Bool])?["enabled"], true)
        XCTAssertNil(result["openai_api_key"])
        XCTAssertNil(result["ollama_model"])
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".config").path))
        XCTAssertFalse(fm.fileExists(atPath: model.modelFolder.appendingPathComponent(".muesli-managed-model-complete.json").path))
    }

    func testExistingSelectionRequiresReplaceAndClearsObsoleteTokenizer() throws {
        try fill(MuesliModels.fromMuesli(muesli, home: home))
        let existing: [String: Any] = ["model": ["id": "whisper-small", "tokenizerFolder": "/old/tokenizer", "extra": true]]
        XCTAssertThrowsError(try MuesliImport.proposal(muesli: muesli, existing: existing, home: home, replace: false))
        let result = try MuesliImport.proposal(muesli: muesli, existing: existing, home: home, replace: true)
        let imported = try XCTUnwrap(result["model"] as? [String: Any])
        XCTAssertEqual(imported["id"] as? String, "parakeet-v3")
        XCTAssertNil(imported["tokenizerFolder"])
        XCTAssertEqual(imported["extra"] as? Bool, true)
    }

    func testIncompleteCachesAreRejectedWithoutRepair() throws {
        let model = try MuesliModels.fromMuesli(muesli, home: home)
        try fill(model)
        let state = model.modelFolder.appendingPathComponent(".muesli-download-state.json")
        try write(to: state)
        XCTAssertThrowsError(try MuesliModels.validate(model))
        XCTAssertTrue(fm.fileExists(atPath: state.path))
        try fm.removeItem(at: state)
        let weights = model.modelFolder.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")
        try write(Data(), to: weights)
        XCTAssertThrowsError(try MuesliModels.validate(model))
        XCTAssertEqual(try Data(contentsOf: weights), Data())
    }

    func testCompletionMarkerSizeMismatchAndTraversalAreRejected() throws {
        let model = try MuesliModels.fromMuesli(muesli, home: home)
        try fill(model)
        let marker = model.modelFolder.appendingPathComponent(".muesli-managed-model-complete.json")
        for entry: [String: Any] in [
            ["relativePath": "parakeet_vocab.json", "expectedByteCount": 99],
            ["relativePath": "../outside", "expectedByteCount": 1],
        ] {
            try write(JSONSerialization.data(withJSONObject: ["files": [entry]]), to: marker)
            XCTAssertThrowsError(try MuesliModels.validate(model))
        }
    }

    func testWhisperUsesSeparateCachedTokenizerAndDistinctCompressedModelID() throws {
        let source: [String: Any] = ["stt_backend": "whisper", "stt_model": "large-v3-v20240930_626MB"]
        let incomplete = try MuesliModels.fromMuesli(source, home: home)
        try fill(incomplete)
        XCTAssertEqual(incomplete.id, "whisper-large-v3-turbo-626mb")
        XCTAssertThrowsError(try MuesliModels.validate(incomplete))
        let tokenizer = home.appendingPathComponent("Documents/huggingface/models/openai/whisper-large-v3")
        for file in ["tokenizer.json", "tokenizer_config.json"] { try write(to: tokenizer.appendingPathComponent(file)) }
        let complete = try MuesliModels.fromMuesli(source, home: home)
        XCTAssertEqual(complete.tokenizerFolder?.path, tokenizer.path)
        XCTAssertNoThrow(try MuesliModels.validate(complete))
    }

    func testMalformedSettingsAndUnknownModelDoNotFallBack() throws {
        try fill(MuesliModels.fromMuesli(muesli, home: home))
        XCTAssertThrowsError(try MuesliImport.proposal(muesli: muesli, existing: ["model": 42], home: home, replace: true))
        XCTAssertThrowsError(try MuesliModels.fromMuesli(["stt_backend": "whisper", "stt_model": "../../unknown"], home: home))
        XCTAssertThrowsError(try MuesliModels.resolve(id: "parakeet-v3", modelFolder: "", tokenizerFolder: nil, home: home))
    }

    func testWriteBacksUpOriginalPreservesSymlinkAndRejectsChangedFile() throws {
        let real = home.appendingPathComponent("dotfiles/settings.json")
        let link = home.appendingPathComponent("settings.json")
        let original = Data("{\"future\":42}".utf8)
        try write(original, to: real)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let backup = try XCTUnwrap(MuesliImport.write(["future": 42, "model": ["id": "parakeet-v3"]],
                                                    to: link, expectedOriginal: original))
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(try MuesliImport.read(real)["future"] as? Int, 42)
        XCTAssertEqual((try fm.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let changed = try Data(contentsOf: real)
        XCTAssertThrowsError(try MuesliImport.write([:], to: link, expectedOriginal: original))
        XCTAssertEqual(try Data(contentsOf: real), changed)
    }

    func testDanglingSettingsSymlinkIsNotOverwritten() throws {
        let link = home.appendingPathComponent("settings.json")
        let missing = home.appendingPathComponent("missing.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: missing)
        XCTAssertThrowsError(try MuesliImport.write([:], to: link, expectedOriginal: nil))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), missing.path)
        XCTAssertFalse(fm.fileExists(atPath: missing.path))
    }
}
