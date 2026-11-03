import Foundation

/// Loads `settings.json`, writes it atomically, and reloads it when it
/// changes on disk, so a hand edit applies without a restart (ADR-002).
///
/// The only writer of the file. A file that fails to load keeps the last good
/// settings and logs one line naming the problem; the line is not repeated
/// until the problem changes.
///
/// The file may live in a dotfiles repository: `~/.config/parrot`, or the file
/// itself, can be a symlink. The store resolves the path, requires the target
/// to be a regular file owned by the current user, and writes to the resolved
/// target, so the link survives a save.
@MainActor
final class SettingsStore: ObservableObject {
    /// Larger than any hand-written settings file; refuses anything absurd.
    nonisolated static let maxBytes = 1 << 16

    let file: URL
    @Published private(set) var current: Settings

    private let log: (String) -> Void
    private var observers: [(_ old: Settings, _ new: Settings) -> Void] = []
    private var lastProblem: String?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var reloadScheduled = false

    init(file: URL = Paths.settingsFile, log: @escaping (String) -> Void = { Log.warning($0) }) {
        self.file = file
        self.log = log
        self.current = Settings()
        if let loaded = read() { current = loaded }
    }

    /// Calls `handler` with the old and new settings after every change,
    /// whether it came from `write` or from an edit on disk.
    func observe(_ handler: @escaping (_ old: Settings, _ new: Settings) -> Void) {
        observers.append(handler)
    }

    /// Saves `settings` and applies it. Creates the config directory owner-only
    /// if it is missing.
    func write(_ settings: Settings) {
        do {
            try save(settings)
        } catch {
            log("couldn't save \(file.path): \(error.localizedDescription)")
            return
        }
        apply(settings)
    }

    /// Changes one field and saves.
    func update(_ change: (inout Settings) -> Void) {
        var next = current
        change(&next)
        write(next)
    }

    /// Writes the current settings if no file exists yet, so Open Config File
    /// has something to open.
    func createIfMissing() {
        guard Paths.fileType(file.path) == nil else { return }
        try? save(current)
    }

    /// Reads the file again and applies it if it changed.
    func reload() {
        if let loaded = read() { apply(loaded) }
        armFileWatch()
    }

    // MARK: - Reading and writing

    private func apply(_ settings: Settings) {
        guard settings != current else { return }
        let old = current
        current = settings
        for observer in observers { observer(old, settings) }
    }

    /// The settings on disk, `Settings()` when there is no file, or nil when
    /// the file can't be used (logged once).
    private func read() -> Settings? {
        guard Paths.fileType(file.path) != nil else {
            lastProblem = nil
            return Settings()
        }
        let resolved = file.resolvingSymlinksInPath().path
        var st = stat()
        guard stat(resolved, &st) == 0 else {
            return refuse("\(file.path) points to \(resolved), which doesn't exist")
        }
        if st.st_mode & S_IFMT != S_IFREG { return refuse("\(resolved) is not a regular file") }
        if st.st_uid != getuid() { return refuse("\(resolved) is not owned by you") }
        if st.st_size > Self.maxBytes { return refuse("\(resolved) is larger than \(Self.maxBytes / 1024) KB") }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            lastProblem = nil
            return settings
        } catch let error as DecodingError {
            return refuse("\(file.lastPathComponent) not loaded, \(Self.describe(error))")
        } catch {
            return refuse("couldn't read \(resolved): \(error.localizedDescription)")
        }
    }

    private func refuse(_ problem: String) -> Settings? {
        if problem != lastProblem {
            lastProblem = problem
            log("\(problem); keeping the last good settings")
        }
        return nil
    }

    private func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(settings)
        data.append(0x0A)

        let dir = file.deletingLastPathComponent()
        if Paths.fileType(dir.path) == nil {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Write to the link's target, so a symlinked file stays a symlink.
        let target = Paths.fileType(file.path) == .typeSymbolicLink ? file.resolvingSymlinksInPath() : file
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        lastProblem = nil
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
                ?? context.debugDescription
            return path.isEmpty ? detail : "\(path): \(detail)"
        @unknown default:
            return "\(error)"
        }
    }

    // MARK: - Watching

    /// Watches the config directory (atomic saves replace the file, which only
    /// the directory sees) and the file itself (editors that write in place).
    /// Follows a symlinked directory to its target.
    func startWatching() {
        guard directorySource == nil else { return }
        let dir = file.deletingLastPathComponent().resolvingSymlinksInPath()
        if Paths.fileType(dir.path) == nil {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        directorySource = source(for: dir.path, events: .write)
        armFileWatch()
    }

    private func armFileWatch() {
        guard directorySource != nil else { return }
        fileSource?.cancel()
        fileSource = source(for: file.resolvingSymlinksInPath().path, events: [.write, .delete, .rename, .extend])
    }

    private func source(for path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Coalesces a burst of events (an atomic save produces several) into one
    /// reload.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadScheduled = false
                self.reload()
            }
        }
    }
}
