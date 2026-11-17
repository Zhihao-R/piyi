# Piyi

[中文](README.zh-CN.md)

Piyi (片羽, “a fragment of a feather”) is a visual library for macOS. Web pages, images, videos, audio, and documents become cards that you arrange freely on boundless boards; to find something, describe it in a sentence and the matching cards are gathered in front of you. All data stays on your Mac. Requires macOS 26; for now it must be built from source.

![Part of the sample board: paintings by Böcklin, Friedrich, and Hammershøi alongside articles, videos, and notes](.github/images/board-en.webp)

## Collecting

| Source | How |
|---|---|
| Files and links | Drag or paste onto a board; the card lands on that board |
| Browser (Chrome, Edge, Arc) | Click the Piyi icon in the toolbar to collect the current page, or right-click a page and choose Collect to Piyi |
| Other apps | Copy, then press ⌃⌥C; or select text or files and choose Services › Collect to Piyi |
| iPhone | Share to the “Collect To Piyi” shortcut; items reach the Mac through iCloud Drive |

Items collected from the browser, other apps, or the iPhone go to Unsorted first.

Piyi extracts the content of what it collects. Web pages yield their main text, including WeChat articles, Weibo, and Xiaohongshu. Bilibili and YouTube videos come with subtitles; Bilibili subtitles require the browser extension and a Bilibili login in that browser. Audio and video files are transcribed locally, and text in images is recognized. With a cloud model connected, each card also receives a title, a one-line description, key points, and tags.

## Boards

Cards can be moved, resized, rotated, and cropped (⌘K), so size and spacing can express how a group of items relate. A card can appear on several boards (⌘C, ⌘V).

A board can have a sorting rule: right-click it in the sidebar, choose Sorting Settings…, and write a one-line description such as “references for color and type”. New cards that match are placed on that board automatically. Auto-sort currently requires OpenRouter with its default judging model, plus the local model.

## Search

Search matches by meaning, so neither a card's name nor its board needs to be remembered. Clicking into the search field shows filters for date, type, color, and more above it; All Cards can also be grouped by day, color, or source.

![Searching “quiet rooms, someone alone” brings up a Hammershøi interior, a video about him, his Wikipedia page, and Satie's Gymnopédie No. 1](.github/images/search-en.webp)

## Detail view

Double-click a card or press ⌘Y to open it. Articles open with their key points; clicking a point jumps to the passage it summarizes. Video and audio, including Bilibili and YouTube, play here with time-segmented transcripts; clicking a line plays from that moment.

![A Wikipedia article in the detail view: title, one-line description, five key points, followed by the article's images](.github/images/detail-en.webp)

## Inspire and Discuss

Inspire: click ✦ to the right of the search field. Piyi selects a few cards from the current board and states one concrete connection between them; Try Another Set makes a new selection.

![Inspire pairs Böcklin's Isle of the Dead with a hilltop landscape: both set a dark vertical mass against a lighter sky, with small figures low in the foreground](.github/images/inspire-en.webp)

Discuss: click the speech-bubble icon at the top right to open the discussion panel. Type @ to choose cards to discuss, or ask about the whole library and let the model find relevant cards. Citations appear as small gray numbers; hovering shows the quoted text and its source, and clicking opens that passage. Discussions are kept in the sidebar and archived after three days without new messages.

![A discussion with a Hammershøi interior, The Book of Tea, and Isle of the Dead, asking how each uses emptiness to create silence; the answer addresses each work with numbered citations](.github/images/discuss-en.webp)

## Installation

No prebuilt release is available yet. Building requires macOS 26 or later, the Xcode 26 Command Line Tools (`xcode-select --install`), and Node.js for the browser extension. The full Xcode is optional: with it, the app icon gets the system's glass effect; without it, the build uses a plain version of the same icon. If you have Xcode but the command line still points to the standalone Command Line Tools, run `sudo xcode-select -s /Applications/Xcode.app` first.

```sh
git clone https://github.com/Zhihao-R/piyi.git
cd piyi
./scripts/build_app.sh
```

The build produces `build/Piyi.app`; move it to the Applications folder.

## First launch

Piyi opens on a Sample board whose cards already include descriptions and key points, so it can be browsed without an API key. Setup then has four steps, each of which can be skipped and completed later in Settings:

1. Connect a cloud model: choose a provider and enter its API key. Built-in providers are OpenRouter, DeepSeek, Volcano Engine, Alibaba Cloud Model Studio, SiliconFlow, Zhipu GLM, Kimi, MiniMax, Anthropic, Gemini, and OpenAI; any other OpenAI-compatible endpoint also works. Without a cloud model, collecting and arranging still work, but new cards get no title, description, key points, or tags, auto-sort is off, and Inspire and Discuss are unavailable.
2. Download the local model (about 600 MB): search depends on it and works offline once it is downloaded.
3. Install the browser extension: load the extension bundled with the app from the browser's extensions page, as the guide shows. Piyi also uses it to open pages that require a login or load through scripts, in the background.
4. Collect from the iPhone: add the “Collect To Piyi” shortcut. The iPhone and Mac must be signed in to the same Apple Account, with iCloud Drive turned on on the Mac.

## Language

The interface is available in English and Simplified Chinese and follows the system language; it can be changed under Settings › Language. Titles, descriptions, tags, key points, and Inspire are written in the interface language, while Discuss and search questions are answered in the language of the question.

The style of AI-generated text can be adjusted under Settings › Cloud Model › Advanced, separately for titles and tags, key points, Discuss, search questions, random cards, and Inspire. Output format, source citations, and language remain fixed.

## Data and privacy

The library is stored in `~/Library/Application Support/Piyi/`, including cards, original files, thumbnails, and API keys. The local search model, transcription, and text recognition all run on the Mac.

With a cloud model connected, the following send card or page content to the chosen provider: generating titles, descriptions, key points, and tags; interpreting search queries and ranking results; auto-sort; checking whether a fetched page is the article or a login page, and extracting the text when it cannot be identified directly; Inspire and Discuss. Without a cloud model, nothing is sent.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘N | New board |
| ⌘F | Search |
| ⌘0 | Show the whole board |
| ⌘Y | Open the selected card |
| ⌘K | Crop |
| ⌘C, ⌘V | Put cards on another board |
| ⇧⌘A | Arrange the selected cards in rows |
| ⌘[ | Back |
| ⌘Z | Undo; each board has its own history |
| ⌃⌥C | Collect what was just copied, from any app |

## Contributing

Building, code layout, translation, and generation of the sample board are described in [CONTRIBUTING.md](CONTRIBUTING.md) (in Chinese).

## License

The code is released under the [MIT License](LICENSE). The artworks and texts on the sample board come from public-domain or openly licensed sources; per-item credits and the licenses of third-party code are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
