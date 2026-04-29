# SwiftDict

A minimalist macOS English-Chinese dictionary app born from pure vibe coding — it lives in your menu bar, summons with a single keystroke, and gets out of your way the moment you're done.

[中文说明 →](README_CN.md)

## Why

I wanted a dictionary that imposes zero friction. No Dock icon, no window hunting, no extra clicks. Press a key, look up a word, done. SwiftDict is that tool, built for myself and shared as open source.

## Shortcuts

| Key | Context | Action |
|---|---|---|
| **Right Command** | Anywhere | Toggle dictionary window |
| **Right Option** | Window visible | Focus search field |
| **Enter** | Search field focused | Look up current input |
| **Cmd+V** | Search field focused | Paste clipborad, clean it, look up |
| **`[`** | Window focused | Go back in query history |
| **`]`** | Window focused | Go forward in query history |
| **`↓`** | Search field focused | Expand next result section |
| **`↑`** | Search field focused | Collapse last result section |
| **Esc** | Window focused | Hide dictionary window |

That's it. No learning curve.

## Features

- **Global hotkey** — Press Right Command from any app to summon or dismiss the window.
- **Paste-and-search** — `Cmd+V` with the search field focused auto-cleans clipboard text and looks it up. Works with `"don't"`, `"self-made"`, and multi-word phrases.
- **Cached offline** — Lookups hit a local SQLite database first. Previously seen words load instantly with zero network.
- **Audio pronunciation** — Auto-plays British pronunciation on each lookup. Click the speaker icon to replay.
- **Word history** — `[` and `]` navigate your recent queries like a browser's back/forward. Up to 100 entries.
- **Related words & synonyms** — Optional sections below definitions showing other POS forms and synonyms (toggle in settings or with `↓`/`↑`).
- **Spelling suggestions** — Misspelled words show clickable corrections.
- **Auto fade-out** — The window fades after 10 seconds of inactivity. Disable in settings.
- **Menu bar only** — No Dock icon, no Cmd+Tab entry. Right-click the book icon for About / Settings / Quit.

## Settings

Open from the menu bar (right-click icon → 配置, or `Cmd+,`):

| Setting | Default | Description |
|---|---|---|
| Auto fade-out | On | Window disappears after 10s idle |
| Show other POS forms | Off | Display related words (verb / noun / adv. forms) |
| Show synonyms | Off | Display synonyms grouped by POS |

The database section shows cached word count and file size. The logs section lists log file paths and sizes.

## Install

### Download

Get the latest DMG from [Releases](https://github.com/gaoxiaoliang/swift-dictionary/releases). Open it, drag `SwiftDict.app` to `/Applications`.

### Accessibility Permission

Grant accessibility permission when prompted (System Settings → Privacy & Security → Accessibility). Required for the Right Command global hotkey.

### Build from source

```sh
git clone https://github.com/gaoxiaoliang/swift-dictionary.git
cd swift-dictionary
make install    # build .app, replace /Applications/SwiftDict.app
```

Requires macOS 12+, Swift 5.7+, no third-party dependencies.

## Data footprint

| Path | Content |
|---|---|
| `~/Library/Application Support/SwiftDict/dictionary.db` | SQLite cache (words, audio BLOBs) |
| `~/Library/Logs/SwiftDict/SwiftDict-YYYY-MM-DD.log` | Logs (daily rotation, auto-pruned) |
| `~/Library/Preferences/com.xiaoliang.SwiftDict.plist` | UserDefaults |

## License

MIT
