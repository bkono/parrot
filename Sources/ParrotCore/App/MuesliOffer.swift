import Foundation

/// The decision belongs to Parrot, independently of Muesli's configuration.
/// Persisting the offer before showing it prevents a crash/closed window from
/// turning into a prompt on every launch.
struct MuesliOfferReceipt: Codable, Equatable {
    enum Status: String, Codable {
        case unseen, offered, accepted, rejected, dismissed, failed, notFound
    }

    var status: Status = .unseen
    var prompted = false
    var updatedAt = Date()
    var error: String?

    static func location(settingsFile: URL) -> URL {
        settingsFile.deletingLastPathComponent().appendingPathComponent("muesli-import.json")
    }

    static func load(settingsFile: URL) throws -> Self {
        guard let data = try MuesliImport.originalData(at: location(settingsFile: settingsFile)) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save(settingsFile: URL) throws {
        let path = Self.location(settingsFile: settingsFile)
        _ = try MuesliImport.originalData(at: path)
        let target = path.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".muesli-decision-" + UUID().uuidString)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try MuesliImport.privateFile(encoder.encode(self), at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func recordAcceptance(settingsFile: URL) throws {
        var receipt = (try? load(settingsFile: settingsFile)) ?? Self()
        receipt.status = .accepted
        receipt.updatedAt = Date()
        receipt.error = nil
        try receipt.save(settingsFile: settingsFile)
    }
}

@MainActor
final class MuesliOffer: ObservableObject {
    typealias Status = MuesliOfferReceipt.Status

    @Published private(set) var selection: MuesliModels.Selection?
    @Published private(set) var status: Status
    @Published private(set) var error: String?
    @Published private(set) var isInspecting = false
    @Published private(set) var backupURL: URL?
    @Published private(set) var replacingModelID: String?
    var onStateChange: (() -> Void)?

    let sourceURL: URL
    let receiptURL: URL
    private let store: SettingsStore
    private let home: URL
    private var receipt: MuesliOfferReceipt
    private var previewModel: ModelSettings?
    private var generation = 0

    var wasPrompted: Bool { receipt.prompted }
    var shouldHoldInitialLoad: Bool { isInspecting || status == .unseen || status == .offered }

    init(store: SettingsStore, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.store = store
        self.home = home
        sourceURL = home.appendingPathComponent("Library/Application Support/Muesli/config.json")
        receiptURL = MuesliOfferReceipt.location(settingsFile: store.file)
        do {
            var receipt = try MuesliOfferReceipt.load(settingsFile: store.file)
            if receipt.status == .offered {
                // An uncompleted offer is a dismissal, including a crashed app.
                receipt.status = .dismissed
                receipt.updatedAt = Date()
                try receipt.save(settingsFile: store.file)
            }
            self.receipt = receipt
            self.status = receipt.status
            self.error = receipt.error
        } catch {
            let problem = "Parrot could not read its saved import decision. Retry explicitly to review the Muesli setup."
            self.receipt = MuesliOfferReceipt(status: .failed, error: problem)
            self.status = .failed
            self.error = problem
        }
    }

    func inspectAutomatically() async {
        guard status == .unseen, !isInspecting else { return }
        await inspect()
    }

    func retry() async {
        guard !isInspecting else { return }
        await inspect()
    }

    private func inspect() async {
        generation += 1
        let currentGeneration = generation
        selection = nil
        backupURL = nil
        error = nil
        isInspecting = true
        onStateChange?()
        let source = sourceURL
        let home = home
        let result = await Task.detached { () -> Result<MuesliModels.Selection?, Error> in
            Result {
                guard try MuesliImport.originalData(at: source, maximumBytes: 4 << 20) != nil else { return nil }
                let candidate = try MuesliModels.fromMuesli(MuesliImport.read(source), home: home)
                try MuesliModels.validate(candidate)
                return candidate
            }
        }.value
        guard generation == currentGeneration else { return }
        isInspecting = false
        switch result {
        case .success(let candidate?):
            previewModel = store.current.model
            replacingModelID = store.current.model.id
            // Persist before publishing the preview, never after a click.
            if transition(.offered, prompted: true) { selection = candidate }
        case .success(nil):
            previewModel = nil
            replacingModelID = nil
            _ = transition(.notFound)
        case .failure(let failure):
            previewModel = nil
            replacingModelID = nil
            _ = transition(.failed, error: failure.localizedDescription)
        }
        onStateChange?()
    }

    func accept() async {
        guard status == .offered, let selection, let previewModel, !isInspecting else { return }
        isInspecting = true
        error = nil
        onStateChange?()
        do {
            let source = sourceURL
            let home = home
            let target = store.file
            let backup = try await Task.detached { () throws -> URL? in
                let muesli = try MuesliImport.read(source)
                let current = try MuesliModels.fromMuesli(muesli, home: home)
                guard Self.sameSelection(current, selection) else {
                    throw MuesliImportError("Muesli's selected model changed. Review it again before importing.")
                }
                let original = try MuesliImport.originalData(at: target)
                let existing = try original.map { try MuesliImport.object($0, path: target) } ?? [:]
                let existingSettings = try JSONDecoder().decode(Settings.self,
                    from: JSONSerialization.data(withJSONObject: existing))
                guard existingSettings.model == previewModel else {
                    throw MuesliImportError("Parrot's model selection changed. Review the replacement again before importing.")
                }
                let proposal = try MuesliImport.proposal(muesli: muesli, existing: existing, home: home, replace: true)
                return try MuesliImport.write(proposal, to: target, expectedOriginal: original)
            }.value
            backupURL = backup
            store.reload()
            self.selection = nil
            isInspecting = false
            _ = transition(.accepted)
        } catch {
            isInspecting = false
            self.selection = nil
            _ = transition(.failed, error: error.localizedDescription)
        }
        onStateChange?()
    }

    func reject() { finish(.rejected) }
    func dismiss() { finish(.dismissed) }

    private func finish(_ status: Status) {
        guard self.status == .offered, !isInspecting else { return }
        generation += 1
        selection = nil
        previewModel = nil
        _ = transition(status)
        onStateChange?()
    }

    @discardableResult
    private func transition(_ status: Status, prompted: Bool? = nil, error: String? = nil) -> Bool {
        var next = receipt
        next.status = status
        next.updatedAt = Date()
        next.prompted = prompted ?? receipt.prompted
        next.error = error
        do {
            try next.save(settingsFile: store.file)
            receipt = next
            self.status = status
            self.error = error
            return true
        } catch {
            self.status = .failed
            self.error = "Parrot could not save the import decision: \(error.localizedDescription)"
            return false
        }
    }

    nonisolated private static func sameSelection(_ lhs: MuesliModels.Selection, _ rhs: MuesliModels.Selection) -> Bool {
        lhs.id == rhs.id && lhs.modelFolder.path == rhs.modelFolder.path && lhs.tokenizerFolder?.path == rhs.tokenizerFolder?.path
    }
}
