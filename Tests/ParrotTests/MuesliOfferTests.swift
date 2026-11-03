import Foundation
import XCTest
@testable import ParrotCore

@MainActor
final class MuesliOfferTests: XCTestCase {
    private actor DiscoveryGate {
        private var paused: CheckedContinuation<Void, Never>?
        private var entered: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation { continuation in
                paused = continuation
                entered?.resume()
                entered = nil
            }
        }

        func waitUntilSuspended() async {
            if paused != nil { return }
            await withCheckedContinuation { entered = $0 }
        }

        func release() {
            paused?.resume()
            paused = nil
        }
    }

    private struct Fixture {
        let home: URL
        let settings: URL
        let source: URL
        let sourceJSON: [String: Any] = ["stt_backend": "fluidaudio", "stt_model": "FluidInference/parakeet-tdt-0.6b-v3-coreml"]

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-offer-" + UUID().uuidString)
            settings = home.appendingPathComponent("parrot/settings.json")
            source = home.appendingPathComponent("Library/Application Support/Muesli/config.json")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func write(_ json: [String: Any], to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }

        func prepare(complete: Bool = true) throws {
            try write(sourceJSON, to: source)
            guard complete else { return }
            let selected = try MuesliModels.fromMuesli(sourceJSON, home: home)
            for file in selected.requiredFiles {
                let paths = file.hasSuffix(".mlmodelc")
                    ? [file + "/coremldata.bin", file + "/weights/weight.bin"] : [file]
                for path in paths {
                    let url = selected.modelFolder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data([1]).write(to: url)
                }
            }
        }

        func remove() { try? FileManager.default.removeItem(at: home) }
    }

    func testOfferIsPersistedBeforeAcceptanceAndDoesNotChangeSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepare()
        let store = SettingsStore(file: fixture.settings)
        let offer = MuesliOffer(store: store, home: fixture.home)
        XCTAssertTrue(offer.shouldHoldInitialLoad)
        await offer.inspectAutomatically()
        XCTAssertEqual(offer.status, .offered)
        XCTAssertEqual(offer.selection?.id, "parakeet-v3")
        XCTAssertTrue(offer.wasPrompted)
        XCTAssertTrue(offer.shouldHoldInitialLoad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.settings.path))
        let receipt = try MuesliOfferReceipt.load(settingsFile: fixture.settings)
        XCTAssertEqual(receipt.status, .offered)
        XCTAssertTrue(receipt.prompted)
    }

    func testAcceptBacksUpAndAppliesCurrentPreferencesWithoutRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepare()
        try fixture.write(["model": ["id": "whisper-small"], "future": 7], to: fixture.settings)
        let store = SettingsStore(file: fixture.settings)
        let offer = MuesliOffer(store: store, home: fixture.home)
        var applied = [String?]()
        store.observe { _, settings in applied.append(settings.model.id) }
        await offer.inspectAutomatically()
        XCTAssertEqual(offer.replacingModelID, "whisper-small")
        // An unrelated hand edit made while reviewing is preserved.
        try fixture.write(["model": ["id": "whisper-small"], "future": 9], to: fixture.settings)
        let before = try Data(contentsOf: fixture.settings)
        let sourceBefore = try Data(contentsOf: fixture.source)
        await offer.accept()
        XCTAssertEqual(offer.status, .accepted)
        XCTAssertEqual(store.current.model.id, "parakeet-v3")
        XCTAssertEqual(store.current.model.importedFrom, "muesli")
        XCTAssertEqual(applied, ["parakeet-v3"])
        XCTAssertEqual(try MuesliImport.read(fixture.settings)["future"] as? Int, 9)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(offer.backupURL)), before)
        XCTAssertEqual(try Data(contentsOf: fixture.source), sourceBefore)
        let relaunched = MuesliOffer(store: store, home: fixture.home)
        await relaunched.inspectAutomatically()
        XCTAssertEqual(relaunched.status, .accepted)
        XCTAssertNil(relaunched.selection)
    }

    func testRejectAndDismissAreRememberedAndExplicitRetryWorks() async throws {
        for reject in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.prepare()
            let store = SettingsStore(file: fixture.settings)
            let offer = MuesliOffer(store: store, home: fixture.home)
            await offer.inspectAutomatically()
            if reject { offer.reject() } else { offer.dismiss() }
            let expected: MuesliOffer.Status = reject ? .rejected : .dismissed
            XCTAssertEqual(offer.status, expected)
            XCTAssertNil(store.current.model.id)
            let relaunched = MuesliOffer(store: store, home: fixture.home)
            await relaunched.inspectAutomatically()
            XCTAssertEqual(relaunched.status, expected)
            XCTAssertNil(relaunched.selection)
            XCTAssertTrue(relaunched.wasPrompted)
            await relaunched.retry()
            XCTAssertEqual(relaunched.status, .offered)
        }
    }

    func testInterruptedOfferBecomesDismissedWithoutAnotherPrompt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepare()
        let store = SettingsStore(file: fixture.settings)
        let offer = MuesliOffer(store: store, home: fixture.home)
        await offer.inspectAutomatically()
        let relaunched = MuesliOffer(store: store, home: fixture.home)
        await relaunched.inspectAutomatically()
        XCTAssertEqual(relaunched.status, .dismissed)
        XCTAssertEqual(try MuesliOfferReceipt.load(settingsFile: fixture.settings).status, .dismissed)
        XCTAssertNil(relaunched.selection)
    }

    func testAbsentAndIncompleteSourcesNeedExplicitRetryAfterRepair() async throws {
        for absent in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            if !absent { try fixture.prepare(complete: false) }
            let store = SettingsStore(file: fixture.settings)
            let offer = MuesliOffer(store: store, home: fixture.home)
            await offer.inspectAutomatically()
            let expected: MuesliOffer.Status = absent ? .notFound : .failed
            XCTAssertEqual(offer.status, expected)
            XCTAssertNil(store.current.model.id)
            XCTAssertFalse(offer.wasPrompted)
            try fixture.prepare()
            let relaunched = MuesliOffer(store: store, home: fixture.home)
            await relaunched.inspectAutomatically()
            XCTAssertEqual(relaunched.status, expected)
            await relaunched.retry()
            XCTAssertEqual(relaunched.status, .offered)
        }
    }

    func testChangedSourceOrTargetModelRequiresAnotherPreview() async throws {
        for changeSource in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.prepare()
            try fixture.write(["model": ["id": "whisper-small"]], to: fixture.settings)
            let store = SettingsStore(file: fixture.settings)
            let offer = MuesliOffer(store: store, home: fixture.home)
            await offer.inspectAutomatically()
            if changeSource {
                try fixture.write(["stt_backend": "fluidaudio", "stt_model": "FluidInference/parakeet-tdt-0.6b-v2-coreml"], to: fixture.source)
            } else {
                try fixture.write(["model": ["id": "whisper-tiny"]], to: fixture.settings)
            }
            let before = try Data(contentsOf: fixture.settings)
            await offer.accept()
            XCTAssertEqual(offer.status, .failed)
            XCTAssertNotNil(offer.error)
            XCTAssertNil(offer.backupURL)
            XCTAssertEqual(try Data(contentsOf: fixture.settings), before)
            XCTAssertNil(offer.selection)
        }
    }

    func testMalformedExistingSettingsAreNeverResetByAccept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepare()
        try fixture.write(["model": 42], to: fixture.settings)
        let before = try Data(contentsOf: fixture.settings)
        let store = SettingsStore(file: fixture.settings, log: { _ in })
        let offer = MuesliOffer(store: store, home: fixture.home)
        await offer.inspectAutomatically()
        await offer.accept()
        XCTAssertEqual(offer.status, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.settings), before)
    }

    func testCLIReceiptSuppressesAutomaticOffer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepare()
        try MuesliOfferReceipt.recordAcceptance(settingsFile: fixture.settings)
        let offer = MuesliOffer(store: SettingsStore(file: fixture.settings), home: fixture.home)
        await offer.inspectAutomatically()
        XCTAssertEqual(offer.status, .accepted)
        XCTAssertFalse(offer.wasPrompted)
        XCTAssertNil(offer.selection)
    }

    func testClosingDuringDiscoveryDismissesWithoutPublishingLateOffer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepare()
        let candidate = try MuesliModels.fromMuesli(fixture.sourceJSON, home: fixture.home)
        let gate = DiscoveryGate()
        let store = SettingsStore(file: fixture.settings)
        let offer = MuesliOffer(store: store, home: fixture.home, inspectSource: { _, _ in
            await gate.suspend()
            return candidate
        })
        var observed = [MuesliOffer.Status]()
        offer.onStateChange = { [weak offer] in if let offer { observed.append(offer.status) } }
        let inspection = Task { await offer.retry() }
        await gate.waitUntilSuspended()
        XCTAssertTrue(offer.isInspecting)
        offer.dismiss()
        XCTAssertEqual(offer.status, .dismissed)
        XCTAssertFalse(offer.shouldHoldInitialLoad)
        await gate.release()
        await inspection.value
        XCTAssertEqual(offer.status, .dismissed)
        XCTAssertNil(offer.selection)
        XCTAssertFalse(observed.contains(.offered))
        XCTAssertEqual(try MuesliOfferReceipt.load(settingsFile: fixture.settings).status, .dismissed)
        let relaunched = MuesliOffer(store: store, home: fixture.home)
        await relaunched.inspectAutomatically()
        XCTAssertEqual(relaunched.status, .dismissed)
    }

    func testClosingDuringAcceptedWriteDoesNotCancelConsent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepare()
        let store = SettingsStore(file: fixture.settings)
        let offer = MuesliOffer(store: store, home: fixture.home)
        await offer.inspectAutomatically()
        offer.onStateChange = { [weak offer] in
            if let offer, offer.status == .offered, offer.isInspecting { offer.dismiss() }
        }
        await offer.accept()
        XCTAssertEqual(offer.status, .accepted)
        XCTAssertEqual(store.current.model.id, "parakeet-v3")
        XCTAssertEqual(try MuesliOfferReceipt.load(settingsFile: fixture.settings).status, .accepted)
    }
}
