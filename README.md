# Jotto

Jotto turns your Apple Watch into a recorder that's always ready. Tap the dot on your wrist; your iPhone turns what it hears into clean, titled transcripts you can search, highlight and send on. There is no account and no server: transcription runs on the iPhone, with Apple's speech models or Qwen3-ASR. If you'd rather use a cloud model, bring your own API key (OpenRouter or any OpenAI-compatible service), and recordings go straight from your phone to that service.

Jotto is free. This repository is its full source.

## Build

You need a Mac with Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The apps target iOS 26 and watchOS 26.

```sh
cd apple
xcodegen generate
open Jotto.xcodeproj
```

To run it on your own devices, change these in `apple/project.yml` (and the entitlements it points to) to your own:

- `DEVELOPMENT_TEAM`
- the bundle identifiers, `com.neethanwu.jotto…`
- the app group, `group.com.neethanwu.jotto`

Builds from source download Qwen3-ASR from Hugging Face when you pick it in Settings → Processing; the App Store version gets it from Apple's servers.

| Path | What |
|------|------|
| `apple/` | The iPhone app, the watch app, their widgets, Live Activity and Shortcuts |
| `apple/AssetPacks/` | How the Qwen3-ASR model is packed for the App Store |
| `brand/` | Logo, icons, colour tokens and illustrations |

## Privacy

Jotto collects nothing. See [PRIVACY.md](PRIVACY.md). For help, see [SUPPORT.md](SUPPORT.md).

## Licence

GPLv3, with an additional permission that lets Jotto be distributed through app stores. See [LICENSE](LICENSE) and [NOTICE](NOTICE), which also credits the work Jotto builds on. The Jotto name and logo aren't covered by the licence: if you publish your own version, give it its own name and icons.
