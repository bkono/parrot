import Foundation

/// Whether the hotkey tap is receiving events. Shown in the menu bar when it
/// is not.
enum HotkeyHealth: Equatable {
    case ok
    /// Re-enabling keeps failing while Secure Input is on (a password field,
    /// or Terminal's Secure Keyboard Entry).
    case secureInputActive
    /// Re-enabling keeps failing for another reason.
    case tapDisabled
    /// This process has no Accessibility grant yet; the tap cannot exist.
    case accessibilityMissing
    /// The model is loading (or downloading on first run); the tap starts after.
    case modelLoading
    /// The model failed to load; a retry is scheduled.
    case modelFailed

    /// The menu bar status line for a degraded tap, or nil when healthy.
    var statusText: String? {
        switch self {
        case .ok: return nil
        case .secureInputActive: return "hotkey unavailable, secure input active"
        case .tapDisabled: return "hotkey tap disabled"
        case .accessibilityMissing: return "grant Accessibility to start"
        case .modelLoading: return "loading model…"
        case .modelFailed: return "model unavailable; open Settings…"
        }
    }

    static func degraded(secureInput: Bool) -> HotkeyHealth {
        secureInput ? .secureInputActive : .tapDisabled
    }
}

/// When to re-enable a disabled event tap. Pure, so the schedule is tested.
///
/// The first disable is re-enabled at once. A re-enable that fails, or that
/// macOS undoes within `stableInterval`, counts as a failure, and the next
/// attempt waits 1 s, doubling to 30 s. A tap that stays enabled for
/// `stableInterval` starts over from an immediate re-enable.
struct TapRecovery {
    static let firstDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 30
    static let stableInterval: TimeInterval = 10

    /// Consecutive re-enables that did not stick.
    private(set) var failures = 0
    /// When the last re-enable took, if it has not been undone since.
    private var enabledAt: Date?

    /// Seconds to wait before the next attempt after `failures` failures.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 16))
        return min(firstDelay * pow(2, exponent), maxDelay)
    }

    /// The tap was found disabled. Returns seconds to wait before re-enabling.
    mutating func disabled(at now: Date) -> TimeInterval {
        if let enabledAt, now.timeIntervalSince(enabledAt) < Self.stableInterval {
            failures += 1
        } else {
            failures = 0
        }
        enabledAt = nil
        return Self.delay(afterFailures: failures)
    }

    /// `tapEnable` did not take. Returns seconds to wait before the next try.
    mutating func enableFailed() -> TimeInterval {
        failures += 1
        enabledAt = nil
        return Self.delay(afterFailures: failures)
    }

    /// `tapEnable` took and `tapIsEnabled` confirmed it.
    mutating func enabled(at now: Date) {
        enabledAt = now
    }
}
