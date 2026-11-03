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
Apple Silicon; Parakeet Redux requires macOS 15+. Do the import before launching
the app for the first time, so it does not start downloading its default model.

```sh
swift build -c release
.build/release/parrot import-muesli
.build/release/parrot import-muesli --write
.build/release/parrot doctor
scripts/dev-install.sh
```

If Parrot already has a model selected, preview with `import-muesli --replace`,
then apply with `import-muesli --replace --write`. The original settings are saved
as a private `settings.json.backup-<UUID>` beside the settings file. Other settings,
including unknown fields, survive import. Symlinked dotfiles keep their links.
An invalid configuration is rejected instead of reset. Import never copies
Muesli's provider credentials or transcripts.

The default source is `~/Library/Application Support/Muesli/config.json`. For a
development install or another config location, pass `--config /path/config.json`.
The selected `stt_backend` and `stt_model` must be supported and fully downloaded;
unsupported or missing models stop the import with no fallback or download.

Quit Muesli before starting Parrot to avoid competing hotkeys. Open the installed
Parrot app and grant its Microphone and Accessibility permissions. If reusing
Whisper assets under Documents, allow Parrot's Documents-folder access when macOS
asks; a terminal's access does not transfer to the app. Materialize iCloud-evicted
files in Finder first. Keep the shared model files if uninstalling Muesli.

`scripts/dev-install.sh` builds and signs a local app. With no Developer ID it uses
ad-hoc signing, so permission grants may need renewal after rebuilds. Development
versions do not enable upstream automatic updates. These PR changes are not
included in the upstream DMG or curl installer linked in the general README.

For meeting notes, follow the companion Quill branch's matching commands:
`quill import-muesli` followed by `quill import-muesli --write` (with `--replace`
when replacing existing settings). Quill imports the separate meeting model and
local Ollama configuration. Parrot never sends dictation to Ollama.

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
missing imported files, and retirement of superseded transcribers. Existing
capture, gesture, delivery, and controller regressions remain in the full suite.
Real model inference, microphone permissions, and hotkey behavior must still be
checked on the work laptop; no large models are downloaded for these tests.

## Handoff

- **Decision:** reuse exact selected assets in place; keep meeting summaries in
  Quill. There is no new capture pipeline or completion policy.
- **Closed doors:** do not restore automatic movement of the shared Documents
  cache, automatic replacement of unsupported models, or tokenizer HTTP fallback
  for imported models.
- **Invariant:** failure leaves Muesli's assets untouched and preserves the active
  transcriber during a runtime model change.
- **Deprecated:** the old `migrateLegacyModels` move helper was removed; import
  provides explicit reuse instead.
- **Next check:** install this fork on the work laptop, verify the selected model,
  grant app permissions, and test a short dictation before replacing daily use.
