# Personal AI

A private AI for your Mac in one download. Personal AI is a menu bar app that bundles
[Ollama](https://ollama.com) (MIT), picks the best model this Mac can run from a list of
tested models, downloads it, and serves it on `127.0.0.1:11434`. Any app that works with
Ollama or the OpenAI API connects to it with no setup, and nothing you type leaves the Mac.

```
 download .dmg ─▶ open app ─▶ reads RAM/chip ─▶ picks model ─▶ pulls it ─▶ apps use it
                                   │
                    Resources/models.json (tested list)
```

## Download

Get the latest `PersonalAI.dmg` from the
[Releases page](../../releases/latest), open it and drag **Personal AI** to Applications.
The app is signed with a Developer ID and notarized by Apple, so it opens without a warning.

On first launch a brain icon appears in the menu bar and the model starts downloading
(1 to 22 GB depending on the Mac). Once it says **Ready**, point any Ollama-compatible app at `http://127.0.0.1:11434`
(or `http://127.0.0.1:11434/v1` for apps that expect the OpenAI API).
Turn on **Open at login** in the menu so it is there after a restart.

Requires a Mac with Apple silicon (M1 or later) and macOS 14 or later. Intel Macs are not supported.

## How it behaves

- Only listens on 127.0.0.1. Nothing leaves the Mac except the one-time model download.
- Ollama loads the model on the first request and unloads it after 5 min idle, so RAM is only used while you write.
- When macOS reports memory pressure (warning or critical), the app unloads the model immediately.
- If the user already runs Ollama on 11434, the app reuses it instead of starting a second one.
- The app is about 55 MB. Ollama's MLX engine is not bundled: when the chosen model runs on MLX,
  the app downloads the one build that Mac needs (74 MB on macOS 26, 52 MB before) from the
  GitHub release, checks its SHA-256 and runs Ollama from `~/Library/Application Support/PersonalAI/runtime`.
- Models live in `~/Library/Application Support/PersonalAI/models`.
- A `models.json` dropped in that folder overrides the bundled list.

## Model catalog

The best-ranked model whose `minRAMGB` fits the Mac (and that leaves 2 GB of disk free) wins.

| RAM | Model | Tested |
|-----|-------|--------|
| 32 GB+ | qwen3.6:35b-mlx | yes, M5 32 GB (best in hand testing) |
| 16 GB+ | qwen3.5:9b | yes, M5 32 GB: 20 tok/s |
| 8 GB+ | gemma3:4b | no |
| 4 GB+ | gemma3:1b | no |

`qwen3:30b-a3b` is also in the list (52 tok/s on the M5) but ranks below the 35B.
Benchmark on other Macs with `scripts/bench.sh [model ...]` before marking a tier as tested.

## Build

```bash
scripts/build-app.sh          # ad-hoc signed, for local testing only
```

## Release

1. One time: import the Developer ID certificate (`scripts/import-devid.sh <file.cer>`).
2. Tag, build, notarize:

```bash
git tag v0.1.0
export ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=…/AuthKey_….p8
SIGN_IDENTITY="Developer ID Application: RailsSquad OU (VLZY44ZX2X)" NOTARIZE=1 scripts/build-app.sh
gh release create v0.1.0 build/PersonalAI.dmg build/mlx/mlx_metal_v3.zip build/mlx/mlx_metal_v4.zip \
  --title "Personal AI 0.1.0" --notes "…"
```

The version comes from the latest git tag (or `VERSION=`). The MLX zips must be attached to the
same release, because the app downloads them from that tag's URLs. The App Store isn't an option because the app
runs a bundled server binary.

## License

MIT. See [LICENSE](LICENSE). The bundled Ollama is also MIT licensed.
