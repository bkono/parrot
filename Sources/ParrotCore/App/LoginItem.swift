import AppKit
import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`: macOS starts Parrot.app
/// itself at login and lists it under System Settings → General → Login
/// Items. Needs the signed bundle; a bare `swift build` binary has none.
///
/// Behind `parrot install --launch-at-login`, `parrot install --uninstall`,
/// and the "Launch at login" menu item.
public enum LoginItem {
    /// Register Parrot to start at login (`parrot install --launch-at-login`),
    /// and start it now.
    public static func install() throws {
        guard let app = AppBundle.current else {
            Log.error("launch at login needs Parrot.app. Install it from the DMG, then run this again.")
            throw SilentExit(1)
        }

        if LegacyLaunchAgent.remove() {
            print("✓ removed the old LaunchAgent (\(Paths.legacyLaunchAgentLabel))")
        }

        do {
            try SMAppService.mainApp.register()
        } catch {
            Log.error("couldn't register the login item: \(error)")
            throw SilentExit(1)
        }

        switch SMAppService.mainApp.status {
        case .requiresApproval:
            print("! launch at login needs your approval")
            print("  System Settings → General → Login Items → allow Parrot")
            SMAppService.openSystemSettingsLoginItems()
        default:
            print("✓ launch at login on")
        }
        print("  app:  \(app.path)")
        print("  logs: \(Paths.logs.path)/")

        // The old agent started the daemon right away; so does this. A
        // second copy exits at once on the instance lock.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [app.path]
        try? open.run()
        open.waitUntilExit()
    }

    /// Remove launch at login, quit the app, and delete logs and caches
    /// (`parrot install --uninstall`). Config and models stay.
    public static func uninstall() throws {
        if AppBundle.current != nil, SMAppService.mainApp.status != .notRegistered {
            do {
                try SMAppService.mainApp.unregister()
                print("✓ launch at login off")
            } catch {
                Log.warning("couldn't unregister the login item: \(error)")
            }
        } else {
            print("launch at login was not on")
        }
        if LegacyLaunchAgent.remove() {
            print("✓ removed the old LaunchAgent (\(Paths.legacyLaunchAgentLabel))")
        }
        LegacyLaunchAgent.removeTmpFiles()

        let me = ProcessInfo.processInfo.processIdentifier
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: AppBundle.identifier)
        where running.processIdentifier != me {
            running.terminate()
            print("  quit Parrot (pid \(running.processIdentifier))")
        }

        for dir in [Paths.logs, Paths.caches] where Paths.fileType(dir.path) != nil {
            try FileManager.default.removeItem(at: dir)
            print("  removed \(dir.path)")
        }
    }

    /// Whether the menu item can work: only inside Parrot.app.
    static var isAvailable: Bool { AppBundle.current != nil }

    /// On, or waiting for approval in System Settings.
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// Turns launch at login on or off from the menu.
    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// The hand-written LaunchAgent that pre-app versions installed, which
/// `SMAppService` replaced. Removing it stops the old daemon and keeps it
/// from coming back at the next login. Models, config, and logs stay.
enum LegacyLaunchAgent {
    /// Boots out the agent and deletes its plist. Returns whether there was
    /// an agent to remove.
    ///
    /// `launchctl` is injected so tests never touch the real launchd domain.
    @discardableResult
    static func remove(
        plist: URL = Paths.legacyLaunchAgentPlist,
        label: String = Paths.legacyLaunchAgentLabel,
        launchctl: ([String]) -> Int32 = runLaunchctl
    ) -> Bool {
        let service = "gui/\(getuid())/\(label)"
        let hasPlist = Paths.fileType(plist.path) != nil
        let isLoaded = launchctl(["print", service]) == 0
        guard hasPlist || isLoaded else { return false }

        if isLoaded {
            // Stops the old daemon. By service target, so it works even if
            // the plist on disk no longer matches what launchd loaded.
            let status = launchctl(["bootout", service])
            if status != 0 {
                Log.warning("launchctl bootout \(service) exited \(status)")
            }
        }
        if hasPlist {
            do {
                try FileManager.default.removeItem(at: plist)
            } catch {
                Log.warning("couldn't remove \(plist.path): \(error)")
            }
        }
        Log.info("removed the old LaunchAgent \(label)")
        return true
    }

    /// Deletes the pre-0.0.6 /tmp logs and capture. They hold the user's
    /// transcripts; only touch files this user owns.
    static func removeTmpFiles() {
        for path in Paths.legacyTmpFiles {
            guard
                let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
                Log.info("removed \(path)")
            } catch {
                Log.warning("couldn't remove \(path): \(error)")
            }
        }
    }

    static func runLaunchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return -1
        }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
