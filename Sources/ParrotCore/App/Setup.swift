import ApplicationServices
import AVFoundation
import Foundation

/// First-run permission setup (`parrot setup`). The only place Parrot shows
/// the system permission prompts.
public enum SetupFlow {
    public static func run() throws {
        print("parrot setup")
        print("============")
        print()
        print("Parrot needs two permissions:")
        print("  1. Accessibility — to detect the Fn key globally and inject text at the cursor.")
        print("  2. Microphone — to record audio while you hold Fn.")
        print()
        print("Granted here, they attach to your terminal app (Terminal/iTerm/Ghostty/etc.),")
        print("which covers running `parrot` from this terminal. The launch-at-login daemon")
        print("asks for its own on first start: allow Parrot when macOS prompts.")
        print()

        try waitForAccessibility()
        print()
        try waitForMicrophone()
        print()
        print("✓ all set. Run `parrot` to start the daemon.")
    }

    private static func waitForAccessibility() throws {
        if AXIsProcessTrusted() {
            print("✓ accessibility already granted")
            return
        }

        print("→ opening accessibility prompt...")
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        print()
        print("  1. Toggle your terminal on in the Accessibility list.")
        print("  2. Re-run `parrot setup` — macOS only picks up the grant on a fresh process.")
        throw SilentExit(0)
    }

    private static func waitForMicrophone() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            print("✓ microphone already granted")
            return
        case .denied, .restricted:
            print("✗ microphone is denied — macOS won't re-prompt once denied.")
            print("  opening Settings → Privacy & Security → Microphone...")
            openSettings("Privacy_Microphone")
            print("  enable your terminal, then re-run `parrot setup`.")
            throw SilentExit(1)
        case .notDetermined:
            print("→ requesting microphone access...")
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if granted {
                print("  ✓ microphone granted")
            } else {
                print("  ✗ microphone denied")
                throw SilentExit(1)
            }
        @unknown default:
            print("? microphone in unknown state")
        }
    }

    private static func openSettings(_ pane: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url]
        try? task.run()
    }
}
