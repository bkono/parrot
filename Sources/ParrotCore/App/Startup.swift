import ApplicationServices
import AVFoundation
import Foundation

/// Why the daemon could not start.
///
/// A permanent failure needs the user to act and a relaunch cannot fix it,
/// so the entry point prints `message` once and exits 0, and a supervisor
/// that relaunches on nonzero exit leaves it alone. Anything else (warmup
/// errors, a crash) exits nonzero. The login item (`SMAppService.mainApp`)
/// starts Parrot once per login and does not relaunch it.
public enum StartupFailure: Error {
    case microphoneDenied
    case unknownModel(String)
    case noModelsRegistered
    /// `parrot doctor` checks failed; the report has already been printed.
    case checksFailed
    case warmupFailed(Error)
    case hotkeyUnavailable(Error)

    public var isPermanent: Bool {
        switch self {
        case .microphoneDenied, .unknownModel, .noModelsRegistered:
            return true
        case .checksFailed, .warmupFailed, .hotkeyUnavailable:
            return false
        }
    }

    /// The one message to print. Permanent failures name the exact fix.
    public var message: String {
        switch self {
        case .microphoneDenied:
            return Self.permanent(
                "microphone access denied",
                fix: "run `parrot setup`, or enable parrot in System Settings → Privacy & Security → Microphone"
            )
        case .unknownModel(let id):
            return Self.permanent("unknown model: \(id)", fix: "pick one from `parrot models list` and update --model")
        case .noModelsRegistered:
            return Self.permanent("no models registered", fix: "reinstall parrot")
        case .checksFailed:
            return "\nfix the above or pass --skip-doctor"
        case .warmupFailed(let error):
            return "warmup failed: \(error)"
        case .hotkeyUnavailable(let error):
            return "failed to register hotkey tap: \(error)\nrun `parrot setup` to configure permissions."
        }
    }

    private static func permanent(_ problem: String, fix: String) -> String {
        "\(problem)\n"
            + "  fix: \(fix), then restart parrot "
            + "(`open -a Parrot`, or log in again)."
    }
}

/// Checks that run before any model loads, so a failing start costs nothing.
enum Startup {
    /// Runs the startup checks and returns the model to load.
    /// Throws `StartupFailure`. `hotkey` is a `--hotkey` override, nil for
    /// the saved key; it decides whether the fn mapping is checked.
    static func check(modelID: String?, hotkey: HotkeyKey? = nil, skipDoctor: Bool, modelSettings: ModelSettings? = nil) throws -> TranscriptionModel {
        // Agents installed before 0.0.6 log to /tmp until the plist is rewritten.
        if Paths.legacyTmpFiles.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            Log.info("note: old parrot logs found in /tmp; run `parrot install --launch-at-login` again to remove them and log privately.")
        }

        if !skipDoctor {
            let checks = DoctorReport.run(hotkey: hotkey, modelSettings: modelSettings)
            if !DoctorReport.allOK(checks) {
                Log.error("startup checks failed:")
                DoctorReport.print(checks)
                throw StartupFailure.checksFailed
            }
        }

        let model = try resolveModel(modelID)

        // Accessibility is not checked here. A missing grant is not a startup
        // failure: the daemon asks for it once and waits (Daemon.startHotkey).

        // .notDetermined is requested asynchronously once the daemon starts
        // (MicrophoneAccess), and again on the first press if still undecided.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw StartupFailure.microphoneDenied
        default:
            break
        }

        // Don't look in ~/Documents for an old cache: under launchd that read
        // is denied or prompts. Name the command that can migrate instead.
        if model.engine == .whisperKit && !WhisperKitTranscriber.isCached(model) {
            Log.info("\(model.id): imported model folders load locally; otherwise Parrot uses its own cache. Run `parrot import-muesli` to preview reuse.")
        }

        return model
    }

    /// The model for `id`, or the recommended one when `id` is nil.
    static func resolveModel(_ id: String?) throws -> TranscriptionModel {
        if let id {
            guard let m = ModelRegistry.find(id) else { throw StartupFailure.unknownModel(id) }
            return m
        }
        guard let m = ModelRegistry.recommended() else { throw StartupFailure.noModelsRegistered }
        return m
    }
}
