import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import ParrotCore

private actor FixtureTranscriber: ManagedTranscriber {
    nonisolated let modelID: String
    let delay: UInt64
    let fails: Bool
    private(set) var loads = 0
    private(set) var releases = 0
    init(_ id: String, delay: UInt64 = 0, fails: Bool = false) {
        modelID = id; self.delay = delay; self.fails = fails
    }
    func warmUp(progress: (@Sendable (Double) -> Void)?) async throws {
        loads += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fails { throw TranscriberError.notLoaded }
    }
    func unload() async { releases += 1 }
    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> Transcript { Transcript(text: "fixture") }
}

@MainActor
final class AppFirstModelTests: XCTestCase {
    private func selection(_ id: String) -> ModelSettings { ModelSettings().selecting(id) }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("state transition did not complete")
    }

    func testInitialMissingModelWaitsForExplicitDownload() async throws {
        let model = try XCTUnwrap(ModelRegistry.find("whisper-small"))
        let fake = FixtureTranscriber(model.id)
        let status = ModelLoadStatus()
        var permissions: [Bool] = []
        let switcher = ModelSwitcher(model: model, transcriber: fake, status: status,
            make: { _, _, allowed in permissions.append(allowed); return fake }, cached: { _, _ in false })
        switcher.select(selection(model.id))
        XCTAssertEqual(status.current?.phase, .needsDownload)
        XCTAssertTrue(permissions.isEmpty)
        XCTAssertNil(status.activeSettings)
        switcher.select(selection(model.id), allowDownload: true)
        try await eventually { switcher.ready }
        XCTAssertEqual(permissions, [true])
        XCTAssertEqual(status.activeSettings?.id, model.id)
    }

    func testFailedReplacementRetainsActualActiveProvenance() async throws {
        let first = try XCTUnwrap(ModelRegistry.find("parakeet-v3"))
        let good = FixtureTranscriber(first.id)
        let bad = FixtureTranscriber("parakeet-unified", fails: true)
        let status = ModelLoadStatus()
        let switcher = ModelSwitcher(model: first, transcriber: FixtureTranscriber("unloaded"), status: status,
            make: { model, _, allowed in XCTAssertFalse(allowed); return model.id == first.id ? good : bad },
            cached: { _, _ in true })
        switcher.select(selection(first.id))
        try await eventually { switcher.ready }
        switcher.select(selection(bad.modelID))
        try await eventually { status.current?.phase == .failed }
        XCTAssertEqual(status.activeSettings?.id, first.id)
        XCTAssertEqual(switcher.model.id, first.id)
    }

    func testSupersededStartupCannotBecomeActiveAndSwapWaitsForIdle() async throws {
        let first = try XCTUnwrap(ModelRegistry.find("parakeet-v3"))
        let slow = FixtureTranscriber(first.id, delay: 100_000_000)
        let next = FixtureTranscriber("parakeet-unified")
        var idle = false
        let status = ModelLoadStatus()
        let switcher = ModelSwitcher(model: first, transcriber: FixtureTranscriber("unloaded"), status: status,
            make: { model, _, _ in model.id == first.id ? slow : next }, cached: { _, _ in true }, idle: { idle })
        switcher.select(selection(first.id))
        await Task.yield()
        switcher.select(selection(next.modelID))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(status.activeSettings)
        idle = true
        try await eventually { switcher.ready }
        XCTAssertEqual(status.activeSettings?.id, next.modelID)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(status.activeSettings?.id, next.modelID)
    }

    func testRepeatedPendingSelectionLoadsOnlyOnce() async throws {
        let model = try XCTUnwrap(ModelRegistry.find("parakeet-v3"))
        let incoming = FixtureTranscriber(model.id, delay: 20_000_000)
        var creations = 0
        let switcher = ModelSwitcher(model: model, transcriber: FixtureTranscriber("unloaded"),
            status: ModelLoadStatus(), make: { _, _, _ in creations += 1; return incoming }, cached: { _, _ in true })
        switcher.select(selection(model.id))
        switcher.select(selection(model.id))
        try await eventually { switcher.ready }
        XCTAssertEqual(creations, 1)
        let loads = await incoming.loads
        XCTAssertEqual(loads, 1)
    }

    func testMissingExternalModelNeverPermitsDownload() async throws {
        let model = try XCTUnwrap(ModelRegistry.find("parakeet-unified"))
        var made = false
        let status = ModelLoadStatus()
        let fake = FixtureTranscriber(model.id)
        let switcher = ModelSwitcher(model: model, transcriber: fake, status: status,
            make: { _, _, _ in made = true; return fake }, cached: { _, _ in false })
        switcher.select(selection(model.id), allowDownload: true)
        XCTAssertFalse(made)
        XCTAssertEqual(status.current?.phase, .failed)
    }

    func testProvenanceSeparatesOwnSettingsAndSharedAssetsWithoutMuesliApp() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var settings = selection("parakeet-v3")
        settings.importedFrom = "muesli"
        let local = try MuesliModels.resolve(id: "parakeet-v3", modelFolder: nil, tokenizerFolder: nil, home: home)
        settings.modelFolder = local.modelFolder.path
        for file in local.requiredFiles {
            let names = file.hasSuffix(".mlmodelc") ? [file + "/coremldata.bin", file + "/weights/weight.bin"] : [file]
            for name in names {
                let url = local.modelFolder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: url)
            }
        }
        let valid = ModelProvenance.inspect(settings, home: home)
        XCTAssertEqual(valid.storage, .externalShared)
        XCTAssertTrue(valid.importedFromMuesli)
        XCTAssertNil(valid.problem)
        try renderContent(ModelSourceDetails(source: valid, title: "In use"), name: "shared-source")
        try FileManager.default.removeItem(at: local.modelFolder.appendingPathComponent("parakeet_vocab.json"))
        let missing = ModelProvenance.inspect(settings, home: home)
        XCTAssertNotNil(missing.problem)
        XCTAssertEqual(missing.modelFolder, valid.modelFolder)
        try renderContent(ModelSourceDetails(source: missing, title: "Selected"), name: "missing-source")
        let own = ModelProvenance.inspect(ModelSettings(), home: home)
        XCTAssertEqual(own.storage, .parrotManaged)
        XCTAssertFalse(own.importedFromMuesli)
    }

    func testSettingsEditsPreserveUnknownFieldsAndClearOldModelPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("settings.json")
        let original: [String: Any] = ["future": ["value": 7], "model": ["id": "parakeet-v3", "modelFolder": "/old", "future": true]]
        try JSONSerialization.data(withJSONObject: original).write(to: file)
        let store = SettingsStore(file: file)
        store.update { $0.model = $0.model.selecting("whisper-small") }
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((saved["future"] as? [String: Int])?["value"], 7)
        XCTAssertEqual((saved["model"] as? [String: Any])?["future"] as? Bool, true)
        XCTAssertNil((saved["model"] as? [String: Any])?["modelFolder"])
    }

    func testNativeOfferViewRendersFixtureStates() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("Library/Application Support/Muesli/config.json")
        let json: [String: Any] = ["stt_backend": "fluidaudio", "stt_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml"]
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: source)
        let model = try MuesliModels.fromMuesli(json, home: home)
        for file in model.requiredFiles {
            for name in file.hasSuffix(".mlmodelc") ? [file + "/coremldata.bin", file + "/weights/weight.bin"] : [file] {
                let url = model.modelFolder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: url)
            }
        }
        let offer = MuesliOffer(store: SettingsStore(file: home.appendingPathComponent("settings.json")), home: home)
        await offer.inspectAutomatically()
        try render(offer, name: "offer")
        offer.reject()
        try render(offer, name: "rejected")
        try FileManager.default.removeItem(at: model.modelFolder)
        await offer.retry()
        try render(offer, name: "missing-assets")
    }

    private func render(_ offer: MuesliOffer, name: String) throws {
        try renderContent(MuesliImportSection(offer: offer), name: name)
    }

    private func renderContent<Content: View>(_ view: Content, name: String) throws {
        let content = view.padding(24).frame(width: 460, alignment: .leading).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, 80)
        if let directory = ProcessInfo.processInfo.environment["PARROT_UI_PREVIEW_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
    }
}
