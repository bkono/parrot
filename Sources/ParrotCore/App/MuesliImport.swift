import Foundation

/// Imports only the selected speech model, never Muesli's credentials, meeting
/// recordings, hotkeys, or capture settings. Preview is the default operation.
public enum MuesliImport {
    public static func run(config: String? = nil, write: Bool = false, replace: Bool = false) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let source = config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent("Library/Application Support/Muesli/config.json")
        let muesli = try read(source)
        let target = Paths.settingsFile
        let original = try originalData(at: target)
        let existing = try original.map { try object($0, path: target) } ?? [:]
        let result = try proposal(muesli: muesli, existing: existing, home: home, replace: replace)
        // Restrict preview to imported fields; existing model settings can
        // contain unknown future fields which should be preserved, not printed.
        let selection = try MuesliModels.fromMuesli(muesli, home: home)
        let preview = try JSONSerialization.data(withJSONObject: ["model": selection.configuration],
                                                 options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: preview, as: UTF8.self))
        if write {
            let backup = try self.write(result, to: target, expectedOriginal: original)
            try MuesliOfferReceipt.recordAcceptance(settingsFile: target)
            print("Updated \(target.path)")
            if let backup { print("Backup: \(backup.path)") }
            print("Restart Parrot, then run parrot doctor. Meeting summaries are configured separately with quill import-muesli.")
        } else {
            print("Preview only. Add --write to apply; Muesli files are never modified.")
        }
    }

    static func read(_ url: URL) throws -> [String: Any] {
        guard let data = try originalData(at: url, maximumBytes: 4 << 20) else {
            throw MuesliImportError("Configuration does not exist at \(url.path).")
        }
        return try object(data, path: url)
    }

    static func proposal(muesli: [String: Any], existing: [String: Any], home: URL,
                         replace: Bool) throws -> [String: Any] {
        // Decode to reject malformed known fields without re-encoding and
        // discarding unknown user settings.
        _ = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: existing))
        let selection = try MuesliModels.fromMuesli(muesli, home: home)
        try MuesliModels.validate(selection)
        var model = existing["model"] as? [String: Any] ?? [:]
        let hasSelection = ["id", "modelFolder", "tokenizerFolder"].contains {
            model[$0] != nil && !(model[$0] is NSNull)
        }
        if hasSelection && !replace {
            throw MuesliImportError("Parrot already has a model selection. Preview with --replace; add --write to apply with a backup.")
        }
        model.removeValue(forKey: "tokenizerFolder")
        for (key, value) in selection.configuration { model[key] = value }
        model["importedFrom"] = "muesli"
        var result = existing
        result["model"] = model
        return result
    }

    /// Follows a user-owned dotfiles symlink while keeping the link itself.
    /// The byte comparison catches edits since preview before backing up or
    /// replacing the file. Backups and temporary files are private at creation.
    static func write(_ settings: [String: Any], to path: URL, expectedOriginal: Data?) throws -> URL? {
        let target = path.resolvingSymlinksInPath()
        guard try originalData(at: path) == expectedOriginal else {
            throw MuesliImportError("Parrot settings changed during import; rerun to review the current settings.")
        }
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        guard data.count <= SettingsStore.maxBytes else {
            throw MuesliImportError("Imported settings exceed Parrot's configuration size limit.")
        }
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var backup: URL?
        if let expectedOriginal {
            let url = target.appendingPathExtension("backup-" + UUID().uuidString)
            try privateFile(expectedOriginal, at: url)
            backup = url
        }
        let temporary = directory.appendingPathComponent(".parrot-import-" + UUID().uuidString)
        try privateFile(data, at: temporary)
        defer { try? fm.removeItem(at: temporary) }
        guard path.resolvingSymlinksInPath() == target,
              try originalData(at: path) == expectedOriginal else {
            throw MuesliImportError("Parrot settings changed during import; rerun to review the current settings.")
        }
        guard rename(temporary.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return backup
    }

    static func object(_ data: Data, path: URL) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MuesliImportError("Expected a JSON object at \(path.path).")
        }
        return json
    }

    static func originalData(at path: URL, maximumBytes: Int = 1 << 16) throws -> Data? {
        var linkInfo = stat()
        guard lstat(path.path, &linkInfo) == 0 else {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let target = path.resolvingSymlinksInPath()
        var info = stat()
        guard stat(target.path, &info) == 0 else {
            throw MuesliImportError("Configuration target is missing at \(target.path).")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= maximumBytes,
              info.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw MuesliImportError("Configuration must be a local regular file owned by you, under \(maximumBytes) bytes.")
        }
        return try Data(contentsOf: target)
    }

    static func privateFile(_ data: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
