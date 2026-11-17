# Third-party notices

[中文](THIRD_PARTY_NOTICES.zh-CN.md)

Piyi's own code is released under the MIT License (see `LICENSE`). The items below were not written for Piyi and are each under their own license.

## Code bundled in the app

| Name | Used for | License |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | Library storage | MIT |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | Running the embedding model locally | MIT |
| [Readability.js](https://github.com/mozilla/readability) | Extracting article text from web pages | Apache 2.0; full text in `Sources/Library/Resources/Readability-LICENSE.md` |

## Used but not shipped with the app

| Name | How it's used | License |
|---|---|---|
| [Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF) | Downloaded by the user in Settings, for searching by meaning | Apache 2.0 |
| Cloud models | Used only after the user picks a provider and enters a key in Settings; subject to that provider's and each model's own terms | — |

## Material on the sample board

Everything placed on the "Sample" board for new installs was chosen to be freely usable:

- **Paintings** (the 29 files in `images/` named after their painters): open-access collections of the [Art Institute of Chicago](https://www.artic.edu/open-access/open-access-images), [The Metropolitan Museum of Art](https://www.metmuseum.org/policies/image-resources), and the [Cleveland Museum of Art](https://www.clevelandart.org/open-access), marked by the museums as public domain or CC0 (all rights waived, free to use for any purpose); all the painters died before 1955. Each card links to the work's page
- **Wikipedia page screenshots** (`files/wikipedia-collage-long-screenshot.jpg`, `images/link-wabi-sabi.jpg`): content from Wikipedia, used under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); the source is the original URL on the card
- **American Look (1958)** (`files/american-look-1958.mp4`): a promotional film made by Jam Handy for General Motors, held in the Internet Archive's [Prelinger Archives](https://archive.org/details/American1958), public domain
- **The Horse in Motion (1878)** (`files/horse-in-motion.gif`): Eadweard Muybridge's sequential photographs of a galloping horse, public domain
- **Satie, Gymnopédie No. 1** (`files/gymnopedie-1.mp3`): performed by Robin Alciatore, released into the public domain through [Musopen](https://musopen.org), from [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Erik_Satie_-_gymnopedies_-_la_1_ere._lent_et_douloureux.ogg)
- **Excerpt from The Book of Tea** (`files/茶之书-论虚空.md`, English version `files/the-book-of-tea-on-the-vacuum.md`): Okakura Kakuzō's 1906 English original, public domain, from [Project Gutenberg](https://www.gutenberg.org/ebooks/769); the Chinese translation is Piyi's own
- **Quotes**: from classical texts and public-domain works; the Chinese and English of the two quotes by Klee and Kandinsky, and the English of the quotes by Wang Wei, Wang Yangming, and Zhuangzi, are Piyi's own translations
- **Other files** (`关于拼贴.md`, `卡片画布的交互原则.docx`, `颜色笔记-灰调里的绿.pdf`, and their English versions): written for Piyi, under MIT
- **Link cards** (YouTube, Bilibili, the Stanford Encyclopedia of Philosophy, and others): only the URL is stored; content is fetched from the original site when opened and is not shipped with the app
