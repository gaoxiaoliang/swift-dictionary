# AGENTS.md — SwiftDict

## Project summary

Single-file (~2800-line) macOS menu-bar English-Chinese dictionary. Written in Swift, no external dependencies beyond `-lsqlite3`. Everything lives in `main.swift`.

## Build & test

```bash
make             # debug build (binary only, DEBUG flag)
make release     # release build
make app         # release + .app bundle in build/
make install     # kill running, build .app, copy to /Applications, launch
swiftc -o /dev/null main.swift BuildInfo.swift -lsqlite3 -O   # compile check only
```

`BuildInfo.swift` is generated from `BuildInfo.swift.in` on every build — don't edit it directly.

## Architecture

`main.swift` sections in order: `AppPaths`, `AppInfo`, `AppConfig`, `Logger`, `Database`, `YoudaoAPI`, data models, `DictionaryViewController`, `EscClosablePanel`, `MainMenuBuilder`, `AppDelegate`, main entry.

- `AppDelegate` owns the window, global hotkey monitors (Right Command / Right Option), status bar item, and app lifecycle.
- `DictionaryViewController` owns all UI (search field, results, suggestions, exam badges) and keyboard event monitors.
- `Database` is a singleton. **Do not put schema migration logic in Swift.** Use `sqlite3` CLI directly against `~/Library/Application Support/SwiftDict/dictionary.db`.
- Two tables: `word_audio` (BLOB) and `word_info` (definitions, exam types, query count). Each has a `fully_cached` flag — `true` means skip network, `false` means refresh from API (with stale-cache fallback on failure).
- `YoudaoAPI` parses `https://dict.youdao.com/jsonapi?q=...&client=deskdict&dict=ec&le=eng`. Important JSON paths: `ec.word[0].trs` (definitions), `ec.exam_type` (exam labels), `rel_word.rels` (related words), `syno.synos` (synonyms).
- `LSUIElement = true` — app has no Dock icon, no Cmd+Tab entry. Requires Accessibility permission for the Right Command global hotkey (`addGlobalMonitorForEvents`).

## Release

```bash
# Commit, tag, push — CI builds universal binary + DMG and uploads to GitHub Release
git tag vX.Y.Z && git push origin master && git push origin vX.Y.Z
```

CI workflow: `.github/workflows/release.yml`. Must have `permissions: contents: write`.

## Git & GitHub

- The authenticated `gh` CLI is available — use it for release checks, workflow logs, and GitHub API tasks.
- On commit: push directly to `origin master`. If the push is rejected, stop and report the failure rather than force-pushing or retrying silently.
- Note: `git push` may fail in non-interactive shells because git cannot access the macOS Keychain for HTTPS credentials. Use SSH remote or pre-configured credential store as needed.

## Conventions

- Commit messages use a concise English summary with a `feat:` / `fix:` prefix.
- No third-party Swift packages. Compile with `swiftc` directly, not `swift package`.
- UI is all programmatic — no storyboards, no xibs.
- Local event monitors (`addLocalMonitorForEvents`) are used for paste, Esc, arrow keys, Emacs cursor keys, and suggestion navigation. Always check `isKeyWindow` and `firstResponder` before acting.
- Window height is dynamic (`resizeWindowKeepingTop`). The window is `.floating` level, positioned at the top of the screen.
