import Foundation

/// Behind `parrot models list` and `parrot models download <id>`.
public enum ModelCommands {
    public static func list() {
        // Column width follows the longest id: `padding(toLength:)` truncates
        // a longer string, and a truncated id cannot be copied into
        // `parrot models download`.
        let width = max(26, ModelRegistry.shared.map(\.id.count).max() ?? 0)
        for m in ModelRegistry.shared {
            let star = m.recommended ? "★" : " "
            let id = m.id.padding(toLength: width, withPad: " ", startingAt: 0)
            let langs = "[\(m.languages.joined(separator: ","))]"
                .padding(toLength: 9, withPad: " ", startingAt: 0)
            let size = String(format: "%5d MB", m.sizeMB)
            let source = m.engine == .parakeet ? " [reuse only]" : ""
            print("\(star) \(id) \(size)  \(langs)  \(m.displayName)\(source)")
        }
        for cached in MuesliModels.cachedCandidates() where (try? MuesliModels.validate(cached)) != nil {
            print("cached: \(cached.id) — \(cached.modelFolder.path)")
        }
    }

    public static func download(_ id: String) throws {
        guard let m = ModelRegistry.find(id) else {
            print("unknown model: \(id)")
            throw SilentExit(1)
        }
        guard m.engine == .whisperKit else {
            throw LocalModelError.unsupported("\(id) is reuse-only; download it in Muesli, then run parrot import-muesli")
        }
        let t = WhisperKitTranscriber(model: m)

        let sem = DispatchSemaphore(value: 0)
        var capturedError: Error?
        Task.detached {
            do { try await t.warmUp() } catch { capturedError = error }
            sem.signal()
        }
        sem.wait()
        if let e = capturedError { throw e }
    }
}
