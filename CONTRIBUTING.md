# Contributing

[中文](CONTRIBUTING.zh-CN.md)

## Building from source

Requirements: macOS 26 or later, the Xcode 26 Command Line Tools (with the Swift 6 toolchain), and Node.js (for the browser extension). The full Xcode is optional: with it, actool compiles the app icon into the glass version; without it, `scripts/flat_icon.swift` stacks the same layers into a plain AppIcon.icns. After changing the icon, check both.

```sh
./scripts/build_app.sh             # release build, produces build/Piyi.app
swift build && swift run Piyi   # debug build (build first so the extension relay is compiled too)
swift test                         # automated tests
```

The library lives in `~/Library/Application Support/Piyi/`. Set the environment variable `PIYI_ROOT=<directory>` at launch to use a different library directory, for example to try the first launch of a fresh install.

## Models

- **Generation and judgment**: calls the cloud provider the user picks in Settings. The provider list and each provider's default models are in `Intelligence/Models/Vendor.swift`; Anthropic uses its own API (`Claude.swift`), the others use the OpenAI-compatible API (`Cloud.swift`). Titles, descriptions, key points, inspiration, and answers use a general-purpose model; judgments (login page or article body, what a sentence is asking for) can use a separate, faster model. With OpenRouter, judgments go by default to a model built for judging that returns the probability of each option directly (`Jev.swift`), twice as fast as having a general model write an answer. Automatic sorting works only with Jev: the threshold for placing a card on a board is set against its probabilities, and confidence reported by other models can't be compared against the same threshold.
- **Search embeddings**: Qwen3-Embedding-0.6B, run locally with llama.cpp; the user downloads it in Settings.
- **Transcription**: the system's built-in speech recognition, run locally. Chinese and English models listen at the same time, and the more confident result is kept.

All model calls go through a single gateway, `Intelligence/Models/Gateway.swift`.

## Code layout

| Module | Responsible for | May call |
|---|---|---|
| `Library` | Library storage, content extraction | none |
| `Intelligence` | Model access, understanding, search, inspiration, sorting, discussion | `Library` |
| `Canvas` | Canvas, card rendering | `Library`, `Tokens` |
| `Piyi` | The app: interface shell, collection entry points, detail view | all of the above |
| `Tokens` | Design values: spacing, animation durations, colors, font sizes — numbers only | none |
| `Wire` | Message format and connections between the app, the extension relay, and the extension | none |

There are two separate programs as well: the extension relay `PiyiRelay` (launched by the browser, uses only `Wire`), and the browser extension itself in `Extension/` (TypeScript, bundled with `npm run build`; the release build script does this automatically).

`Package.swift` declares the dependencies in the table above, so the compiler blocks calls in the other direction. Three deliberate arrangements:

- **Canvas and Intelligence can't see each other.** Search returns a list of card IDs, and the app hands them to the canvas to gather.
- **Extraction needs models, but `Library` can't call `Intelligence`.** `Library` declares only the capabilities it needs (telling whether a fetched page is a login page, falling back to a model when fetching fails, transcribing audio and video), and the app passes in the `Intelligence` implementations at launch. Whenever a capability is needed in the other direction, do the same: declare a protocol in the lower module and have the app inject the implementation.
- **Design values are a separate module that holds only numbers.** The canvas draws cards with Core Animation and the rest of the interface uses SwiftUI; both share the same values.

**Collecting** is coordinated by the app's `Collector`, which calls the modules in this order:

1. If it's a URL, check for duplicates by URL first.
2. The canvas finds a free spot for a placeholder card near the drop point, `Library` writes the placeholder, and the card appears right away.
3. `Library` extracts the content, checks for duplicates by content fingerprint, and stores the files.
4. Final sizes are set from the extracted content, and the placements in the batch are written at once.
5. The cards join the understanding queue.

## Coding rules

- **No real controls per card on the canvas.** A card is normally a pre-drawn layer; only the card whose text is being edited temporarily gets a text field on top. Hover and selection change only that card's border.
- **The main thread does interface work only.** Decoding images, drawing card bitmaps, database reads and writes, computing embeddings, and calling models all happen in the background. Work for what's about to appear in view uses `.userInitiated`; embeddings, model calls, and thumbnails use `.utility`.
- **Write tests where logic is easy to get wrong and can't be judged by eye**: database operations, duplicate checks, grid snapping, query parsing, extractor output. Use Swift Testing.

## Interface language

The interface is in Chinese when the system language is Chinese, and in English otherwise. Code holds the Chinese source text; English translations are in `Localization/en.lproj/`:

- Text written directly in SwiftUI (`Text`, `Button`, `Label`, `.help`, …) is translated automatically; any other user-facing text is written as `String(localized: "…")`.
- When the same Chinese phrase needs different English in different places, use `String(localized: "key", defaultValue: "中文")`.
- Sentences with counts that need singular and plural forms go in `Localizable.stringsdict` (both Chinese and English entries are required, or the Chinese interface falls back to English).
- Chinese names stored in data and used by code as identifiers (formats and platforms, such as 公众号, shown as "WeChat") are not translated in the data; use `displayed(_:)` when showing them.
- AI-written titles, descriptions, and answers follow the interface language (`Intelligence/Writing.swift`); the prompts themselves stay in Chinese.
- The browser extension's text is in `Extension/static/_locales/`.

After adding interface text, run this to list anything untranslated:

```sh
python3 scripts/check_strings.py
```

The debug build (`swift run`) isn't a bundled app, so its interface always shows the Chinese from the code. To see English, bundle with `./scripts/build_app.sh` and launch with `-AppleLanguages "(en)"`.

## Checks that use the network or real models

The regular `swift test` doesn't go online or call models. Turn these on manually:

```sh
OPENROUTER_API_KEY=… swift test --filter RealCloud   # understand an image with a real cloud model to confirm the request format still works
SUBTITLE_CHECK=1 swift test --filter SubtitleCheck    # fetch a YouTube video's subtitles; fails first when the platform changes
SPEECH_CHECK=1 swift test --filter SpeechLanguage     # speak a Chinese and an English passage with system text-to-speech and check that transcription follows the audio's language
```

## Sample board

The material placed on the "Sample" board for new installs is in `Sources/Piyi/Resources/Seed/`, listed in `manifest.json`. Each item can carry a position, size, and rotation; quotes and Chinese files also carry an English version (`en`) that's swapped in when the interface isn't Chinese. To rearrange it, lay out the sample board in the app, then run

```sh
python3 scripts/seed_export.py "Board name"
```

to write the positions back to the manifest.

The sample cards' titles, descriptions, tags, and key points are also generated in advance and shipped with the app, so new users see complete cards without entering an API key. After changing the material, regenerate them: with a fresh library and an API key, open the bundled app once with the Chinese interface and once with the English one, wait until all sample cards are understood, then write both results back to the manifest:

```sh
PIYI_ROOT=/tmp/seed-zh OPENROUTER_API_KEY=… build/Piyi.app/Contents/MacOS/Piyi -AppleLanguages "(zh-Hans)"
PIYI_ROOT=/tmp/seed-en OPENROUTER_API_KEY=… build/Piyi.app/Contents/MacOS/Piyi -AppleLanguages "(en)"
python3 scripts/seed_understood.py /tmp/seed-zh/library.sqlite zh
python3 scripts/seed_understood.py /tmp/seed-en/library.sqlite en
```

Licenses for the material are in `THIRD_PARTY_NOTICES.md`. Any new material must be freely redistributable with the app.
