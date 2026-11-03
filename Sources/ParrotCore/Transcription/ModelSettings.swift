/// Transcription model preferences.
///
/// The `settings.json` field for this feature; see `Settings`. Give each new
/// field a default and decode it in `init(from:)` with
/// `decodeIfPresent(…) ?? default`, so older files and `{}` still load.
struct ModelSettings: Codable, Hashable {
    /// A `ModelRegistry` id, or nil for the recommended model. An id the
    /// registry doesn't know falls back to the recommended model at startup.
    var id: String?
    /// Explicit reusable assets. When set, model loading is strictly offline.
    var modelFolder: String?
    var tokenizerFolder: String?
    var importedFrom: String?

    init() {}

    /// A different model must not inherit the previous model's explicit paths.
    func selecting(_ id: String) -> ModelSettings {
        var result = self.id == id ? self : ModelSettings()
        result.id = id
        return result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        modelFolder = try c.decodeIfPresent(String.self, forKey: .modelFolder)
        tokenizerFolder = try c.decodeIfPresent(String.self, forKey: .tokenizerFolder)
        importedFrom = try c.decodeIfPresent(String.self, forKey: .importedFrom)
    }
}
