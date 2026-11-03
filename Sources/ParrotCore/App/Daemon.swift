import AppKit
import Foundation

/// Flags for one foreground run of the dictation loop. Never persisted.
public struct DaemonOptions {
    public var skipDoctor: Bool
    public var debugHotkey: Bool
    public var dumpWav: Bool
    public var noOverlay: Bool
    public var model: String?
    /// How transcripts are inserted. Paste unless `--inject-mode` says otherwise.
    public var injectMode: InjectMode
    /// How the microphone is run (#52). The standard mode unless `--capture` says otherwise.
    public var captureMode: CaptureMode
    /// The push-to-talk key for this run only (#42). Nil uses the saved setting.
    public var hotkey: HotkeyKey?

    public init(
        skipDoctor: Bool,
        debugHotkey: Bool,
        dumpWav: Bool,
        noOverlay: Bool,
        model: String?,
        injectMode: InjectMode = .paste,
        captureMode: CaptureMode = .standard,
        hotkey: HotkeyKey? = nil
    ) {
        self.skipDoctor = skipDoctor
        self.debugHotkey = debugHotkey
        self.dumpWav = dumpWav
        self.noOverlay = noOverlay
        self.model = model
        self.injectMode = injectMode
        self.captureMode = captureMode
        self.hotkey = hotkey
    }
}

/// The dictation daemon (`parrot`, `parrot run`): startup checks, then the
/// AppKit run loop with the model loading behind the menu-bar icon. Does not
/// return once running.
public enum Daemon {
    /// Throws `StartupFailure` if the daemon cannot start.
    public static func run(_ options: DaemonOptions) throws {
        // ArgumentParser calls run() on the main thread.
        let settings = MainActor.assumeIsolated { SettingsStore() }
        var modelSettings = MainActor.assumeIsolated { settings.current.model }
        if let id = options.model { modelSettings = modelSettings.selecting(id) }
        let requestedID = options.model ?? (modelSettings.modelFolder != nil ? modelSettings.id : Self.knownModel(modelSettings.id))
        // Native recovery must keep Settings available for an unsupported saved
        // selection. The placeholder is never loaded; the switcher reports the
        // actual saved selection until the user chooses a compatible model.
        let startupID = AppLaunch.isApp && requestedID.flatMap(ModelRegistry.find) == nil ? nil : requestedID
        let chosenModel = try Startup.check(
            modelID: startupID,
            hotkey: options.hotkey,
            skipDoctor: options.skipDoctor,
            modelSettings: modelSettings
        )

        // Startup has already exited on denied access. If the system has never
        // asked, ask now, without waiting, so the prompt is answered while the
        // model loads rather than on the first press. Parrot.app asks from
        // the onboarding window's Allow instead, never unannounced (#51).
        if !AppLaunch.isApp {
            MicrophoneAccess.requestIfUndetermined()
        }

        modelSettings.id = chosenModel.id
        let transcriber = TranscriberFactory.make(model: chosenModel, settings: modelSettings, allowDownload: false)

        try MainActor.assumeIsolated {
            try runLoop(model: chosenModel, transcriber: transcriber, modelSettings: modelSettings, settings: settings, options: options)
        }
    }

    /// `id` if the registry knows it. A saved id that no longer exists (a
    /// model removed in an update, a typo in a hand edit) falls back to the
    /// recommended model instead of stopping Parrot; `--model` stays strict.
    static func knownModel(_ id: String?) -> String? {
        guard let id else { return nil }
        guard ModelRegistry.find(id) != nil else {
            Log.warning("settings.json: unknown model \"\(id)\"; using the recommended model")
            return nil
        }
        return id
    }

    /// Wires the hotkey, capture and UI to a `DictationController` and runs
    /// the AppKit loop. Returns only if the app terminates.
    @MainActor
    private static func runLoop(
        model: TranscriptionModel,
        transcriber: any ManagedTranscriber,
        modelSettings: ModelSettings,
        settings: SettingsStore,
        options: DaemonOptions
    ) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(key: options.hotkey ?? settings.current.hotkey.key, debug: options.debugHotkey)
        let capture = AudioCapture(mode: options.captureMode)
        let overlay: RecordingOverlay? = options.noOverlay ? nil : RecordingOverlay()
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        // Before the menu, which shows "Check for Updates…" only when running.
        if AppLaunch.isApp { Updater.start() }
        let menuBar = MenuBarController(modelID: model.id)
        let offer = MuesliOffer(store: settings)
        let settingsWindow = SettingsWindow(store: settings, offer: offer)
        menuBar.onOpenSettings = { settingsWindow.show() }
        menuBar.setHotkey(monitor.key)
        // A model change loads behind the menu bar and swaps in between dictations (#43).
        let switcher = ModelSwitcher(model: model, transcriber: transcriber, menuBar: menuBar, settings: modelSettings)

        // The dictionary (#33): converted once from dictionary.json, created
        // on first run, reloaded when it changes.
        let dictionary = DictionaryStore()
        switch DictionaryMigration.run() {
        case .converted(let examples):
            // The text file has no place for example sentences; they move to
            // settings.json, unless settings already has its own.
            if !examples.isEmpty {
                if settings.current.dictionary.examples.isEmpty {
                    settings.update { $0.dictionary.examples = examples }
                } else {
                    Log.info("dictionary: settings.json already has example sentences; kept those")
                }
            }
        case .nothingToDo:
            dictionary.createIfMissing()
        case .failed:
            // Leave the path empty so the next launch tries again.
            break
        }
        // Read at each release, so a Language change applies at the next press (#43).
        let dictionaryContext = {
            var context = DictionaryContext(
                store: dictionary,
                language: DictionaryContext.language(of: switcher.model, setting: settings.current.language.code),
                examples: settings.current.dictionary.examples
            ).context()
            context.spokenLanguages = settings.current.language.spoken ?? []
            return context
        }

        // Overlay first, then menu bar: the order the UI updated in before.
        var observers: [DictationObserver] = []
        if let overlay { observers.append(overlay) }
        observers.append(menuBar)
        observers.append(LatencyLog())
        let controller = DictationController(
            capture: capture,
            transcriber: transcriber,
            processors: [DictionaryProcessor(store: dictionary)],
            observers: observers,
            dumpWav: options.dumpWav,
            delivery: TextDelivery(mode: options.injectMode),
            context: dictionaryContext
        )
        switcher.controller = controller

        // Each setting applies itself here when it changes, from the window
        // or a hand edit of settings.json (#41). CLI flags only set the
        // starting values of a foreground run.
        settings.observe { old, new in
            if old.hotkey != new.hotkey {
                if options.hotkey != nil {
                    Log.info("hotkey: \(new.hotkey.key.rawValue) saved; --hotkey \(monitor.key.rawValue) stays in effect for this run")
                } else {
                    // The tap stays; it matches the new key from the next event.
                    monitor.setKey(new.hotkey.key)
                    menuBar.setHotkey(new.hotkey.key)
                    Log.info("hotkey: \(new.hotkey.key.rawValue); hold \(new.hotkey.key.shortName) to dictate")
                }
            }
            if old.model != new.model {
                switcher.select(new.model)
            }
            if old.language != new.language {
                // Read per dictation by dictionaryContext.
                Log.info("language: \(new.language.code ?? "automatic"); applies at next press")
            }
        }
        settings.startWatching()

        // HotkeyMonitor reports health on the main thread.
        monitor.onHealthChange = { health in
            MainActor.assumeIsolated { menuBar.setHotkeyHealth(health) }
        }
        // One model-load lifecycle serves startup, imports, recovery and swaps.
        // No default model downloads while discovery or an offer is outstanding.
        var hotkeyStarted = false
        switcher.onReady = {
            guard !hotkeyStarted else { return }
            hotkeyStarted = true
            do {
                try startHotkey(monitor, menuBar: menuBar) { event in controller.handle(event) }
            } catch {
                hotkeyStarted = false
                Log.error((error as? StartupFailure)?.message ?? "\(error)")
                menuBar.setHotkeyHealth(.tapDisabled)
            }
        }
        ModelLoadStatus.shared.requestLoad = { allowDownload in
            switcher.select(settings.current.model, allowDownload: allowDownload, force: true)
        }
        var initialDiscovery = AppLaunch.isApp
        var startupResolved = false
        var onboardingShown = false
        offer.onStateChange = {
            if initialDiscovery, !offer.isInspecting, offer.status == .offered || offer.status == .failed {
                settingsWindow.show()
            }
            guard !offer.shouldHoldInitialLoad else { return }
            startupResolved = true
            switcher.select(settings.current.model)
            if !onboardingShown {
                onboardingShown = true
                OnboardingWindow.startIfNeeded(store: settings, menuBar: menuBar)
            }
        }
        menuBar.setHotkeyHealth(.modelLoading)
        Task { @MainActor in
            if AppLaunch.isApp {
                // An offer must not interrupt an existing usable setup. Its
                // selected cache can warm offline while discovery runs.
                if let id = settings.current.model.id, let configured = ModelRegistry.find(id),
                   TranscriberFactory.isCached(configured, settings: settings.current.model) {
                    switcher.select(settings.current.model)
                }
                await offer.inspectAutomatically()
                initialDiscovery = false
                // A prior decision suppresses discovery and therefore emits no callback.
                if !offer.shouldHoldInitialLoad, !startupResolved {
                    switcher.select(settings.current.model)
                    if !onboardingShown {
                        onboardingShown = true
                        OnboardingWindow.startIfNeeded(store: settings, menuBar: menuBar)
                    }
                }
                if ModelLoadStatus.shared.current?.phase == .needsDownload,
                   offer.status == .notFound { settingsWindow.show() }
            } else {
                // A foreground CLI invocation is explicit; keep its existing
                // model-download behavior. Native first launch requires a button.
                switcher.select(modelSettings, allowDownload: true)
            }
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            Log.info("\nshutting down")
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        Log.info("model: \(model.id) · inject: \(options.injectMode.rawValue) · ^C to quit")
        app.run()
    }

    /// Starts the hotkey tap, or, without an Accessibility grant, asks for one
    /// and waits. The grant belongs to this binary, not the terminal that ran
    /// `parrot setup`, so the launch-at-login daemon has to ask for itself.
    /// It asks once per launch and keeps running: exiting would make launchd
    /// relaunch it and re-fire the prompt. Polling picks up the grant, so no
    /// restart is needed.
    @MainActor
    private static func startHotkey(
        _ monitor: HotkeyMonitor,
        menuBar: MenuBarController,
        onEvent: @escaping @MainActor (HotkeyMonitor.Event) -> Void
    ) throws {
        func start() throws {
            do {
                // HotkeyMonitor delivers events on the main queue.
                try monitor.start { event in
                    MainActor.assumeIsolated { onEvent(event) }
                }
            } catch {
                throw StartupFailure.hotkeyUnavailable(error)
            }
            menuBar.setHotkeyHealth(.ok)
            Log.info("listening on \(monitor.key.shortName) hold")
        }

        if AXIsProcessTrusted() {
            try start()
            return
        }

        Log.info("accessibility not granted; waiting (System Settings → Privacy & Security → Accessibility → parrot)")
        menuBar.setHotkeyHealth(.accessibilityMissing)
        // Parrot.app leaves the prompt to the onboarding window's Allow (#51).
        if !AppLaunch.isApp {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                Log.info("accessibility granted")
                do {
                    try start()
                } catch {
                    Log.error(StartupFailure.hotkeyUnavailable(error).message)
                    menuBar.setHotkeyHealth(.tapDisabled)
                }
            }
        }
    }
}
