# Switching from Muesli

This fork reuses Muesli's downloaded dictation model without moving, copying,
repairing, or deleting the shared files. Capture, hotkey release, trimming,
completion, clipboard delivery, and dictionary replacements keep Parrot's existing
behavior. Quill handles meeting recordings and Ollama meeting notes separately.
This work starts from the newly created fork; unpublished work-laptop changes are
not included and must be ported separately before comparing their completion
behavior with this build.

## Work-laptop setup

Build this branch with Xcode's Swift 6 toolchain. Runtime requires macOS 14+ on
Apple Silicon; Parakeet Redux requires macOS 15+.

```sh
scripts/dev-install.sh
```

Quit Muesli to avoid competing hotkeys, then open the installed Parrot app. On its
first launch, Parrot checks Muesli's local setup before any default model download
and offers the selected dictation model in Settings. Review the model and exact
folders, then choose **Use This Model**, **Keep My Selection**, or **Not Now**.
Closing the window also remembers dismissal. Parrot records the offer and decision
beside its settings in `muesli-import.json`; ordinary relaunches do not ask again.
An existing cached Parrot model can continue loading while the offer is visible.

Accepting saves Parrot's own configuration and applies the model once dictation is
idle. If a model was already selected, the preview explains the replacement.
Existing settings are backed up as a private `settings.json.backup-<UUID>`, and
unrelated settings, unknown fields, and symlinked dotfiles are preserved. Import
never copies provider credentials or transcripts. If a new model cannot load,
the previous loaded model stays active.

Settings shows the **In use** model and backend separately from a pending
**Selected** model, Parrot's own settings path, model/tokenizer paths, and whether
the assets are Parrot-managed or in an external shared cache. Imported preferences
belong to Parrot; it does not follow subsequent Muesli setting changes. Shared
FluidAudio and Hugging Face folders are not owned by Muesli. Removing Muesli.app
alone does not remove them; deleting those caches, including with a cleanup tool,
will break a saved selection. Use the Reveal buttons to locate them.

Use **Review Muesli Setup…** to explicitly retry after any saved decision, absence,
or error. The default source is `~/Library/Application Support/Muesli/config.json`;
when absent, Parrot also checks `MuesliDev/config.json`. **Choose Muesli Config…**
opens a file picker for other locations and remembers the chosen source for retries.
Unsupported or incomplete models report an error without fallback or download.
Settings offers **Choose Another Cached Model…** and **Retry Selected Model** for
recovery. Downloading a missing Parrot-managed Whisper model requires the explicit
**Download** button. No native app startup or imported model silently downloads.

Grant Microphone and Accessibility permissions for dictation. If reusing Whisper
assets under Documents, allow Parrot's Documents-folder access when macOS asks;
a terminal's access does not transfer to the app. Materialize iCloud-evicted files
in Finder first.

`scripts/dev-install.sh` builds and signs a local app. With no Developer ID it uses
ad-hoc signing, so permission grants may need renewal after rebuilds. Development
versions do not enable upstream automatic updates. These PR changes are not
included in the upstream DMG or curl installer linked in the general README.

The companion [Quill PR](https://github.com/bkono/quill/pull/2) provides its own
first-launch offer for the separate meeting model and local Ollama configuration.
Parrot never sends dictation to Ollama.

### Optional CLI diagnostics and import

The command-line flow remains available for scripts and troubleshooting:

```sh
.build/release/parrot import-muesli
.build/release/parrot import-muesli --write
.build/release/parrot doctor
```

If Parrot already has a model selected, preview with `import-muesli --replace`,
then apply with `import-muesli --replace --write`. Use `--config /path/config.json`
for another source. CLI acceptance also records the decision so the app will not
prompt again. `doctor` checks assets without loading or downloading them.

## Compatible assets

| Parrot model ID | Muesli asset |
|---|---|
| `parakeet-v2` | FluidInference Parakeet TDT v2 Core ML |
| `parakeet-v3` | FluidInference Parakeet TDT v3 Core ML |
| `parakeet-redux` | FluidInference Parakeet Redux Core ML, CPU encoder |
| `parakeet-unified` | FluidInference Parakeet Unified offline int8 Core ML |
| `whisper-tiny`, `whisper-tiny.en` | WhisperKit Tiny multilingual / English |
| `whisper-small`, `whisper-small.en` | WhisperKit Small multilingual / English |
| `whisper-medium.en` | WhisperKit Medium English |
| `whisper-large-v3-turbo-626mb` | WhisperKit `large-v3-v20240930_626MB` |

The existing `whisper-large-v3-turbo` remains the original, larger variant. The
compressed Muesli variant has a separate ID. GGML/GGUF, MLX, streaming EOU,
SenseVoice, Qwen ASR, and other engines are not interchangeable with these models.

Parakeet caches are under `~/Library/Application Support/FluidAudio/Models`.
WhisperKit caches are under
`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`; tokenizer files are
usually under `~/Documents/huggingface/models/openai/whisper-<family>`. Both the
compiled model bundles and tokenizer must exist. Imported Whisper loading injects
the local tokenizer explicitly to avoid WhisperKit's network fallback.

`parrot models list` shows compatible IDs and complete shared caches.
`parrot --model parakeet-v3` explicitly chooses that shared cache for one run.
Parakeet entries never download; the Settings picker retains the current working
model if a newly selected cache cannot load. `parrot doctor` validates the saved
selection without loading models, downloading assets, or recording audio.

The import records `model.id`, `model.modelFolder`, and (for Whisper)
`model.tokenizerFolder` in `~/.config/parrot/settings.json`. A missing imported
folder remains an error; it cannot silently switch to a downloaded default.
Selecting another model clears stale paths from the prior selection. A CLI
override checks its own effective model rather than the unavailable saved one.

Parakeet v2 and Unified are English-only. v3 and Redux support 25 languages and
accept a script hint; they do not implement Whisper's constrained language
detection or example-sentence prompting. Dictionary text replacements still run.
Onboarding preserves imported selections rather than selecting another model
because the Mac has additional preferred languages.

## Implementation and verification

Model layouts and config keys were verified against
[Muesli's managed model plans](https://github.com/Muesli-HQ/muesli/blob/5a94fa0f20fe712617124f561e476e227322586d/native/MuesliNative/Sources/MuesliCore/ManagedASRModelDownloads.swift)
and its settings implementation. FluidAudio is pinned to `0.17.3` for strict local
`AsrModels.loadLocal` and `UnifiedAsrManager.loadModels(from:)` APIs. The overloaded
download/repair APIs are deliberately excluded from imported model loading.

```sh
swift test
swift build -c release
```

Tests use temporary synthetic caches and cover configuration preservation,
backups, symlinks, incomplete assets, tokenizer protocol IDs, no fallback on
missing imported files, remembered import decisions and retries, native offer and
provenance rendering, explicit download consent, idle switching, and retirement
of superseded transcribers. Existing
capture, gesture, delivery, and controller regressions remain in the full suite.
Real model inference, microphone permissions, and hotkey behavior must still be
checked on the work laptop; no large models are downloaded for these tests.

## Handoff

- **Decision:** offer import in the native app before any default downloads,
  remember all decisions, and allow explicit retries. Reuse selected assets in
  place; keep meeting summaries in Quill. There is no new capture pipeline or completion policy.
- **Closed doors:** do not restore automatic movement of the shared Documents
  cache, automatic replacement of unsupported models, or tokenizer HTTP fallback
  for imported models.
- **Invariant:** failure leaves Muesli's assets untouched and preserves the active
  transcriber during a runtime model change.
- **Deprecated:** the old `migrateLegacyModels` move helper was removed; import
  provides explicit reuse instead.
- **Next check:** install this fork on the work laptop, verify the selected model,
  grant app permissions, and test a short dictation before replacing daily use.
