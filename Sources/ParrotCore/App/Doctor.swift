import AVFoundation
import AppKit
import ApplicationServices
import Foundation

public enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

public struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

public enum DoctorReport {
    /// `hotkey` is the key in use, nil for the one saved in settings.json.
    /// The fn mapping matters only when that key is fn (#42).
    public static func run(hotkey: HotkeyKey? = nil) -> [Check] {
        run(hotkey: hotkey, modelSettings: nil)
    }

    static func run(hotkey: HotkeyKey?, modelSettings: ModelSettings?) -> [Check] {
        // Doctor runs from the command line, on the main thread.
        let key = hotkey ?? MainActor.assumeIsolated { SettingsStore().current.hotkey.key }
        var checks = [checkMicrophone(), checkAccessibility()]
        if key == .fn { checks.append(checkFnKeyMapping()) }
        checks.append(checkModelCache(settings: modelSettings))
        return checks
    }

    /// Models belong in Application Support. ~/Documents is unreadable from
    /// the launchd daemon and iCloud can evict the weights, which hangs load.
    static func checkModelCache(settings: ModelSettings? = nil) -> Check {
        let settings = settings ?? MainActor.assumeIsolated { SettingsStore().current.model }
        if let id = settings.id, let model = ModelRegistry.find(id),
           model.engine == .parakeet || settings.modelFolder != nil {
            do {
                let selection = try MuesliModels.resolve(id: id, modelFolder: settings.modelFolder, tokenizerFolder: settings.tokenizerFolder)
                try MuesliModels.validate(selection)
                return Check(name: "local model \(id) (\(selection.modelFolder.path))", status: .ok, remediation: nil)
            } catch {
                return Check(name: "local model \(id)", status: .fail(error.localizedDescription), remediation: "restore the selected cached model in Muesli, then run `parrot import-muesli` to preview; no automatic download or fallback occurs")
            }
        }
        let name = "model cache (\(Paths.appSupport.path))"
        let resolved = Paths.appSupport.resolvingSymlinksInPath().path
        let documents = Paths.documents.path
        if resolved.hasPrefix(documents + "/") || resolved.contains("/Library/Mobile Documents/") {
            return Check(
                name: name,
                status: .warn("resolves to \(resolved), under ~/Documents or iCloud"),
                remediation: "make \(Paths.appSupport.path) a real folder, then `parrot models download <id>`"
            )
        }
        if WhisperKitTranscriber.hasLegacyModels() {
            return Check(
                name: name,
                status: .warn("models still in \(Paths.legacyModels.path)"),
                remediation: "run `parrot import-muesli` to preview model reuse without moving shared assets"
            )
        }
        return Check(name: name, status: .ok, remediation: nil)
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "run parrot and hold the hotkey once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for your terminal"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    static func checkAccessibility() -> Check {
        if AXIsProcessTrusted() {
            return Check(name: "accessibility", status: .ok, remediation: nil)
        }
        let parent = parentProcessName() ?? "your terminal"
        return Check(
            name: "accessibility",
            status: .fail("not granted"),
            remediation: "System Settings → Privacy & Security → Accessibility → enable for \(parent)"
        )
    }

    /// macOS routes Fn (🌐) to one of: Do Nothing / Change Input Source / Show Emoji / Start Dictation.
    /// We need "Do Nothing" so Fn is a clean modifier.
    static func checkFnKeyMapping() -> Check {
        let raw = readDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType")
        guard let raw, let value = Int(raw) else {
            return Check(
                name: "fn key mapping",
                status: .warn("unset — system default may intercept Fn"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
        switch value {
        case 0:
            return Check(name: "fn key mapping", status: .ok, remediation: nil)
        case 1:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Change Input Source"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 2:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Show Emoji & Symbols"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 3:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Start Dictation"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        default:
            return Check(
                name: "fn key mapping",
                status: .warn("unknown value \(value)"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
    }

    private static func readDefault(domain: String, key: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", domain, key]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parentProcessName() -> String? {
        let ppid = getppid()
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(ppid), "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return (s as NSString).lastPathComponent
    }

    public static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    public static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }

    /// True only if every check passed cleanly (used by `parrot doctor` exit code).
    public static func allClean(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .ok = $0.status { return true }
            return false
        }
    }
}
