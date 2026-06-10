# ann

A minimal, blazing-fast, keystroke-driven application launcher for Windows.

Press **Alt+Space**, a small search window appears centered on your active
monitor, type a few characters, the right result is at the top, press Enter, it
launches. That is the entire product.

## Features

- **Fuzzy subsequence matching** — `gc` surfaces *Google Chrome*, `vsc` surfaces
  *Visual Studio Code* (an fzy-style C scorer with word-boundary bonuses, not
  substring matching).
- **Learns your habits** — frecency (frequency + recency with a 14-day half-life)
  re-ranks results toward what you actually launch.
- **Three launch-target classes**, composed in fixed priority (apps → running
  windows → files): installed applications (Start Menu + Microsoft Store), an
  Alt-Tab-style **running-window switcher**, and your files & folders (Desktop,
  Documents, Downloads by default — configurable), kept fresh by a filesystem
  watcher within ~200 ms of changes.
- **Action panel** (Tab / Ctrl+K) — kind-contextual actions: run as
  administrator, open file location, copy path/name, activate/close window —
  with inline confirmation for destructive system commands.
- **System commands** — lock, sleep, shut down, restart, empty recycle bin,
  Settings, Control Panel, quit — a fixed list, fuzzy-matchable.
- **Real app icons** at every size, extracted natively and LRU-cached.
- **Lives in the system tray** — click the tray icon (or press the hotkey) to
  open; right-click it, or click the **titlebar app icon**, for ann's menu:
  **Settings…** (indexed folders, hotkey, result count), Rescan index, Quit.
- **Programmable, not pluggable** — `ann.config.tcl` is a real Tcl script,
  hot-reloaded on save: options, keyword aliases, custom result providers, and
  custom panel actions. No plugin SDK, no marketplace (by design). The Settings
  dialog persists its choices into one clearly-marked managed block; the rest of
  the file stays yours.
- **Fully portable** — one folder: `ann.exe`, the config, the SQLite database.
  Runs from a USB stick; imports only system DLLs; no installer, no autostart,
  no telemetry.

Deliberately omitted (see [`docs/DESIGN.md`](docs/DESIGN.md) §1): web search,
calculator, clipboard manager, browser bookmarks, plugins, themes.

## Get it

Grab the latest **`ann.exe`** from the [Releases](../../releases) page. It's one
self-contained file — no installer, no dependencies.

## Using it

Run `ann.exe`. It stays resident and holds the global hotkey (**Alt+Space** by
default). Esc hides the popup; type `quit ann` (or use the action panel) to exit.
On first run it writes an annotated `ann.config.tcl` next to the exe — edit and
save it any time; changes apply live (a broken config is rejected and the
previous one stays active).

The implementation is a small **C23 host** that statically embeds **Tcl/Tk
9.0.3** (UI + config language) and **SQLite with FTS5** (catalog, search,
frecency), built exclusively with MinGW-w64 (MSYS2 UCRT64). Architecture,
threading model, and every locked decision: [`docs/DESIGN.md`](docs/DESIGN.md).

## Toolchain & tasks

The project is **fully self-contained**: the vendored Tcl/Tk 9, the gcc/C23
toolchain, the SQLite amalgamation, and twapi live under `.toolchain/`, so the
folder is copy-paste portable to any Windows 11+ machine — no installs, and no
links to anything outside the folder. One ignition script, `x.cmd`, puts the
toolchain on PATH and hands off to the Tcl task runner:

```
x help          # list tasks
x build         # build the native ann.exe (static Tcl+Tk+SQLite, zipfs payload)
x build-con     # the console-subsystem debug twin (stderr is readable text)
x test          # in-process suite (110 tests; tcltest + Tk event generate)
x selftest      # ann.exe --selftest headless smoke (exit code = result)
x hktest        # end-to-end: synthesize Alt+Space, verify the popup toggles
x launchtest    # end-to-end: index, type a query, Enter, verify the app starts
x shot out.png  # screenshot the popup (PrintWindow, occlusion-proof)
x dist          # build + selftest-gate + put the release exe in dist/
x toolcheck     # verify the vendored toolchain (--deep runs functional checks)
```

See [`toolchain.md`](toolchain.md) for the full setup, the static-link recipe,
and the rules that keep the repo Tcl + C23 + one `.cmd`.

## About

Built on **Tcl/Tk 9.0.3** and **SQLite 3.51** (FTS5). **v0.3**.
© 2026 Vincent Vercauteren. **MIT** licensed; see [`LICENSE`](LICENSE).
