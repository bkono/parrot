<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/icon-dark.png">
    <img src="docs/assets/icon.png" width="96" alt="parrot">
  </picture>
</p>

# parrot

Hold `fn`, speak, release. Your words appear at the cursor. On-device dictation for macOS.

Already using Muesli? This fork can reuse its downloaded Parakeet or WhisperKit
models in place. See [Switching from Muesli](docs/muesli-migration.md) before the
first launch to avoid downloading Parrot's default model. Meeting summaries live
in the companion [Quill fork](https://github.com/bkono/quill).

## 1. Install

Download [Parrot.dmg](https://github.com/humanitas-labs/parrot/releases/latest/download/Parrot.dmg), drag Parrot to Applications, and open it. Turn on Parrot when macOS asks for Accessibility and the microphone. The first start downloads the speech model (about 150 MB).

Or from a terminal, which also installs the `parrot` command:

```sh
curl -fsSL https://perroquet.xyz/install.sh | sh
```

Requires macOS 14+ on Apple Silicon. Parrot is signed and notarized, so permissions survive updates, and it updates itself: it checks once a day, and **Check for Updates…** in its menu checks now. Upgrading from the command-line version: open the new app once and it replaces the old install.

## 2. Usage

1. Click into any text field.
2. Hold `fn` and speak. A small pill at the bottom of the screen shows the mic is live. On a keyboard where `fn` does nothing (Logitech and most third-party keyboards), choose another key under **Hotkey** in **Settings…**: left or right Option, Command, Control, or Shift. The change applies from the next press.
3. Release. The transcript is pasted at the cursor, usually within 200–300 ms, and your clipboard is restored.

Choose **Launch at login** in **Settings…** to start Parrot with your Mac. A tap shorter than 0.3 s, or a hold with another modifier, is ignored, so shortcuts on the hotkey still work. If `fn` is mapped to input source or emoji, `parrot doctor` shows how to fix it.

To dictate in another language, choose a multilingual model in Settings (⌘, from the menu), then either one Language or Automatic. Automatic detects which of the languages under **Languages** each dictation is in, and never picks one you haven't listed. The list starts as your Mac's languages.

## 3. Dictionary

Add your names and technical terms to `~/.config/parrot/dictionary`, a plain-text table of each word and what the model writes instead, and Parrot spells them your way. **Open Dictionary File** in Settings opens it. Edits apply on the next dictation. See [docs/dictionary.md](docs/dictionary.md).

## 4. CLI

| Command | What it does |
|---|---|
| `parrot` | Run in the foreground (^C to quit) |
| `parrot setup` | One-time permission setup |
| `parrot doctor` | Check permissions, and the `fn` key setting when the hotkey is `fn` |
| `parrot install --launch-at-login` | Start Parrot at login |
| `parrot install --cli` | Link `/usr/local/bin/parrot` to Parrot.app |
| `parrot install --uninstall` | Stop launching at login and remove logs |
| `parrot models list` | List available models |
| `parrot import-muesli` | Preview reuse of Muesli's selected dictation model |
| `parrot import-muesli --write` | Save the validated selection, backing up existing settings |
| `parrot --model whisper-large-v3-turbo` | Larger, multilingual model |
| `parrot --hotkey right-option` | Use another key for this run only; Settings… changes the saved key |
| `parrot --no-overlay` | Hide the recording pill |
| `parrot --inject-mode type-unicode` | Type instead of paste (leaves the clipboard alone) |

## 5. How it works

WhisperKit runs Whisper and FluidAudio runs cached Parakeet models locally via CoreML. AVAudioEngine captures the mic, a CGEventTap watches the hotkey, and a synthesized ⌘V pastes the result. Nothing leaves your Mac, and logs never contain what you said. See [docs/architecture.md](docs/architecture.md).

## 6. Build from source

```sh
swift build -c release && swift test
scripts/dev-install.sh      # build, sign, install Parrot.app, link the CLI
```

## 7. License

[MIT](LICENSE)
