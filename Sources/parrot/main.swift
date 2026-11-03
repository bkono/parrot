import ArgumentParser
import Foundation
import ParrotCore

// The entry point parses flags and calls ParrotCore. Behaviour lives there.

struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold a key (fn by default), speak, release.",
        version: AppBundle.version,
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, ImportMuesli.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print each modifier change the hotkey tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to ~/Library/Caches/parrot/last-capture.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(
        name: .long,
        help: "How text is inserted: paste (default; borrows the clipboard and restores it) or type-unicode.",
        transform: { raw in
            guard let mode = InjectMode(rawValue: raw) else {
                throw ValidationError("expected one of: \(InjectMode.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return mode
        }
    )
    var injectMode: InjectMode = .paste

    @Option(
        name: .long,
        help: "How the microphone is run: \(CaptureMode.allCases.map(\.rawValue).joined(separator: ", ")) (default \(CaptureMode.standard.rawValue)).",
        transform: parseCaptureMode
    )
    var capture: CaptureMode = .standard

    @Option(
        name: .long,
        help: "Push-to-talk key for this run only, overriding Settings: \(HotkeyKey.allCases.map(\.rawValue).joined(separator: ", ")).",
        transform: parseHotkey
    )
    var hotkey: HotkeyKey?

    func run() throws {
        // The app and a foreground run would both paste every dictation.
        guard AppLaunch.claimSingleInstance() else {
            Log.error("Parrot is already running. Quit it from the menu bar first.")
            throw ExitCode(1)
        }
        do {
            try Daemon.run(DaemonOptions(
                skipDoctor: skipDoctor,
                debugHotkey: debugHotkey,
                dumpWav: dumpWav,
                noOverlay: noOverlay,
                model: model,
                injectMode: injectMode,
                captureMode: capture,
                hotkey: hotkey
            ))
        } catch let failure as StartupFailure {
            // The one exit-code rule. A supervisor that relaunches on nonzero
            // exit can't fix a permanent failure, so print its fix once and
            // exit 0. Everything else exits nonzero. The app has no terminal,
            // so it also shows the failure in a dialog.
            Log.error(failure.message)
            MainActor.assumeIsolated { AppLaunch.presentStartupFailure(failure) }
            throw ExitCode(failure.isPermanent ? 0 : 1)
        }
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk through first-run permission setup."
    )

    func run() throws {
        try exiting { try SetupFlow.run() }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and fn key configuration."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            ModelCommands.list()
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            try exiting { try ModelCommands.download(id) }
        }
    }
}

struct ImportMuesli: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-muesli",
        abstract: "Preview reuse of Muesli's installed dictation model; --write saves it."
    )

    @Option(name: .long, help: "Muesli config.json path (defaults to Application Support/Muesli/config.json).")
    var config: String?

    @Flag(name: .long, help: "Write the validated selection to Parrot settings, with a backup.")
    var write = false

    @Flag(name: .long, help: "Replace an existing Parrot model selection when writing.")
    var replace = false

    func run() throws {
        try MuesliImport.run(config: config, write: write, replace: replace)
    }
}

/// Launch at login and the `parrot` command on PATH.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up launch at login and the parrot command, or remove them."
    )

    @Flag(name: .long, help: "Start Parrot.app at login, and start it now.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Link /usr/local/bin/parrot to the executable in Parrot.app.")
    var cli: Bool = false

    @Flag(name: .long, help: "Stop starting at login, quit Parrot, and remove its logs.")
    var uninstall: Bool = false

    func run() throws {
        if [launchAtLogin, cli, uninstall].filter({ $0 }).count != 1 {
            Log.error("specify exactly one of --launch-at-login, --cli, or --uninstall")
            throw ExitCode(64)
        }

        try exiting {
            if uninstall {
                try LoginItem.uninstall()
            } else if cli {
                try CommandLineLink.installFromTerminal()
            } else {
                try LoginItem.install()
            }
        }
    }
}

/// `--capture`: a `CaptureMode` by name.
private func parseCaptureMode(_ raw: String) throws -> CaptureMode {
    guard let mode = CaptureMode(rawValue: raw) else {
        throw ValidationError("expected one of: \(CaptureMode.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return mode
}

/// `--hotkey`: a `HotkeyKey` by name.
private func parseHotkey(_ raw: String) throws -> HotkeyKey {
    guard let key = HotkeyKey(rawValue: raw) else {
        throw ValidationError("expected one of: \(HotkeyKey.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return key
}

/// Maps ParrotCore's `SilentExit` to an exit code. Any other error reaches
/// ArgumentParser, which prints it and exits nonzero.
private func exiting(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let exit as SilentExit {
        throw ExitCode(exit.code)
    }
}

// Through the /usr/local/bin symlink, become the executable inside
// Parrot.app so the bundle (version, login item) is found.
AppBundle.resolveSymlinkedLaunch()

if AppLaunch.launchedAsApp {
    // Opened from Finder, `open`, or the login item: the menu-bar app.
    MainActor.assumeIsolated { AppLaunch.prepare() }
    Parrot.main(["run", "--skip-doctor"])
} else {
    Parrot.main()
}
