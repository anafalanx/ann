# ann — Design Document

> **Working title:** `ann`. The project folder is `ann`; the final product name is **TBD**.
> **Status:** Design (pre-implementation). **Target OS:** Windows 10/11 (x64).
> **License:** Permissive open source (MIT or BSD — see §13).

---

## 1. Overview & Goals

`ann` is a **minimal, blazing-fast, keystroke-driven application launcher for Windows**. You press a single global hotkey, a borderless search box appears centered on your active monitor, you type a few characters, the right result is at the top, you press Enter, it launches. That is the entire product.

The implementation is a small **C23 host** that statically embeds **Tcl/Tk 9.0.4** for the GUI and **SQLite (with FTS5)** for the index. It is built **exclusively with MinGW-w64 — the MSYS2 UCRT64 toolchain (GCC ≥ 15)** — with no MSVC build, which lets the host use the full C23 feature set, including `#embed` to bake the default config, the FTS5 schema, and UI/icon assets into the EXE (see §4). The C layer owns the Windows integration (global hotkey, icon extraction, window enumeration, shell actions); Tcl owns the UI composition and is also the **fully programmable configuration surface**; SQLite owns the durable catalog, the search prefilter, and frecency learning.

### Design philosophy

- **Latency is the feature.** Every decision is judged against "does this keep keystroke-to-result under a frame?" If a feature would add measurable latency or a background tax, it is cut.
- **Keyboard only.** The mouse is never required. The happy path is: hotkey → type → arrows → Enter.
- **One opinionated look.** No themes, no skins, no layout options. The product looks one way and looks good.
- **Fully portable.** One folder: the EXE, the Tcl config, the SQLite DB. Copy it to a USB stick and it runs.
- **Programmable, not pluggable.** No compiled plugin SDK. Power comes from the Tcl config, which is a real script.

### Primary goals

1. **Sub-frame interactivity.** Keystroke-to-rendered-results under ~16 ms on a warm index for a typical catalog (hundreds to low-thousands of items). Hotkey-to-visible-window under ~50 ms.
2. **Accurate fuzzy matching.** Typing `gc` surfaces *Google Chrome*; `vsc` surfaces *Visual Studio Code*. This is true **subsequence** matching with word-boundary/CamelCase bonuses — not substring, not prefix-only.
3. **Learns your habits.** Frecency (frequency + recency with time decay) re-ranks results so the things you actually launch float to the top.
4. **Three launch-target classes:** installed applications, files & folders, and currently-running windows (an Alt-Tab-style switcher) — composed in a **fixed source priority**, not a single blended list.
5. **A small, durable, dependency-light binary** that runs from a single folder with no installer.

### Non-Goals (explicit — these are rejected, not "later")

These are **out of scope by design**. They will not be added; reintroducing them contradicts the product thesis.

- **No web search.** `ann` never sends a query to a search engine.
- **No calculator / unit conversion / math evaluation.**
- **No clipboard manager, no snippets, no text expansion.**
- **No browser bookmarks or browser history** as launch targets.
- **No general "instant answers"** beyond the fixed system-command list in §8 (no weather, no dictionary, no currency).
- **No plugin system / no plugin SDK / no third-party loadable extensions.** Extensibility is the Tcl config only (§12).
- **No autostart with Windows.** The resident process is started manually by the user (§10).
- **No theming, skins, or user-selectable layouts.** One fixed look (§9).
- **No number quick-pick** (you do not press `1`–`9` to choose a result) and **no vim-style navigation** (`j`/`k`). Navigation is arrows + Enter only.
- **No relevance-blended single list.** Result composition is fixed source priority: apps → running windows → files.
- **No cloud sync, no telemetry, no account.**
- **No notification surface.** We do not use `tk sysnotify`. ann never toasts.
  (**Reversed decision:** this bullet used to also reject a system-tray icon. ann
  now *does* live in the tray — the tray icon is its presence, its click-to-open
  affordance, and the host of its menu: Settings…, Rescan index, Quit. "Is it
  running / how do I quit it?" is answered by the tray, not only inside the popup.)

---

## 2. Positioning

`ann` sits in the lineage of **Find and Run Robot (FARR)** — a keystroke launcher with abbreviation matching and learned ranking — but rebuilt on a modern, statically-linked Tcl/Tk 9 + SQLite core, with a Raycast-style action panel and a deliberately narrow scope.

| Capability | **ann** | FARR | Raycast (Win) | Alfred (macOS) |
|---|---|---|---|---|
| Core model | Keystroke launcher | Keystroke launcher | Launcher + command platform | Launcher + workflows |
| Fuzzy subsequence (`gc`→Chrome) | **Yes (custom fzy-style scorer)** | Yes (abbrev engine) | Yes | Yes |
| Frecency / learned rank | **Yes (Mozilla-style decay)** | Yes (learning) | Yes | Yes |
| Apps / files / folders | **Yes** | Yes | Yes | Yes |
| Running-window switcher | **Yes (Alt-Tab-style)** | Plugin-ish | Limited | Via workflow |
| Action panel (alt actions) | **Yes (Tab / Ctrl+K)** | Right-arrow menu | Yes (⌘K) | Yes (actions) |
| System commands (shutdown/lock/…) | **Yes (fixed list)** | Yes | Yes | Yes |
| Calculator | **No (cut)** | Yes | Yes | Yes |
| Web search | **No (cut)** | Yes | Yes | Yes |
| Clipboard manager | **No (cut)** | Plugin | Yes | Powerpack |
| Plugin SDK | **No — Tcl config only** | Plugins | Extensions store | Workflows |
| Theming | **No — one fixed look** | Skins | Themes | Themes |
| Distribution | **Portable single folder** | Portable | Installer | App bundle |
| License | **MIT/BSD (open)** | Freeware (closed) | Proprietary | Proprietary |
| Scriptable config | **Full Tcl script** | INI + aliases | GUI/JS | GUI + scripts |

**Versus Flow Launcher / PowerToys Run / Wox:** these are the closest open-source Windows analogues. Flow Launcher and Wox are C#/.NET with a plugin ecosystem (Python/C# plugins); PowerToys Run is a C#/.NET module inside the larger PowerToys suite. `ann` deliberately rejects the .NET runtime dependency and the plugin marketplace model in favor of a tiny native binary and a single scriptable config. The tradeoff: no plugin store, but no runtime install, no plugin supply chain, and a much smaller resident footprint.

**Versus Keypirinha:** Keypirinha is the spiritual sibling — a fast, portable, scriptable Windows launcher with a C++ core and a Python plugin/config split. `ann` keeps the C-core + scripted-config idea but uses **Tcl** (embedded statically, no external runtime) and **refuses a separate plugin layer**: there is no `Plugin` base class to subclass and ship. See §12 for the full comparison and rationale.

**What ann deliberately omits, in one line:** the "platform" ambitions. No store, no calculator, no web, no clipboard, no themes. It is a launcher, not a command palette for the whole OS.

---

## 3. Architecture Overview

### 3.1 Component diagram

```
                          ┌───────────────────────────────────────────────┐
                          │              ann.exe (C23)                  │
                          │                                                 │
   ┌──────────────┐       │  ┌─────────────────────────────────────────┐   │
   │ Global Hotkey│       │  │            GUI THREAD (main)              │   │
   │  thread      │ Tcl_  │  │                                           │   │
   │ RegisterHot- │ Thread│  │  ┌─────────────┐    ┌──────────────────┐  │   │
   │ Key + Get-   │ Queue │  │  │ Embedded    │    │  C command procs │  │   │
   │ Message loop │ Event │──┼─▶│ Tcl/Tk 9.0.4│◀──▶│ (ann::* in C)    │  │   │
   │ (own HWND)   │ +Alert│  │  │ interp+pump │    │  - search        │  │   │
   └──────────────┘       │  │  │ (owns Win32 │    │  - launch        │  │   │
                          │  │  │  msg pump)  │    │  - icon push     │  │   │
                          │  │  └──────┬──────┘    │  - actions       │  │   │
                          │  │         │           └────────┬─────────┘  │   │
                          │  │   Tk widgets:                │            │   │
                          │  │   popup, entry, virtual list │            │   │
                          │  └──────────────────────────────┼───────────┘   │
                          │                                  │ read-only conn │
                          │                                  ▼                │
                          │  ┌─────────────────────────────────────────┐    │
                          │  │             SQLite (WAL)                  │    │
                          │  │  catalog · usage_events · frecency        │    │
                          │  │  catalog_fts (FTS5 trigram) · app_meta    │    │
                          │  └────────────────────▲────────────────────┘    │
                          │                        │ writer conn             │
                          │  ┌─────────────────────┴─────────────────────┐  │
                          │  │          INDEXER THREAD (background)        │  │
                          │  │  - App discovery (.lnk + AppsFolder)        │  │
                          │  │  - File scan + ReadDirectoryChangesW (IOCP) │  │
                          │  │  - Frecency aggregation                     │  │
                          │  │  - ALL SQLite writes happen here            │  │
                          │  └─────────────────────────────────────────────┘  │
                          │                                                 │
                          │  ┌─────────────────────────────────────────┐   │
                          │  │   Win32 Platform Layer (shared, C)         │   │
                          │  │   DWM · SHGetFileInfo/IShellItemImage      │   │
                          │  │   EnumWindows · ShellExecuteEx · IAAM      │   │
                          │  └─────────────────────────────────────────┘   │
                          └───────────────────────────────────────────────┘
```

### 3.2 Process & threading model

`ann` is a **single process** with three logical threads plus transient worker threads:

1. **GUI thread (main).** Owns the Tcl interpreter and the Tk window. Runs the event loop. **Exclusively** touches the interpreter and Tk. Opens a **read-only** SQLite connection for search queries (WAL snapshot reads). This thread is where C-implemented Tcl commands (`ann::search`, `ann::launch`, etc.) run.
2. **Indexer thread.** Owns the **single writer** SQLite connection. Performs all catalog discovery, file scanning, `ReadDirectoryChangesW` handling (via an I/O completion port), and all writes (catalog upserts, usage-event inserts, frecency rollups, FTS sync). It **never** touches the interpreter; it pushes results/notifications to the GUI thread via `Tcl_ThreadQueueEvent` + `Tcl_ThreadAlert`.
3. **Hotkey thread.** Owns a dedicated message-only `HWND`, calls `RegisterHotKey` against it, and runs a `GetMessage` loop. On `WM_HOTKEY` it marshals into the GUI thread via `Tcl_ThreadQueueEvent` + `Tcl_ThreadAlert`. (Rationale in §3.4 and §10.)

**The absolute threading rule:** the Tcl interpreter and every Tk command are owned by the GUI thread alone. Tcl interpreters are never shared across threads — only *events* cross thread boundaries. The indexer and hotkey threads communicate **only** by queuing events. Calling `Tcl_Eval` or `Tk_PhotoPutBlock` from a worker thread will corrupt state or crash. (Tcl 9.0 is always built threaded, which is required for this model.)

**SQLite concurrency model:** WAL mode permits multiple concurrent readers plus exactly one writer; readers see a consistent snapshot and never block the writer. We therefore funnel **all writes through the indexer thread's single connection** and let the GUI thread read. We still set `busy_timeout` defensively. A second writer would get `SQLITE_BUSY`, so we structurally guarantee there is never a second writer.

### 3.3 Why C owns the platform and Tcl owns the UI

The hard Windows integration — global hotkey delivery, HICON→pixel extraction, window enumeration and foreground activation, shell verbs — is all Win32 and is done in C, where we control HWNDs, COM apartments, and handle lifetimes. Tcl/Tk handles what it is good at: composing the popup, the entry box, and the results list, and being the live config language. The boundary is a set of C-implemented Tcl commands registered with `Tcl_CreateObjCommand`.

### 3.4 Event-loop integration story (the central problem)

This is the trickiest part of the whole design, so it is specified precisely.

On Windows, **Tk already owns the Win32 message pump**: Tk's notifier calls `GetMessage`/`PeekMessage` on the GUI thread. Two consequences follow:

1. **We must not run a second blocking `GetMessage` loop on the GUI thread.** That would double-pump the queue, drop or reorder messages, and starve Tk. Instead the GUI thread runs a **custom blocking loop**:

   ```c
   while (running) {
       Tcl_DoOneEvent(0);   /* block until an event is ready; never spin */
   }
   ```

   `Tcl_DoOneEvent(0)` blocks in the notifier (no CPU spin) and processes one event when something arrives. We never use `TCL_DONT_WAIT` in a tight loop — that burns a core.

2. **`WM_HOTKEY` posted to the GUI thread can be swallowed** by Tk's own pump and never surfaced to our code. The robust pattern is therefore a **dedicated hotkey thread with its own message-only `HWND`** that we control (so `WM_HOTKEY` is delivered to a `WndProc` we own), which then **bridges into the GUI thread via `Tcl_ThreadQueueEvent` + `Tcl_ThreadAlert`**.

Work reaches the GUI thread's event loop from exactly two off-thread sources, both via the documented cross-thread mechanism:

- **Indexer thread:** `Tcl_ThreadQueueEvent(guiThreadId, ev, TCL_QUEUE_TAIL)` then `Tcl_ThreadAlert(guiThreadId)`. The event carries a `malloc`'d payload (e.g. "catalog updated", or a batch of icon blobs); the GUI-thread handler consumes it and frees it.
- **Hotkey thread:** identical mechanism, with an event meaning "toggle the popup."

The GUI thread obtains its id once at startup via `Tcl_GetCurrentThread()` and shares it with the workers. If we ever need a purely C-side event source (e.g. to bound polling latency), we use `Tcl_CreateEventSource(setup, check, data)` and `Tcl_SetMaxBlockTime` in the setup proc — but the two-worker-thread design above avoids needing a polling source.

---

## 4. Technology Stack & Static Linking

### 4.1 Components and versions

| Layer | Choice | Notes |
|---|---|---|
| Language | **C23** host + a thin Win32 platform layer | Built exclusively with MinGW-w64 (MSYS2 UCRT64, GCC ≥ 15, `-std=gnu23`), so the full C23 set — including `#embed` — is available. No MSVC build (§4.3). |
| GUI toolkit | **Tcl/Tk 9.0.4**, built **static** | Tk 9.0 *requires* Tcl 9.0 — the major versions are locked together; Tk 9.0 does not work with Tcl 8.6. |
| Storage / index | **SQLite** amalgamation with **FTS5** and **math functions** | Compiled into the EXE. |
| Platform APIs | Win32: DWM, Shell, USER32 | `dwmapi`, `shell32`, `user32`, `ole32`, `shlwapi`. |

Tcl/Tk 9.0 is the first stable major release of the line in ~27 years (9.0.0 shipped Oct 2024); 9.0.4 is the current patch release. Choosing 9.0 specifically buys us: **HiDPI scaling-aware widgets/themes**, **built-in SVG photo images** (for our own UI glyphs), and `image ... -withalpha`. We do **not** rely on `tk sysnotify`/`tk print` — they exist but are out of scope. ann *does* have a **system-tray presence**: the tray icon is the launcher's liveness indicator, a click-to-open affordance, and the host of its menu (Settings…, Rescan index, Quit). (§1 originally rejected a tray; that decision was reversed in implementation.)

### 4.2 The stubs mechanism — and why the host does not use it

The Tcl **stubs** mechanism (`USE_TCL_STUBS` + `Tcl_InitStubs` + linking `tclstub.lib`/`tkstub.lib`) exists so that **loadable extensions** can bind to whatever Tcl is present at load time, across versions, even into a statically-linked host. **`ann` is a host, not an extension**, so it does **not** use stubs for itself. We **statically link the full Tcl/Tk libraries** and call the real entry points directly:

```
TclZipfs_AppHook(&argc, &argv);     /* FIRST: mount the library zip appended to ann.exe */
Tcl_FindExecutable(argv[0]);        /* sets up filesystem-relative library lookup */
Tcl_Interp *ip = Tcl_CreateInterp();
Tcl_Init(ip);                        /* MUST precede Tk_Init */
Tk_Init(ip);                         /* fails if the embedded library zip isn't mounted */
/* register C commands, source the config, enter the loop */
```

`TclZipfs_AppHook` **must run first** — before `Tcl_FindExecutable`/`Tcl_CreateInterp`. Under the MinGW static build there is no external `lib/tcl9.0` directory, so this is the call that **mounts the script-library zip appended to `ann.exe`** and lets `Tcl_Init`/`Tk_Init` find `init.tcl`/`tk.tcl` (see §4.3). `Tcl_Init` must then precede `Tk_Init`. The smoke test for the whole static-build effort is simply: **does `Tk_Init` return `TCL_OK` with no external library directory present?** If yes, `AppHook` mounted the embedded zip correctly.

> If we ever ship a compiled extension of our own, *that* would be built `USE_TCL_STUBS` and linked against `tclstub`/`tkstub` so it can load into the static host. The host never does.

### 4.3 Static build approach

**Toolchain (MinGW-exclusive).** The project builds **only** with **MinGW-w64**, standardized on the **MSYS2 UCRT64** environment — `mingw-w64-ucrt-x86_64-gcc`, currently **GCC 16.1**, version-pinned for reproducible builds. There is no MSVC build. Two rules:

- **GCC ≥ 15 is a hard floor.** The design uses C23 `#embed` to bake the default config, the FTS5 schema, and UI/icon assets into the EXE; `#embed` first shipped in **GCC 15.1** (not 13/14) and in **Clang 19**. Guard embedded assets with `#if __has_embed(...)` + a clear `#error`, so an older compiler fails with a precise message instead of a parse error.
- **UCRT, never legacy MSVCRT.** The old MSYS2 `MINGW64` (msvcrt) environment is being retired (deprecated 2026-03-15) and has non-conforming `printf`/UTF-8; UCRT64 is the modern, in-OS runtime and the only future-proof GCC choice.

Compile flags: **`-std=gnu23 -municode -D_WIN32_WINNT=0x0A00 -D__USE_MINGW_ANSI_STDIO=1`**. (`-municode` for the Unicode `wmain`; `_WIN32_WINNT=0x0A00` unlocks the Win10 Shell/DWM/AppActivation declarations; `__USE_MINGW_ANSI_STDIO` gives conformant `%zu`/`%lld` — and we avoid `long double` formatting regardless, since MinGW can't print 80-bit `long double`.)

> *Alternatives.* A pinned **WinLibs GCC 15+ (UCRT)** zip is the documented option for machines without MSYS2 (same `#embed`). **llvm-mingw** (Clang ≥ 19, UCRT target) is worth a second dev/CI lane: unlike GCC-MinGW it has working **AddressSanitizer / UBSan and Control Flow Guard** (`-mguard=cf`), which is valuable for this COM-heavy code. Never mix toolchains within one shipped EXE.

**Build Tcl/Tk 9.0.4 static from source.** MSYS2 packages only Tcl/Tk **8.6** (DLL + stub libs), so a from-source static build is **mandatory** and should be a pinned, checked-in script. In the **UCRT64 shell**:

```
# Tcl first
cd tcl9.0.4/win && ./configure --disable-shared --enable-64bit && mingw32-make && mingw32-make install
# then Tk, against that Tcl
cd tk9.0.4/win  && ./configure --disable-shared --enable-64bit --with-tcl=<tcl-build-dir> && mingw32-make && mingw32-make install
```

Do **not** pass `--enable-threads` (threading is unconditional in 9.0); use `--enable-symbols` only for debug. Build **SQLite** (amalgamation, `SQLITE_ENABLE_FTS5` + `SQLITE_ENABLE_MATH_FUNCTIONS`) and **zlib** in the *same* UCRT64 environment so every object shares one CRT.

> **There is no `staticpkg` token under MinGW.** `nmake -f Makefile.vc … OPTS=static,staticpkg,msvcrt` is an **MSVC-only** recipe — there is no `nmake`, no `Makefile.vc`, and no `staticpkg` flag in the MinGW build. The MinGW way to embed the script library is **Tcl 9 zipfs**: the `--disable-shared` build appends `libtcl9.0.4.zip` / `libtk9.0.4.zip` to the binary, and at runtime **`TclZipfs_AppHook` mounts that appended zip** and sets `tcl_library`/`tk_library` (§4.2). Linking the `.a` *without* the appended zip + AppHook makes `Tk_Init` fail to find `init.tcl` — embedding is **not** automatic. (Our own assets are already baked into the C objects via `#embed`; a `zipfs mkimg` pass is only needed if we'd rather ship them inside the same zip.) The host must **not** define `USE_TCL_STUBS` or link `tclstub`/`tkstub` — MSYS2's *only* static `.a` are the stub libs, which is the opposite of a static-embed build (§4.2).

**Link recipe (GNU ld — order matters):** static archives with **Tk before Tcl**, the Windows import libs *after* the archives, and **`-static`** to fold in libgcc/libstdc++/**libwinpthread** *and* the CRT (`-static-libgcc`/`-static-libstdc++` alone do **not** cover `libwinpthread`):

```
x86_64-w64-mingw32-gcc -std=gnu23 -municode -D_WIN32_WINNT=0x0A00 -D__USE_MINGW_ANSI_STDIO=1 \
  ann.c ... -o ann.exe -static \
  libtk9.0.a libtcl9.0.a libsqlite3.a libz.a \
  -lcomctl32 -lcomdlg32 -limm32 -luxtheme -lgdi32 \
  -lshell32 -lole32 -loleaut32 -luuid -lpropsys -lshlwapi -ldwmapi -lpowrprof \
  -luser32 -lws2_32 -lnetapi32
```

- **`#define INITGUID` in exactly one `.c`** — the TU that `CoCreateInstance`s `CLSID_ApplicationActivationManager` (and any `PKEY_*`). mingw-w64's `libuuid.a` may not export those GUID symbols; this defines them locally. Keep every *other* TU **without** `INITGUID` to avoid duplicate-symbol errors.
- **DWM constant shim** — for older headers, guard the Win11 attributes: `#ifndef DWMWA_WINDOW_CORNER_PREFERENCE` define it `33`, `DWMWCP_ROUND` `2`, `DWMWA_CLOAKED` `14`.

> **Portability upside of `-static`.** The final `ann.exe` imports **only system DLLs** (`KERNEL32`, `USER32`, `OLE32`, `SHELL32`, `DWMAPI`, `ucrtbase`/`api-ms-win-*`) — no `libgcc`/`libstdc++`/`libwinpthread` to ship. The UCRT is an OS component on Win10/11, so the single EXE genuinely runs from a USB stick. Verify with `objdump -p ann.exe | findstr /i dll`.

**Other hard rules:**

- **One runtime model (UCRT) across all objects.** No mixing — never link a `msvcrt`-built (old MINGW64) Tcl/Tk/SQLite archive into the UCRT host (heap/`FILE*`-crossing crashes).
- **`Tcl_Size`, not `int`, for all lengths.** Tcl 9.0 moved object/string lengths to 64-bit (`Tcl_Size`). Code written against 8.6 `int` signatures will truncate or invoke UB on large data; use the documented 9.0 `*FromObj` APIs.
- **Verify `tcl.h`/`tk.h` compile clean under `-std=gnu23`** *before* committing the stack — C23 promotes `bool`/`true`/`false` to keywords, so confirm the public headers tolerate it on the pinned GCC.
- **DPI + UTF-8 manifest via `windres`** (Per-Monitor-V2), present **before any HWND exists** — see §9.8.

---

## 5. Data Model

SQLite in **WAL mode**, single file, lives next to the EXE (§13). Durable, learnable data is persisted; **volatile OS state is never persisted.**

### 5.1 What is stored vs. not stored

- **Stored (durable):** the catalog of installed apps, indexed files/folders, system commands, and config-provided static results; `usage_events` and the derived `frecency`; and a tiny `app_meta` key/value cache (schema version, last full-scan timestamp, watched roots).
- **NOT stored (volatile):** **the live running-window list.** It changes every second, has no durable identity, and persisting it would thrash WAL and the FTS index. Running windows are enumerated **live** at query time (§7.3) and merged in memory; their `HWND`s can go stale between enumeration and action, so action handlers revalidate (§7.3, §9.5). Also never persisted: transient z-order, per-keystroke query state, clipboard (we have none).

### 5.2 Schema DDL

```sql
-- ── Connection setup (run once on each connection) ───────────────────────────
PRAGMA journal_mode = WAL;       -- one writer + many readers, snapshot reads
PRAGMA synchronous  = NORMAL;    -- safe under WAL, much faster than FULL
PRAGMA busy_timeout = 3000;      -- defensive; we structurally avoid 2nd writer
PRAGMA foreign_keys = ON;

-- ── Durable catalog (apps, files, folders, shortcuts, system commands) ───────
CREATE TABLE catalog (
  id           INTEGER PRIMARY KEY,
  path         TEXT    NOT NULL UNIQUE,   -- file path, .lnk path, AUMID, or cmd id
  display_name TEXT    NOT NULL,
  kind         TEXT    NOT NULL,          -- 'app' | 'uwp' | 'file' | 'folder'
                                          --   | 'shortcut' | 'control_panel'
                                          --   | 'system_cmd' | 'config'
  launch_kind  TEXT    NOT NULL,          -- 'path' | 'aumid' | 'shell' | 'tclproc'
  icon_ref     TEXT,                      -- cache key / path+index, NOT icon bytes
  search_text  TEXT    NOT NULL,          -- normalized: foldcase + diacritic-fold of
                                          --   name||' '||path||' '||keywords (see §6)
  keywords     TEXT,                      -- space-joined aliases (from config or discovery)
  enabled      INTEGER NOT NULL DEFAULT 1,
  updated_at   INTEGER NOT NULL           -- unix seconds
);
CREATE INDEX ix_catalog_kind ON catalog(kind) WHERE enabled = 1;

-- ── FTS5 coarse prefilter (external content; trigram = substring matching) ───
CREATE VIRTUAL TABLE catalog_fts USING fts5(
  search_text,
  content      = 'catalog',
  content_rowid= 'id',
  tokenize     = 'trigram case_sensitive 0'
  -- case_sensitive 0 → case-insensitive substring match, and keeps indexed LIKE
  -- accelerated (indexed LIKE requires case_sensitive 0). Indexed GLOB is NOT
  -- available under case_sensitive 0; we only need case-insensitive substring,
  -- so we use LIKE and never rely on GLOB acceleration. Diacritic folding is
  -- applied identically at index time and query time in our own normalization
  -- (NOT via FTS remove_diacritics) so accented entries match folded queries.
);

CREATE TRIGGER catalog_ai AFTER INSERT ON catalog BEGIN
  INSERT INTO catalog_fts(rowid, search_text) VALUES (new.id, new.search_text);
END;
CREATE TRIGGER catalog_ad AFTER DELETE ON catalog BEGIN
  INSERT INTO catalog_fts(catalog_fts, rowid, search_text)
    VALUES ('delete', old.id, old.search_text);
END;
CREATE TRIGGER catalog_au AFTER UPDATE ON catalog BEGIN
  INSERT INTO catalog_fts(catalog_fts, rowid, search_text)
    VALUES ('delete', old.id, old.search_text);
  INSERT INTO catalog_fts(rowid, search_text) VALUES (new.id, new.search_text);
END;
-- Recovery path only: INSERT INTO catalog_fts(catalog_fts) VALUES('rebuild');

-- ── Usage events (one row per launch) → frecency ────────────────────────────
CREATE TABLE usage_events (
  id         INTEGER PRIMARY KEY,
  catalog_id INTEGER NOT NULL REFERENCES catalog(id) ON DELETE CASCADE,
  ts         INTEGER NOT NULL,            -- unix seconds
  weight     REAL    NOT NULL DEFAULT 1.0 -- event-type weight (launch=1.0, etc.)
);
CREATE INDEX ix_usage_catalog_ts ON usage_events(catalog_id, ts);

-- ── Incremental decayed aggregate (avoids rescanning all events) ────────────
CREATE TABLE frecency (
  catalog_id    INTEGER PRIMARY KEY REFERENCES catalog(id) ON DELETE CASCADE,
  decayed_score REAL    NOT NULL,         -- score re-anchored to last_event_ts
  last_event_ts INTEGER NOT NULL
);

-- ── Tiny meta cache (NO volatile data) ──────────────────────────────────────
CREATE TABLE app_meta (key TEXT PRIMARY KEY, value TEXT);
-- e.g. 'schema_version','last_full_scan_ts','watched_roots'
```

**Why trigram and not the default tokenizer?** The launcher needs *substring* matching (`MATCH 'chr*'` style is for prefixes only). The **trigram** tokenizer indexes every contiguous 3-character sequence, enabling general substring matches via `MATCH`, and — because we choose `case_sensitive 0` — keeps **indexed `LIKE`** available too (the trigram index accelerates `LIKE` only when `case_sensitive 0`; it would accelerate `GLOB` only under `case_sensitive 1`, which we do not use — we never rely on GLOB acceleration). Its one constraint: matches require runs of **≥ 3 characters**; 1–2 char queries cannot use the trigram index at all and fall back to a cheap `LIKE 'q%'` prefix scan on the (small) catalog. Trigram is *fast enough at our scale*: a launcher catalog is hundreds to low-thousands of rows, so a trigram `LIKE`/`MATCH` over it is sub-millisecond. (Reports of trigram `LIKE` taking on the order of a second only appear at multi-million-row scale and depend heavily on pattern length, hardware, and whether the index is actually used; none of that applies at a launcher's catalog size, and patterns shorter than 3 chars never touch the trigram index in any case.)

**Build flags this schema requires:** SQLite compiled with `SQLITE_ENABLE_FTS5` and `SQLITE_ENABLE_MATH_FUNCTIONS` (for `exp()` in the frecency query). If we prefer not to enable math functions, decay is computed in C instead (see §6.4).

---

## 6. Search & Ranking Pipeline

The pipeline is intentionally a **coarse SQL prefilter → exact in-C scoring** split. FTS5 cannot do subsequence matching, so we never ask it to; we use it only to shrink thousands of catalog rows to a tiny candidate set, then do the real `gc`→*Google Chrome* scoring in C, where it is sub-millisecond.

### 6.1 Stages

```
keystroke
   │
   ▼
[0] normalize query  (lowercase, trim, fold diacritics)
   │
   ▼
[0.5] exact keyword-alias check                          ← HYBRID alias leg (§6.7)
       if the query exactly equals a registered alias,
       its target is pinned to the top of its bucket
   │
   ▼
[1] candidate retrieval                                  ┐
     len ≥ 3 → FTS5 trigram MATCH (AND of char-runs)     │ SQL, read-only conn,
     len 1–2 → LIKE 'q%' prefix scan on catalog          │ WAL snapshot
     also pull frecency in same statement                ┘
   │  (≤ ~200 rows)
   ▼
[2] live providers merge
     - running windows (EnumWindows, live)               ← in-memory, not SQL
     - config custom result providers (Tcl procs)        ← §11
   │
   ▼
[3] fuzzy subsequence scoring  (fzy-style DP, in C)      ← the core IP
   │
   ▼
[4] frecency blend             (bigger = better)
   │
   ▼
[5] fixed source-priority bucketing + per-bucket slots
     apps  →  running windows  →  files                  ← NOT relevance-blended
   │
   ▼
[6] render top-N into virtualized Tk list
```

### 6.2 Stage 1 — candidate retrieval (SQL prefilter)

For queries of length ≥ 3, build a trigram `MATCH`; pull frecency in the same statement so we touch the DB once:

```sql
SELECT c.id, c.display_name, c.path, c.kind, c.launch_kind, c.icon_ref, c.search_text,
       COALESCE(f.decayed_score, 0.0)  AS frecency_anchor,
       COALESCE(f.last_event_ts, 0)    AS frecency_ts
FROM catalog_fts ft
JOIN catalog  c ON c.id = ft.rowid
LEFT JOIN frecency f ON f.catalog_id = c.id
WHERE catalog_fts MATCH ?            -- trigram query for the typed string
  AND c.enabled = 1
LIMIT 200;
```

(If we aggregate frecency on the fly instead of using the `frecency` table, the `COALESCE` subquery is `SUM(weight * exp(-lambda*(strftime('%s','now') - ts)))` over `usage_events` — see §6.4.) **FTS5 auxiliary functions like `bm25()` only work inside a `MATCH` query**, so if we ever use bm25 it must be in this same statement — but we generally don't, because **bm25 over a trigram index ranks by 3-gram overlap, not word relevance.** Our relevance comes from the C fuzzy scorer, not bm25.

For length 1–2, skip FTS (those queries cannot use the trigram index) and do `SELECT ... FROM catalog WHERE enabled=1 AND search_text LIKE ?||'%' LIMIT 200`.

### 6.3 Stage 3 — fuzzy subsequence scoring (the part FTS5 cannot do)

**FTS5 does not do subsequence matching at all** — no operator makes `gc` match `Google Chrome` as an in-order subsequence with gaps. Trigram does *contiguous substrings*; prefix does *word starts*; `spellfix1` does *edit-distance typo correction* (and is a separate loadable extension we deliberately do **not** ship). Abbreviation/initialism matching is a distinct algorithm, and we implement it ourselves in C.

We implement an **fzy/fzf-style scorer**: a match requires every query character to appear, in order, in the candidate (gaps allowed). Scoring uses an `O(n·m)` dynamic-programming matrix (`n` = query length, `m` = candidate length) with a parallel matrix tracking the best score *ending in a match at* each position, awarding bonuses for:

- **Word-boundary** matches (char after space, `/`, `\`, `_`, `-`, `.`).
- **CamelCase** matches (a capital following a lowercase).
- **Consecutive** matches (runs are strongly preferred).
- **Match near the start** of the candidate.

This is exactly the algorithm that makes `gc` rank *Google Chrome* highly and `vsc` rank *Visual Studio Code* highly. Because the candidate set after the prefilter is tiny (tens of rows, ≤ 200), the `O(n·m)` DP over short strings is **sub-millisecond** for the whole batch.

We may optionally expose the scorer to SQL as a `SQLITE_DETERMINISTIC` scalar via `sqlite3_create_function()` (so we could `ORDER BY ann_fuzzy(?, display_name)`), but for a tiny app it is simpler and faster to **`SELECT` the candidates and score them in a C loop**. The candidate-list architecture is the recommended fit for a low-latency app: prefilter small, score exact.

### 6.4 Stage 4 — frecency blend

We use **Mozilla's frecency model**: each usage event has a type-weighted value decayed exponentially, and an item's frecency is the **sum over its events**:

$$\text{frecency}(item) = \sum_{e \in events(item)} w_e \cdot e^{-\lambda \,(\,t_{now} - t_e\,)}$$

with decay constant

$$\lambda = \frac{\ln 2}{H}, \qquad H = \text{half-life}.$$

A launch a half-life ago is worth half a fresh one. Mozilla uses **H = 30 days**; for a launcher, habits shift faster, so `ann` **defaults to H = 14 days** (configurable, see §11). In seconds, `λ = ln2 / (14·86400) ≈ 5.73e-7`.

Two implementation options (the schema supports both):

- **On the fly:** `SUM(weight * exp(-lambda * (strftime('%s','now') - ts)))` over `usage_events` for the candidate (needs `SQLITE_ENABLE_MATH_FUNCTIONS`).
- **Incremental aggregate (default):** maintain `frecency.decayed_score` anchored at `frecency.last_event_ts`. On a new event at `t_new` with weight `w`: `new_score = old_score * exp(-λ·(t_new − last_ts)) + w`, then set `last_ts = t_new`. This bounds work and table churn; `usage_events` can be pruned periodically.

**Anchoring note (precise).** For a *pure exponential-sum* score, the common decay factor `exp(-λ·Δ)` factors out across all items, so the relative ordering is time-invariant and re-anchoring on write would suffice. **But our final rank is not the pure sum:** we pass frecency through a **non-linear `norm()`** and *add* it to the time-invariant `fuzzyScore` (below). After a non-linear squash plus an additive blend, the common decay factor no longer cancels, so the relative ordering **is not** time-invariant. Therefore reading the stored `decayed_score` *directly* (without re-decaying) can change rankings between items last launched at different times. The correct, cheap fix: at query time, **re-apply the single `exp(-λ·(t_now − last_event_ts))`** to each candidate's stored `decayed_score` *before* the `norm()`/blend. This is one `exp()` over the tiny candidate set — never a full event re-scan. (Reading `decayed_score` directly is only acceptable if you accept some ordering drift between items launched at different times; we do **not** accept it, so we always re-apply the one `exp()`.)

**The blend (sign-correct):** both terms are "bigger = better."

$$\text{final} = w_{fuzzy}\cdot \text{fuzzyScore} \;+\; w_{frec}\cdot \text{norm}(\text{frecency})$$

`norm()` squashes frecency into a comparable `[0,1)` range. **Default (pinned):** `norm(x) = x / (x + k)` with **`k = 4.0`** (roughly four recent launches puts an item at `norm ≈ 0.5`). Pinning `norm()` and `k` is what makes `w_frec = 0.35` reproducible. Defaults: `w_fuzzy = 1.0`, `w_frec = 0.35` — a strong match dominates, frecency breaks ties among comparable matches. **If we ever rank via `bm25` in SQL we must negate it** (`bm25` returns *smaller = better*); getting that sign wrong silently inverts ranking. We avoid that by scoring in C.

### 6.5 Stage 5 — fixed source-priority ordering (a locked decision)

> **Amendment (v0.4+, by owner decision — supersedes the three buckets below):**
> the EMPTY query is the LAUNCH HISTORY: only items actually started/opened
> through ann (frecency anchors), re-decayed and bucketed like everything else
> — never arbitrary catalog rows; first-run shows a friendly hint instead. And
> the buckets are **by NATURE, not by source**:
> **1. commands** (system commands + any future ann commands) ·
> **2. executable stuff** (apps, UWP, shortcuts, running windows, provider
> results, and plain files with executable extensions: exe com bat cmd msi msc
> lnk url appref-ms) · **3. openable files** · **4. folders** — score-ranked
> within each bucket, **no reserved slots**. Born from a real failure: a
> portable `firefox.exe` (exact name match, old files bucket) ranked below
> eight Office shortcuts recalled only via the f-i-r-e-f-o-x subsequence of
> their target PATHS — the penalized fallback recall must never outrank an
> exact name match through bucket privilege.

Results are **not** a single relevance-blended list. After scoring, results are bucketed and presented in **fixed source priority**:

1. **Apps** (installed applications, UWP, shortcuts, system commands, config results) — ranked by `final` within the bucket.
2. **Running windows** — ranked by `final` within the bucket.
3. **Files & folders** — ranked by `final` within the bucket.

Within each bucket, sort by `final` descending. A weak app match still appears above a strong file match. This is deliberate and predictable: when you type `chr`, an installed Chrome ranks above a file named `chrome-notes.txt`. (A configurable per-bucket score floor prevents very weak matches from showing at all.)

**Per-bucket slot allocation (so a small `result_limit` doesn't starve lower buckets).** With fixed priority and a small `result_limit` (default 9, §11.4), apps could otherwise consume every row and hide all windows and files even when they match. To keep all three target classes discoverable, the list is composed with a **reserved-slot policy** before filling greedily by priority:

1. **Reserve** up to **1 running-window slot** and **1 file/folder slot** *whenever those buckets have at least one above-floor match.* (No reservation is made for a bucket with zero matches; those rows go back to the pool.)
2. **Fill the remaining slots** strictly by source priority (apps first, then windows, then files), each bucket internally ordered by `final`.
3. **Reclaim** any reserved-but-unused slots back to the priority fill, so the list is never padded with blanks.

So with `result_limit = 9` and twenty matching apps plus one matching window and one matching file, the user still sees ~7 apps + 1 window + 1 file rather than 9 apps. The reserved counts are derived from `result_limit` and are not separately user-tunable in v1 (kept deliberately simple).

### 6.6 Latency budget

Target: **keystroke → rendered results ≤ ~16 ms** (one frame) on a warm index, typical catalog.

| Stage | Budget | How met |
|---|---|---|
| Normalize query | < 0.1 ms | Trivial string work in C. |
| SQL prefilter (FTS5/LIKE) | ≤ 3 ms | WAL snapshot read, indexed, ≤ 200 rows; catalog is small. |
| Live window enumerate | ≤ 2 ms | `EnumWindows` cached for ~250 ms between keystrokes; re-enumerated only when stale. |
| Fuzzy DP scoring | ≤ 2 ms | `O(n·m)` over short strings × ≤ ~200 candidates, in C. |
| Frecency blend + sort + bucket | ≤ 1 ms | Re-apply one `exp()` per candidate (§6.4), then sort tens of rows. |
| Render (virtualized list) | ≤ 6 ms | Only visible rows get Tk photo images; icon bytes from C cache. |
| **Total** | **≤ ~14 ms** | Headroom under one frame. |

Keystrokes are **debounced ~10–20 ms** and **coalesced**: if the user is typing fast, we drop intermediate queries and run only the latest, so we never queue stale work.

### 6.7 The HYBRID matching model (fuzzy + keyword aliases + frecency)

The locked matching decision is **hybrid**, with three legs that combine as follows:

1. **Fuzzy subsequence** (§6.3) is the general matcher for everything in the candidate set.
2. **Keyword aliases** (registered via `ann::alias`, §11.3) are a **first-class routing mode**, not just extra text in the trigram blob. The behavior is explicit:
   - On every keystroke, after normalization, the query is checked against the registered alias table (stage [0.5] above).
   - **An *exact* alias match short-circuits fuzzy scoring for that target:** the aliased target is given a max fuzzy score and **pinned to the top of its source bucket** (an app alias pins to the top of the apps bucket, etc.). So typing the exact alias `cfg` always puts the config file first in its bucket, regardless of fuzzy competition.
   - Partial/typo'd alias input *also* surfaces the target through normal fuzzy matching — but only the *exact* alias match triggers the top-pin. This makes the alias leg observable rather than indistinguishable from substring matching.
     > **Amendment (v0.6, mechanism only — the observable behavior above is
     > unchanged):** recall is implemented **query-time** — each keystroke
     > fuzzy-scores the query against the registered keyword table and merges
     > any hit's target into the candidates at that honest score (dedup keeps
     > the higher-scored row; `ann::alias_item` resolves all three target
     > forms for both legs). The original sketch ("fold alias text into
     > `search_text`") is NOT how it works: `search_text` is written by the
     > indexer thread under the single-writer rule, while aliases are
     > config-owned and live on the GUI thread — folding would demand
     > cross-thread catalog writes for cosmetic parity. A per-keystroke fuzzy
     > pass over a config-scale alias table costs microseconds (§6.6).
3. **Frecency** (§6.4) re-ranks *within* a bucket among comparable matches; it never overrides an exact-alias pin and never crosses bucket boundaries (fixed source priority, §6.5).

This is what "HYBRID" means concretely: fuzzy handles discovery, exact aliases give deterministic shortcuts, frecency learns your habits — all under fixed source-priority bucketing.

---

## 7. Launch Targets in Detail

All Win32/shell calls happen in the C platform layer on a thread with **COM initialized as apartment-threaded** (`CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)`), since shell interfaces are apartment-threaded; we never share raw interface pointers across apartments.

### 7.1 Application discovery

Two sources, merged into the catalog as `kind='app'`/`'uwp'`/`'shortcut'`:

**(a) Start Menu `.lnk` shortcuts.** Scan the all-users and per-user Start Menu folders for `.lnk`. Resolve each:

```
CoCreateInstance(CLSID_ShellLink, IID_IShellLinkW)
  → QueryInterface(IID_IPersistFile) → IPersistFile::Load(path, STGM_READ)
  → IShellLink::GetPath(... SLGP_RAWPATH) / GetArguments / GetIconLocation
```

The system does **not** auto-resolve a link loaded from a stream. We **avoid `IShellLink::Resolve` on any UI-facing thread** — it can hit the Distributed Link Tracking service and **block on network/UI** for moved targets. We prefer `GetPath` with `SLGP_RAWPATH` first and only fall back to `Resolve` lazily on the indexer thread when the raw target is missing.

**Resolved-target cache (avoid re-resolving on every full re-scan).** Resolving thousands of `.lnk` files via `IShellLink`/`IPersistFile` is per-file COM + disk and is slow if repeated on every full re-scan. We therefore cache the resolved target (and arguments/icon location) keyed by **`.lnk` path + last-write time** in `app_meta` (or a small side column on the `catalog` row). On a re-scan, an unchanged `.lnk` (same mtime) reuses the cached resolution and skips the COM round-trip entirely; only new or modified shortcuts are re-resolved. This keeps full re-scans cheap on machines with large Start Menus.

**(b) UWP / Store apps via `FOLDERID_AppsFolder`.** This shell folder is the same view as `shell:AppsFolder` and enumerates **both** desktop and packaged apps:

```
SHGetKnownFolderItem(FOLDERID_AppsFolder, ..., IID_IShellItem)
  → IShellItem::BindToHandler(NULL, BHID_EnumItems, IID_IEnumShellItems)
  → for each item:
       GetDisplayName(SIGDN_NORMALDISPLAY)              → visible name
       GetDisplayName(SIGDN_PARENTRELATIVEFORPARSING)   → AUMID (for packaged apps)
```

**Launching:**
- **Desktop apps / `.lnk` targets** (`launch_kind='path'`): `ShellExecuteEx` (or `CreateProcess`) on the real path.
- **UWP apps** (`launch_kind='aumid'`): **`IApplicationActivationManager::ActivateApplication(aumid, args, AO_NONE, &pid)`** — AUMIDs are **not** file paths and cannot be `CreateProcess`'d. The object is `CoCreateInstance(CLSID_ApplicationActivationManager)`; COM must be initialized. Before activating, call `CoAllowSetForegroundWindow` on the manager so the launched app can take focus (§7.3).

A catalog item must record *which* launch path applies — desktop apps surfaced inside AppsFolder may be `.lnk`-backed with a real parsing path, while packaged apps have an AUMID. We disambiguate at discovery time and store `launch_kind` accordingly.

### 7.2 File & folder indexing

> **Amendment (v0.1, by owner decision — two-tier full-disk indexing; supersedes
> the "defaults: Desktop, Documents, Downloads" below):**
>
> **Defaults (owner decision, revised after live whole-disk runs):** the default
> watched roots are **the seven priority locations themselves** (below) — NOT
> whole drives. Whole-disk roots were built, measured, and rejected as the
> default: watching all of `C:\` costs idle watcher churn on a busy system and
> a ~50 MB database for marginal recall. Adding `C:\` in Settings re-enables
> full-disk indexing with all the machinery below intact. The list is always
> authoritative — ann scans *only* what it covers, and an explicitly EMPTY list
> scans no files at all (never a silent fallback to defaults).
>
> **Tier 0 — priority folders, first and fast (per-folder flag, owner
> decision).** Priority is an attribute of EACH list entry, fully
> user-controlled in Settings (● on / ○ off, a Priority toggle button): ON
> folders are scanned at normal thread priority with no pacing, **before
> anything else**, so the catalog is useful seconds after start. The DEFAULT
> folders — seeded on first run and re-injectable via **Add Defaults** — carry
> the flag ON; folders the user adds default to OFF. The default seed
> (`SHGetKnownFolderPath`, existing dirs only): Desktop, Public Desktop,
> Downloads, Documents, `%LOCALAPPDATA%\Programs` (per-user installs), Program
> Files, Program Files (x86) — in that order (most-startable first, so the
> tier-0 cap truncates the least valuable last; a hit cap is reported in stats,
> and the flagged folder's overflow is never silently re-walked by the slow
> tier). Tier 0 indexes **all file types**, depth ≤ 6, cap ~30k rows with
> per-folder slices. In the config the option is `watched_roots` holding
> `{path prio}` pairs; bare legacy paths migrate (default folders → on,
> others → off). Start-Menu `.lnk` + UWP enumeration remain separate sources
> ahead of it.
>
> **Tier 1 — the priority-OFF folders, throttled.** After tier 0 commits and the
> GUI is notified, every ○ folder is walked in **background mode**
> (`THREAD_MODE_BACKGROUND_BEGIN` → very-low I/O + memory priority, the same
> mechanism Windows search uses) **plus pacing** (sleep between entry batches),
> in **batched transactions** (commit every few hundred upserts — never one
> giant transaction holding the writer for minutes). Tier 1 skips: tier-0
> subtrees (already scanned), reparse points, hidden/system dirs, dot-dirs, a
> **deny list** of noise/system dirs (`Windows`, `Windows.old`, `ProgramData`,
> `$Recycle.Bin`, `System Volume Information`, `Recovery`, `PerfLogs`,
> `Temp`/`Tmp`, `cache`/`caches`, `node_modules`, `__pycache__`), and indexes
> folders plus an **allow list** of startable/openable extensions (exe lnk bat
> cmd msc msi url | pdf office/text formats | common image/audio/video |
> zip 7z rar iso). Depth ≤ 10, cap ~120k rows; hitting a cap is logged and
> surfaced in stats, never silent. A `gWork` signal (config change, explicit
> rescan) aborts the bulk phase at the next batch boundary; the file-event
> queue is drained between batches so live changes are not starved during the
> long walk.
>
> **Schema & ranking.** `catalog` gains `tier INTEGER NOT NULL DEFAULT 0`
> (migrated in place via `ALTER TABLE` so existing frecency survives). Search
> treats tiers differently so latency stays inside §6.6 at ~150k rows:
> tier-0 rows (apps, shortcuts, syscmds, priority files — a small corpus) keep
> the full **subsequence-LIKE** recall at every query length; tier-1 rows are
> recalled via **FTS5 trigram MATCH** (substring semantics, already indexed)
> for queries ≥ 3 chars and via cheap **prefix-LIKE** for 1–2 chars; an empty
> query never surfaces tier-1 rows unless they have frecency. Tier 0 also gets
> a small additive rank bonus (tunable) — a deep file must be findable, not
> dominant.
>
> **Prune** is per-phase: tier-0 kinds prune after the fast phase; tier-1 rows
> prune only after a **complete, error-free** bulk walk (an aborted or errored
> bulk never deletes). Watcher overflow on a whole-drive root triggers the fast
> phase immediately but rate-limits bulk re-walks (cooldown ≥ 10 min); watcher
> events under deny-listed paths are dropped at the watcher thread.
>
> **Settings guidance.** The Settings dialog computes coverage: any priority
> location *not* under a listed root is shown beneath the folder list
> ("Not indexed: Downloads — D:\Stuff\Downloads") with a one-click **Include**
> action appending it. Removing `C:\` is allowed (the user owns the list); the
> hint is advice, never enforcement.
>
> **Lessons the first real-machine runs enforced (all load-bearing):**
> (1) the deny list applies to tier 0 too, and each priority location gets its
> own budget slice (~8k) — one `node_modules` inside Documents must not starve
> Program Files; (2) the FTS trigger is scoped `AFTER UPDATE OF search_text` —
> the unscoped version re-tokenized the trigram index on every generation
> touch, and that WAL churn fed the watcher a self-sustaining event storm;
> (3) unchanged files (same mtime) get a cheap generation/tier touch, never a
> row rewrite; (4) the watcher drops events for ann's own files (db/WAL/log)
> and rate-limits overflow→rescan signals to one per minute — the scan's own
> writes can overflow the 60KB RDC buffer; (5) an aborted bulk walk resumes via
> a timed wait (cooldown), never back-to-back; (6) scan generations are
> monotonic (`time(NULL)` alone collides within a second and the prune would
> silently skip).
>
> **Honesty.** First full bulk index of a large disk takes minutes (by design —
> it must not load the system); the popup is fully usable on tier 0 within
> seconds. `ann.db` grows to tens of MB at the 150k cap (trigram FTS included);
> the WAL is checkpoint-truncated after each completed bulk walk.

The indexer walks a configurable set of **watched roots** (defaults: Desktop, Documents, Downloads; fully overridable in the Tcl config). Each file/folder becomes a `catalog` row (`kind='file'`/`'folder'`). `search_text` is built with the **same normalization used for queries** (§6 stage [0]): lowercase + diacritic-fold of `name || ' ' || path` (plus any keywords). Applying the identical fold at index time and query time is what lets an accented entry like `Résumé.docx` match the folded query `resume`; folding only the query would make accented entries unreachable.

**Live updates via `ReadDirectoryChangesW`** on a worker, using an **I/O completion port** (`GetQueuedCompletionStatus`) so it scales to many roots without alertable-wait pitfalls:

```
hDir = CreateFile(root, FILE_LIST_DIRECTORY,
                  FILE_SHARE_READ|WRITE|DELETE, NULL, OPEN_EXISTING,
                  FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
ReadDirectoryChangesW(hDir, buf /*DWORD-aligned*/, len, bWatchSubtree,
   FILE_NOTIFY_CHANGE_FILE_NAME | _DIR_NAME | _LAST_WRITE,
   &bytesReturned, &overlapped, NULL);
```

Parse results as `FILE_NOTIFY_INFORMATION` linked via `NextEntryOffset`; `FileName` is a **non-null-terminated** WCHAR block sized in bytes by `FileNameLength`. We treat changes as a **hint stream** and **must** handle these documented gotchas:

- **Buffer overflow drops everything:** the call may return `TRUE` with `bytesReturned == 0`, or fail with `ERROR_NOTIFY_ENUM_DIR`. On either, we **schedule a debounced full re-scan** of that root or the index drifts.
- Buffer must be **DWORD-aligned** (else `ERROR_NOACCESS`); on network shares, length **> 64 KB** fails with `ERROR_INVALID_PARAMETER`.
- **Renames arrive as OLD_NAME + NEW_NAME action pairs**; events are coalesced/duplicated; we must **re-issue** the call after each completion.
- **Debounce bursts ~200 ms** before touching the index, then upsert; triggers propagate to FTS automatically.

A periodic full re-scan (timer in `app_meta.last_full_scan_ts`) is the backstop for missed events.

### 7.3 Running-windows switcher (Alt-Tab-style)

**Enumerated live, never persisted.** Built each time the switcher is relevant via `EnumWindows`, filtering to the alt-tab set:

- `IsWindowVisible(hwnd)` is true;
- title is non-empty (`GetWindowTextLengthW`/`GetWindowTextW`);
- **not** `WS_EX_TOOLWINDOW` (`GetWindowLongPtr(GWL_EXSTYLE)`);
- owner is `NULL` (`GetWindow(hwnd, GW_OWNER)`) **or** has `WS_EX_APPWINDOW`;
- **not cloaked:** `DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &v, sizeof v)` succeeds (returns `S_OK`) **and** the output value `v == 0`. (Note: `DwmGetWindowAttribute` returns an `HRESULT`; the *cloaked state* is in `v`, where `0` means "not cloaked." Do not conflate the `HRESULT` with the value — check both.)

These become in-memory results (`kind='window'`), scored against the query and placed in the **"running windows" bucket** (§6.5).

**Stale-HWND revalidation (enumeration → action race).** Because the window list is a live snapshot, an `HWND` can become invalid between enumeration and the moment the user acts on it (the window was closed, or the process exited). **Every window action handler — Activate and Close (§9.5) — first revalidates** with `IsWindow(hwnd)` (and `IsWindowVisible(hwnd)` for activate). If the `HWND` is stale, the action **silently drops** (no error toast), triggers a fresh `EnumWindows` re-enumeration, and refreshes the results so the dead row disappears. We never call `SetForegroundWindow`/`PostMessage(WM_CLOSE)` on an unvalidated handle.

**Activation — the Win32 foreground-rules problem.** `SetForegroundWindow` is *not* guaranteed to work: Windows only allows it under specific conditions (caller is foreground, foreground-lock timeout expired, caller received the last input event, etc.). When blocked, it merely **flashes the taskbar button** instead of raising the window — the classic launcher pain point, because at the instant the hotkey fires the "last input" went to another app.

`ann` uses the robust documented sequence (after the `IsWindow` recheck above):

1. If minimized, `ShowWindow(hwnd, SW_RESTORE)`.
2. **Attach input queues:** `GetWindowThreadProcessId(GetForegroundWindow(), …)` then `AttachThreadInput(ourThread, fgThread, TRUE)`.
3. `BringWindowToTop(hwnd)` + `SetForegroundWindow(hwnd)`.
4. `AttachThreadInput(ourThread, fgThread, FALSE)` (always pair attach/detach; never attach to our own thread; cross-attached threads can deadlock).
5. Fallback: `SwitchToThisWindow(hwnd, TRUE)` (documented as not always reliable on its own, hence the AttachThreadInput primary path).

**Handing off focus to launched apps.** When `ann` launches/activates a target (it is itself foreground while the popup is shown), it calls **`AllowSetForegroundWindow(ASFW_ANY)`** (or the specific child PID once known) **before** the launch, and **`CoAllowSetForegroundWindow`** on the `IApplicationActivationManager` for the COM activation path — otherwise the launched window only flashes the taskbar.

---

## 8. System Commands

A **fixed, built-in list** of system commands (`kind='system_cmd'`). **This is the only "instant answer" surface** — no calculator, no web, no conversions. Each is a catalog row with keyword aliases so fuzzy matching finds it (e.g. `lock` matches "Lock Workstation").

| Command | Display name | Implementation |
|---|---|---|
| Shutdown | "Shut Down" | `ExitWindowsEx(EWX_SHUTDOWN \| EWX_FORCEIFHUNG, ...)` (requires the `SE_SHUTDOWN_NAME` privilege be enabled first) — or `shutdown /s /t 0` via `ShellExecuteEx`. |
| Restart | "Restart" | `ExitWindowsEx(EWX_REBOOT \| ...)` (also requires `SE_SHUTDOWN_NAME`) / `shutdown /r /t 0`. |
| Lock | "Lock Workstation" | `LockWorkStation()`. |
| Sleep | "Sleep" | `SetSuspendState(bHibernate=FALSE, bForce=FALSE, bWakeupEventsDisabled=FALSE)` (Powrprof) — `FALSE` for `bHibernate` requests suspend (sleep), not hibernate. Like `ExitWindowsEx`, this requires the `SE_SHUTDOWN_NAME` privilege be enabled first. |
| Empty Recycle Bin | "Empty Recycle Bin" | `SHEmptyRecycleBin(NULL, NULL, SHERB_NOCONFIRMATION \| ...)`. |
| Open Settings | "Settings" | `ShellExecuteEx` on `ms-settings:`. |
| Open Control Panel | "Control Panel" | `ShellExecuteEx` on `control.exe` (or the Control Panel shell folder). |

> **Privilege note.** `ExitWindowsEx` and `SetSuspendState` do **not** grant themselves the `SE_SHUTDOWN_NAME` privilege; the process token must enable it first (`OpenProcessToken` + `LookupPrivilegeValue(SE_SHUTDOWN_NAME)` + `AdjustTokenPrivileges`) before the call, or it fails with access-denied. The `shutdown.exe` fallback path enables the privilege internally.

These commands are seeded into the catalog at first run and kept in `app_meta` schema versioning. The **destructive** ones — **shutdown, restart, and empty recycle bin** — are gated by a confirmation in the action panel by default (`confirm_destructive`, §15.4), configurable off in the Tcl config. Each is implemented as a C handler dispatched by the catalog row's `path` id; the config can also define *additional* commands as Tcl procs (§11), but the built-in set is exactly the list above — nothing more.

---

## 9. UI/UX Spec

One fixed, polished look. No themes, no skins, no layout options.

### 9.1 The window

> **Amendment (v0.1, by owner decision — supersedes the bullets below where they
> conflict):** the window has a **real titlebar** reading `ann <version>`
> (`wm overrideredirect 0`, still `-topmost`; the X button hides, quit stays
> explicit per §10.2) carrying the **real ann icon** (`wm iconphoto -default`,
> not Tk's feather); the window has **no taskbar button** (a hidden owner via
> `annplat::own_window` — owned toplevels get none, while keeping the normal
> caption the in-icon menu needs; the tray is ann's presence); the look matches **els** (calm grey `#F2F2F2` page,
> near-black ink, flat white fields with hairlines, ONE accent flourish — the
> caret in **the suite's shared red `#DC322F`** (owner decision 2026-07-20,
> **reversing** the earlier green4 `#008B00` choice: the tools now read as one
> suite, same single accent everywhere; one color for ALL accent uses; errors
> also read red — same hue, semantics carried by placement and wording, as in
> els itself; the catalog LED's *idle* state moves to the semantic good-green
> `#3C8A50`, since a red idle would collide with the LED's own red
> priority-scan state) — `#D6E2F2` selection, Segoe UI chrome) instead of the
> dark theme; the
> result **list rows use a compact font** (name 8 pt / subtitle 5 pt — the panel
> and dialogs keep 12/9); the list keeps the **first 50 results behind an x-row
> viewport** (`result_limit` rows of widgets — the §9.4 virtualization holds;
> scrolling re-points them) with a **vertical scrollbar cloned from els** (clam
> default layout, 12p arrows, els's greys, auto-hidden while everything fits;
> wheel = 3 rows per notch, keyboard selection drags the window along); there
> is a **real docked status bar** (els-style: hairline rule) carrying: a flat
> tri-state **catalog LED** leftmost (semantic good-green `#3C8A50` idle ·
> red while the priority scan runs · sober dark-yellow `#B8860B` while the
> throttled background walk runs — fed by the indexer's live `phase` field in
> its stats), then the left
> cell = transient message / **abbreviated catalog facts** ("A 97 · F 17,366 ·
> 15:07 · cap · E2") whose full sentences live in **tooltips** (els's tip
> machinery ported verbatim: 550 ms delay, dark tip, wrapping, window-clamped)
> on the LED, the line, and the result count; right cell = result count —
> never usage hints; and the mouse is supported on results: **click selects,
> double-click launches, right-click opens the context menu** (keyboard stays
> primary).

- **Borderless popup:** `wm overrideredirect 1` (undecorated, window-manager-ignored) + `wm attributes -topmost 1` (always above).
- **Centered on the active monitor** — the monitor with focus/the cursor. We compute the active monitor in C (`MonitorFromPoint`/`MonitorFromWindow` on the foreground window), then position via `wm geometry`. (`winfo screenwidth/height` alone is multi-monitor-naive, so the C layer supplies the correct monitor rect.)
- **Fixed width**, grows **downward** as results fill (the entry is pinned at top; the list expands beneath it up to a max height, then scrolls).
- **Single fixed visual style.** Dark, flat, rounded — see below.

### 9.2 The polished-popup problem and its limits (honest constraints)

This is a genuine Tk-on-Windows limitation that the design confronts directly:

- **`overrideredirect` kills DWM decoration**, so Windows 11 gives the popup **no automatic rounded corners and no drop shadow**. To get the polished look we grab the popup's `HWND` (`winfo id` / platform call) and call **`DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND)`** from C, and optionally extend the frame to enable a shadow. **This is best-effort:** because `overrideredirect` strips the standard non-client frame that DWM relies on, corner-preference and frame-extension behavior are inconsistent on frameless windows — on some Win11 builds it produces the rounded corners we want, and on others it produces **no rounding at all**. We treat any rounding we get as a bonus, not a guarantee (see the §16 risk).
- **True per-pixel anti-aliased rounded corners are not achievable in pure Tk.** `-transparentcolor` is **1-bit color-keying** (hard, jagged edges, and the keyed color is then unusable in the UI); `-alpha` is **uniform whole-window opacity** only. Tk on Windows has no per-pixel `WS_EX_LAYERED`/`UpdateLayeredWindow` compositing. **There is no `wm attributes -shadow`** on any platform.
- **Decision:** use `overrideredirect` + `-topmost` + DWM `DWMWCP_ROUND` for Win11 rounded corners *where the OS honors it on a frameless window*, accept slightly imperfect (or absent) edges/shadow, and **do not** use `-transparentcolor` for the popup body. `-alpha` is used only for a subtle whole-window fade-in/out. If we later want pixel-perfect rounded+shadowed edges, that is a **Win32 layered-window shim**, not a Tk feature — flagged as an optional polish task, not a v1 requirement.

### 9.3 Focus on show (the spotlight pain point)

`overrideredirect` windows **do not get keyboard focus from the window manager automatically** and don't appear in taskbar/alt-tab. On show we must **force focus**: `focus -force` on the entry, plus a Win32 `SetForegroundWindow` on the popup HWND (using the AttachThreadInput sequence from §7.3 if needed) so keystrokes reach the search entry.

### 9.4 Input box & results list

- **Input box on top:** a single `ttk::entry` styled to match. Optional `-placeholder` ("Search…") via Tk 9.0's entry placeholder support.
- **Vertical results list with icons:** each row is `[icon] [display name] [secondary line: path/type]`. The **selected row** is highlighted.
- **Keyboard navigation:** **Up/Down arrows** move the selection; **Enter** launches the selected (default action); **Esc** hides the popup. **No number quick-pick. No vim keys.** (Locked.)
  > **Amendment (v0.6, gap-analysis #3):** **Ctrl+Up / Ctrl+Down** recall
  > **typed-query history** — the MRU of what was typed at each invoke (distinct
  > from launch history, which the empty view shows). Ctrl+Up walks back,
  > Ctrl+Down forward to the saved live input; any edit returns to live typing;
  > every popup shows in live mode. Persisted next to the config as
  > `ann.history` (one query per line, newest first, cap 50, atomic
  > temp-and-rename, best-effort — history must never break a launch). No new
  > chrome: the entry itself is the whole UI.
  > **Amendment (v0.6, gap-analysis #4): path mode.** A rooted path in the
  > entry (`X:\`, `X:/`, UNC `\\server\…`; a **leading** `~` or `%VAR%` expands
  > first) switches the box into a live directory listing: the text up to the
  > last separator names the directory, the tail fuzzy-filters the listing.
  > **Tab completes the top result into the entry** (a folder gains a trailing
  > `\` — Tab is the descend; **Enter stays the ordinary launch**, so a folder
  > row opens in Explorer); **Ctrl+Backspace pops one level** (outside path
  > mode the chord falls through to Tk's word-delete). Ordering deliberately
  > **bypasses rank/bucketize** (whose cmds→execs→files→dirs nature order is
  > backwards for browsing): directories first, then files; `lsort -dictionary`
  > name order while the tail is empty, fuzzy score on the tail otherwise —
  > and no windows/providers/aliases and **no Run fallback row** (an unknown
  > directory lists nothing). Rows are ordinary file/folder dicts, so icons
  > and every panel verb work unchanged. Attribute-hidden entries are skipped
  > (Tcl `glob`'s Windows default — Explorer's behavior); dot-named files that
  > are not attribute-hidden appear. Listings cap at `PATH_LIST_CAP` (1000)
  > with the status bar's `cap` marker. This creates the **one documented Tab
  > mode-exception** to the §9.5 amendment: in path mode Tab means completion
  > (the universal shell convention) and **Ctrl+K is the panel's unconditional
  > opener everywhere**. FARR's `c:\pro\com` multi-segment smart matching is
  > the noted stretch goal, deliberately not built until the plain mode earns
  > daily use.
- **Virtualized list:** only visible rows hold live Tk photo images (§9.7). Scrolling reuses row widgets.

### 9.5 The action panel (Raycast-style)

> **Amendment (v0.5+, by owner decision — supersedes the custom slide-in
> panel):** the action surface is a **classic NATIVE context menu** (Tk menu →
> a real Windows popup menu), opened with **Tab/Ctrl+K** at the selected row or
> by **right-clicking any row** (which selects it first). (One documented
> exception since v0.6: in **path mode** Tab means completion and Ctrl+K is the
> panel's sole keyboard opener — see the §9.4 path-mode amendment.) Navigation, Enter and
> Esc are the native menu's own. **Destructive actions use the classic
> cascade-confirm idiom**: the item is a submenu ("Run... ▸ Confirm: Run"), so
> a stray Enter can never fire them and no dialog box is ever involved (§15.4
> honored). The inline arm/confirm state machine is gone with the custom panel.

A **secondary menu listing every action for the currently selected result**, opened with **Tab** (primary) or **Ctrl+K** (alias). It slides in over/within the popup; arrows navigate its items, Enter runs the chosen action, Esc/Tab closes it back to the list.

Actions are **contextual to the result's `kind`**:

| Result kind | Default (Enter) | Action panel offers |
|---|---|---|
| App / shortcut / UWP | Launch | Run as administrator; Open file location; Copy path; Copy name; (config actions) |
| File | Open | Open with…; Open containing folder (select item); Copy path; Copy name; (config) |
| Folder | Open | Open in new window; Copy path; (config) |
| Window | Activate | Activate; Close window; Copy title; (config) |
| System command | Run | Run; (confirm step for destructive ones) |

Action implementations (C):
- **Run as administrator:** `ShellExecuteEx` with `lpVerb = L"runas"`, `fMask = SEE_MASK_NOCLOSEPROCESS`. A **cancelled UAC prompt returns `FALSE` with `GetLastError() == ERROR_CANCELLED (1223)`** — a normal outcome we handle gracefully, not an error toast.
- **Open containing folder (with item selected):** `SHParseDisplayName(path, NULL, &pidl, 0, NULL)` then `SHOpenFolderAndSelectItems(pidl, 0, NULL, 0)`; free `pidl` with `CoTaskMemFree`. COM must be initialized.
- **Activate / Close window:** both first revalidate the `HWND` with `IsWindow()` (Close additionally uses `PostMessage(hwnd, WM_CLOSE, 0, 0)`); a stale handle is silently dropped and the enumeration refreshed (§7.3).
- **Copy path / name:** placed on the clipboard *as a one-shot action* — this is **not** a clipboard manager; `ann` stores nothing.

**The destructive-action confirmation flow (in-panel).** For destructive system commands (shutdown, restart, empty recycle bin — §8) with `confirm_destructive` on, selecting the action does **not** fire immediately. Instead the action panel replaces the action row with an inline two-choice confirm step ("Shut down? — Enter to confirm, Esc to cancel"). Enter on the confirm row runs the C handler; Esc returns to the action list. No separate modal dialog is opened — the confirmation lives inside the popup so the keyboard-only flow is unbroken.

The action panel is also the extension point: **config-defined action procs (§11) appear here automatically** for matching result kinds.

### 9.6 Result states

> **Amendment (v0.6, gap-analysis #1 — supersedes the "No matches" bullet):** a
> non-empty query that matches nothing now yields **one synthetic result row,
> `Run: <query>`** (stock PC icon, subtitle "run as typed"), instead of a dead
> "No results" state. Invoking it hands the raw query to
> `annplat::run_split` — Run-box splitting in C: a quoted first token wins,
> else the longest space-joined token prefix that exists on disk, else first
> token + args — and executes through the ordinary `annplat::launch` path, so
> the box doubles as a full Run-box replacement (`\\server\share`,
> `ms-settings:…`, anything on PATH). The row carries no panel actions and is
> inert unless invoked; there is deliberately **no option to disable it**.

- **Empty query:** show top frecency results (most-used recent items) — a useful "what would I launch" default. Subject to the same per-bucket slot policy (§6.5) so the empty-query view isn't all apps.
- **No matches:** a single muted "No results" row.
- **Indexing in progress (cold start):** results stream in as the indexer reports via queued events. The cold-start state is shown as a **single muted footer line** (e.g. "Indexing…") rather than a progress widget — consistent with the one-fixed, minimal-chrome look; it neither blocks input nor adds an animated control. (We deliberately do **not** use a `ttk::progressbar` here; the footer text is enough to explain why results are still filling in.)
- **Stale/missing target:** if a launch fails (target moved/deleted), show an inline error and trigger a re-index of that item.
- **Liveness / quit affordance (no tray).** Because there is no tray icon (§10.2), the popup itself answers "is it running / how do I quit?": a muted footer shows the app name/version, and **"Quit ann"** is available both as a built-in entry in the action panel's global section and as a fuzzy-matchable command (typing `quit ann`). Pressing the global hotkey at any time confirms the process is alive by showing the popup.

### 9.7 HICON → Tk photo image pipeline (C)

Native Windows file/app icons are **HICON/bitmaps, not SVG** — and Tk's bundled nanosvg **silently drops SVG text** anyway, so the SVG path is only used for our *own* UI glyphs (rendered via `image create photo -format svg -scaletoheight …` for crisp HiDPI). **Real icons go through this C pipeline:**

1. **Extract** at the exact target pixel size. Prefer `IShellItemImageFactory::GetImage` or `SHGetImageList(SHIL_JUMBO/SHIL_EXTRALARGE)` for crisp HiDPI (plain `SHGFI_LARGEICON` is *not* high-DPI). `SHGetFileInfo(... SHGFI_ICON ...)` is the simple fallback; it hands you an **owned `HICON` you must `DestroyIcon`**.
2. **Convert to pixels:** `GetIconInfo(hIcon, &ii)` → `hbmColor` + `hbmMask`; `GetDIBits` with a **top-down 32bpp `BI_RGB` `BITMAPINFO` (negative `biHeight`)** on `hbmColor`. This yields **BGRA**. **Swap B↔R** to get RGBA. For icons lacking alpha (A=0 everywhere), **synthesize alpha from the monochrome AND mask** or the image renders fully transparent. `DeleteObject` both bitmaps; `DestroyIcon` the icon.
3. **Push into Tk** via **`Tk_PhotoPutBlock`** with a `Tk_PhotoImageBlock` set to **`pixelSize = 4`, `offset = {0,1,2,3}`**, `pitch = width*4`, compositing `TK_PHOTO_COMPOSITE_SET`. **The opacity trap:** if the alpha offset (`offset[3]`) is **≥ `pixelSize`**, Tk assumes no alpha and forces the image opaque — so `offset[3]` must be `3` with `pixelSize = 4`. Get the **row order** right (top-down via negative `biHeight`) or icons render upside-down; get **R/B swap** right or colors are wrong.

**Caching & virtualization (memory discipline):** holding thousands of live Tk photo images is memory-heavy and slow to create. So we **cache the raw extracted ARGB bytes in a C-side LRU keyed by `(path, sizeBucket)`** and **create/destroy Tk photo images only for currently visible rows**. Off-screen rows release their photo images. `DestroyIcon`/`DeleteObject` happen promptly to avoid GDI handle leaks in a long-running session.

> **Threading reminder:** icon extraction (Win32/COM) happens on a worker; `Tk_PhotoPutBlock` happens **only on the GUI thread**. The worker hands ARGB blobs to the GUI thread via `Tcl_ThreadQueueEvent`; the GUI-thread handler pushes them into photo images and frees the payload.

### 9.8 DPI / HiDPI

We declare **Per-Monitor-V2 DPI awareness in the EXE manifest** (preferred over a runtime call, because awareness must be set **before any HWND is created** and cannot change once a window exists). Under the MinGW toolchain the manifest — Per-Monitor-V2 DPI **and** the UTF-8 active-code-page setting — is authored as a `.rc` resource compiled with **`windres`** and linked into the EXE (the MinGW analogue of MSVC's manifest tooling). Tk 9.0 widgets/themes are scaling-aware and `tk scaling` is initialized from the monitor at startup. Combining manifest awareness + Tk scaling + SVG/scalable UI glyphs + correctly-sized icon extraction keeps the UI crisp; without manifest awareness, DWM bitmap-stretches the window at ≥150% scaling, producing blurry text.

### 9.9 Dark mode / appearance note

`ann` ships **one fixed dark look** — we are not doing OS-theme following as a user option (no theming). Tk core has **zero** dark-mode integration (no system-theme query, no dark title bar, built-in Windows ttk themes are light). So we **embed our own ttk styles** (a small bundled `.tcl` + image assets baked into the static build, in the spirit of Sun Valley/Azure but trimmed to our fixed palette). Because the main popup is `overrideredirect` (no title bar), the dark-title-bar `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` call is only relevant for any auxiliary decorated window (e.g. a future preferences dialog), and we apply it there.

---

## 10. Activation & Process Lifecycle

### 10.1 The global hotkey (single, configurable)

A **single configurable global hotkey** toggles the popup. Default: **`Alt+Space`** (configurable in the Tcl config, §11). Implemented with **`RegisterHotKey`**:

- We register against a **dedicated `HWND` we own** (a message-only window on the **hotkey thread**), **not** `NULL`/the GUI thread — because Tk already pumps the GUI thread's queue and a thread-targeted `WM_HOTKEY` can be **swallowed** before our code sees it.
- `fsModifiers` is built from `MOD_ALT|MOD_CONTROL|MOD_SHIFT|MOD_WIN`, **always OR-ed with `MOD_NOREPEAT`** to suppress auto-repeat `WM_HOTKEY` storms.
- `WM_HOTKEY` carries the id in `wParam`; the modifiers/VK in `lParam`. Our `WndProc` translates it into a GUI-thread event via `Tcl_ThreadQueueEvent` + `Tcl_ThreadAlert`.
- `RegisterHotKey`/`UnregisterHotKey` run on the **same thread that owns the HWND** (here, the hotkey thread). We **never bind `F12`** (reserved by the debugger). If the chord is already taken by another app, `RegisterHotKey` fails — we surface a clear error and let the user pick another chord in config (§11.2 covers hot-reload re-registration).
- On exit we `UnregisterHotKey`.

Toggle semantics: hotkey shows the popup (and forces focus, §9.3) if hidden; hides it if visible. Esc hides; launching a result hides.

### 10.2 Manual-start resident process (no autostart — locked; tray: yes, per the amendment)

> **Amendment (v0.1, by owner decision — supersedes the "no tray" paragraph
> below):** `ann` **does** reside in the system tray (`tk systray`, reversing
> the §4.1 exclusion): left-click opens the popup, right-click opens ann's menu.
> The same menu opens from a **left-click on the titlebar app icon** (replacing
> the standard system menu via a WndProc subclass on `HTSYSMENU`; the icon
> double-click-to-close is suppressed). The menu carries **Settings…** (a dialog
> managing, at minimum, the indexed-folders list — persisted into a clearly
> marked, machine-managed block at the end of `ann.config.tcl`), **Rescan
> index**, and **Quit ann**. The titlebar X button hides; quitting stays
> explicit. No-autostart remains locked.
>
> **Amendment 2 (v0.1):** a real els-style menubar (`. configure -menu .menu`)
> was evaluated to close the apparent gap difference vs els and then **rejected**
> — it made no real difference to the window (els's content sits below a menubar
> *and* a tab bar, which is editor chrome a launcher has no equivalent for). ann
> keeps the **in-icon menu** (the titlebar app-icon menu via
> `annplat::hook_sysmenu`) plus the tray menu as the menu surface; the main
> window has no menubar.

`ann.exe` is a **resident process the user starts manually.** **It does not register for autostart with Windows**, does not write a Run key, does not install a scheduled task or service. Once running, it holds the global hotkey and stays resident. The user closes it explicitly (via **"Quit ann"** in the popup/action panel, §9.6) to release the hotkey. This is a deliberate, locked decision: the user owns when the launcher is alive.

**No tray icon.** Consistent with the minimalism stance and with §4.1's "`tk systray` is out of scope," `ann` has **no system-tray presence at all**. The "how do I know it's running / how do I quit it?" question is answered *inside the popup* (§9.6): the hotkey itself proves liveness by showing the window, a footer shows the name/version, and **"Quit ann"** is a first-class command in the action panel and via fuzzy search. There is no optional tray mode — a tray would reintroduce an out-of-scope feature for a single affordance the popup already provides.

### 10.3 Single-instance enforcement

Holding a global hotkey means a second instance would collide on `RegisterHotKey`. We enforce **single instance** with a **named mutex** (`CreateMutex` on a fixed name; `GetLastError() == ERROR_ALREADY_EXISTS` ⇒ another instance is live). A second launch detects the existing instance, optionally signals it to show the popup (via a named event or `WM_COPYDATA` to the existing window), then exits. Because `ann` is portable, the mutex name incorporates a hash of the install path so two copies in different folders (e.g. USB vs. local) can coexist without stomping each other's hotkey — or, if desired, share a single global name to enforce true one-at-a-time. Default: **per-install-path** single instance.

> **Hotkey thread vs. mutex interaction.** The single-instance mutex is checked at startup *before* the hotkey thread registers its chord, so a second instance never even reaches `RegisterHotKey` for the live install. Hot-reloading the hotkey (§11.2) does not create a second instance and does not touch the mutex; it only re-registers the chord on the existing hotkey thread.

---

## 11. Configuration

### 11.1 The model: the config *is* a Tcl script

There is no INI, no JSON, no GUI settings panel. **`ann.config.tcl` is a Tcl script, sourced at startup through the embedded interpreter.** It runs in the same interpreter as the UI, with a documented set of `ann::*` commands available. This is what makes `ann` programmable without a plugin system: setting an option and defining a brand-new result provider are the same kind of act — writing Tcl.

**First run & default config.** On first run there is no `ann.config.tcl`; `ann` **writes a default config** (the annotated template in §11.4, including the default `Alt+Space` hotkey and seeded options) into the install folder, then sources it. The seeded default is authored by us and trusted (§15.1). Subsequent runs detect the existing file and source it unchanged.

**Hotkey-conflict detection timing.** A config can register a hotkey that conflicts with another app or the system. We do **not** try to predict conflicts at source time — Windows has no reliable "is this chord free?" query — so a bad chord is detected **only when `RegisterHotKey` actually runs** (on the hotkey thread). On failure we keep the launcher alive and surface a clear, non-fatal error (status line + log) telling the user the chord is taken and to pick another in config. (At first run with the seeded default, if even `Alt+Space` is taken, the same non-fatal path applies and the user edits the config.)

### 11.2 Hot reload

The config is **hot-reloaded**. The indexer watches `ann.config.tcl` (it is just another file under `ReadDirectoryChangesW`); on change, the GUI thread is notified, the config is **re-sourced into a fresh child interpreter/namespace**, validated, and atomically swapped in. If re-sourcing errors, the previous config stays live and the error is surfaced (status line + log). Hot reload re-reads options, refreshes alias/provider/action registries, and re-registers the global hotkey if it changed.

**Re-registering the hotkey on hot reload (cross-thread).** `RegisterHotKey`/`UnregisterHotKey` must run on the thread that owns the hotkey `HWND` (the hotkey thread, §10.1) — the GUI thread cannot call them directly. So when a hot reload changes the chord, the GUI thread **marshals a "rebind hotkey" request to the hotkey thread** (via `Tcl_ThreadQueueEvent`/a posted message to the message-only window). On the hotkey thread, the handler **`UnregisterHotKey` the old chord first, then `RegisterHotKey` the new one**; if the new registration fails (chord taken), it re-registers the old chord (or leaves none) and reports the error back to the GUI thread for the non-fatal status message (§11.1). The old chord is never left dangling and there is never a window where two chords are registered for the same id.

### 11.3 Available config surface (selected `ann::*` commands)

- `ann::set <option> <value>` — set an option (hotkey, half-life, weights, width, watched roots, result limit, …).
- `ann::alias <keyword> <target>` — define a keyword alias (a typed keyword that maps to a launch target or proc). An **exact** match on `<keyword>` short-circuits fuzzy scoring and pins the target to the top of its bucket (§6.7).
- `ann::provider <name> <proc>` — register a **custom result provider**: a Tcl proc called with the query that returns result rows to merge into the candidate set.
- `ann::action <name> -kinds {...} -label "..." <proc>` — register a **custom action** that appears in the action panel for matching result kinds.
- `ann::result ...` — helper to construct a result dict. Recognized keys: `-id`, `-name`, `-subtitle`, `-icon`, `-kind`, and the action keys below.
- `ann::launch <spec>` / `ann::run <verb> <path> ?args?` — invoke the C launch/shell layer from Tcl.

> **Amendment (v0.6, gap-analysis #5): ignore globs + "Hide from results".**
> `ann::option ignore_globs {<glob> …}` is a user knob for paths that must never
> be indexed. A glob's `*` spans anything (including the separator, so a bare
> name matches at any depth), `?` is one char, matching is case-insensitive, and
> `/` and `\` both work. Enforcement is **index-time, in C** (the walk skips a
> matching directory without descending; every catalog write funnels through one
> upsert gate that deletes-and-refuses an ignored path; a full scan first calls
> `purge_ignored` to evict already-indexed rows) — so search pays **zero**
> per-keystroke cost. The knob is Tcl (`annindex::set_ignores` marshals it to the
> indexer), the mechanism is C: the split that keeps the core solid and the
> behavior scriptable. **The `ON CONFLICT … enabled=1` upsert would resurrect a
> mere `enabled=0` hide on the next scan; refusing to reach the INSERT is the fix.**
> The **action-panel** entry *Hide from results* (real indexed items only — not
> the Run row, an alias pin, a live window, or a path-mode browse row) appends the
> item's exact path to a **managed** `ann::option ignore_hidden {…}` line in the
> config's managed block, so the persistence *is* the un-hide surface (edit the
> file). The effective ignore set is `ignore_globs ∪ ignore_hidden`, so a hide
> never disturbs the user's hand-written globs. Note the built-in **deny list**
> (§7.2 — `node_modules`, `__pycache__`, `Windows`, …) already excludes the usual
> noise for free; `ignore_globs` is for the rest (`*.tmp`, `*.bak`, a project the
> user simply doesn't launch).

> **Amendment (v0.6, gap-analysis #6 & #7).**
> **`ann::option show_scores 1`** — a debug view of the ranking: each result's
> subtitle is prefixed with `[final  fN frecN tN]` (the blended final, the fuzzy
> component, normalized frecency, and tier). The components are computed in the C
> blend (`anndb.c` make_row now surfaces `sc_fuzzy`/`sc_frec` alongside `score`
> and `tier`); this is a debug surface for tuning the exposed `weight_*` /
> `frecency_norm_k` knobs, not a feature toggle.
> **`-term` exclusion** (no config, always on) — a whitespace-delimited query
> token that *starts* with `-` (so a hyphenated filename like `foo-bar` is
> untouched) is a negative substring filter: `report -draft` searches for
> `report` and drops any result whose name or path contains `draft`. Stripped
> from the query in `ann::split_query` **before** it reaches the search / window /
> provider candidate sources (all must see the cleaned query), then applied as a
> post-filter on the merged rows (`ann::apply_excludes`, tested on name+path).

**Default action vs. panel actions for config-provided results.** A result dict produced by `ann::result` distinguishes its **default (Enter) action** from its **action-panel actions** explicitly:
- **`-launch <spec>`** is the **default action** — what runs when the user presses **Enter** on the result. Exactly one `-launch` is the contract for "the Enter action" of a custom result (the §11.4 example sets `-launch [list ann::run open $dir]`). If a provider omits `-launch`, the result has no default action and Enter is a no-op for that row (it can still expose panel actions).
- Additional **action-panel** entries for that result come from any `ann::action` procs whose `-kinds` include the result's `kind` (they appear under Tab/Ctrl+K). So `-launch` = Enter; `ann::action` registrations = the panel. This contract is what makes the default action for custom providers unambiguous.

### 11.4 Full annotated example config

```tcl
# ============================================================================
#  ann.config.tcl  — sourced at startup; hot-reloaded on change.
#  This file is the ONLY extensibility surface. There is no plugin system:
#  everything below is plain Tcl running in ann's embedded interpreter.
#  (On first run, ann writes this template into the install folder; §11.1.)
# ============================================================================

# ---- 1. OPTIONS ------------------------------------------------------------
ann::set hotkey            {Alt+Space}     ;# the single global hotkey
ann::set frecency_halflife {14d}           ;# decay half-life (Mozilla-style)
ann::set weight_fuzzy      1.0             ;# blend: w_fuzzy * fuzzyScore
ann::set weight_frecency   0.35            ;#      + w_frec  * norm(frecency)
ann::set frecency_norm_k   4.0             ;# norm(x)=x/(x+k); pins w_frec (§6.4)
ann::set window_width      640             ;# fixed popup width in px (grows down)
ann::set result_limit      9               ;# max rows shown before scrolling
ann::set confirm_destructive 1             ;# confirm shutdown/restart/empty-bin

# Watched roots for the file index (overrides the defaults entirely):
ann::set watched_roots {
    {%USERPROFILE%\Desktop}
    {%USERPROFILE%\Documents}
    {%USERPROFILE%\Downloads}
    {D:\projects}
}

# ---- 2. A KEYWORD ALIAS ----------------------------------------------------
# Typing "cfg" launches this very config file in the user's editor.
# An EXACT "cfg" pins this to the top of its bucket (§6.7).
ann::alias cfg [list ann::run open [file join $ann::dir ann.config.tcl]]

# A simple alias that maps a keyword straight to an app already in the catalog:
ann::alias term {C:\Windows\System32\WindowsTerminal.exe}

# ---- 3. A CUSTOM RESULT PROVIDER -------------------------------------------
# Providers receive the normalized query and return a list of result dicts.
# They are merged into the candidate set BEFORE fuzzy scoring, so the same
# ranking/bucketing applies. Keep them fast (they run per keystroke).
#
# This provider exposes a few hand-picked project folders as "app"-bucket
# results so they outrank loose files (see fixed source priority, §6.5).
# Each result's -launch is its default (Enter) action (§11.3).
proc my_projects {query} {
    set out {}
    foreach {name dir} {
        ann       {D:\projects\ann}
        notes     {D:\projects\notes}
        scratch   {D:\projects\scratch}
    } {
        # ann::fuzzy returns >0 if the query is a subsequence of $name.
        if {[ann::fuzzy $query $name] > 0} {
            lappend out [ann::result \
                -id      "proj:$name" \
                -name    "Project: $name" \
                -subtitle $dir \
                -kind    app \
                -icon    folder \
                -launch  [list ann::run open $dir]]   ;# <- default (Enter) action
        }
    }
    return $out
}
ann::provider projects my_projects

# ---- 4. A CUSTOM ACTION ----------------------------------------------------
# Custom actions appear in the action panel (Tab / Ctrl+K) for the kinds
# you list. Here: "Open in Windows Terminal here" for files and folders.
proc open_in_terminal {result} {
    set path [dict get $result path]
    # If it's a file, open the terminal in its containing folder.
    if {[dict get $result kind] eq "file"} {
        set path [file dirname $path]
    }
    ann::run open "C:\\Windows\\System32\\WindowsTerminal.exe" \
        [list -d $path]
}
ann::action term_here \
    -kinds {file folder} \
    -label "Open in Windows Terminal" \
    open_in_terminal

# ---- 5. (Optional) a custom system-style command via a proc ----------------
# NOTE: built-in system commands (shutdown/restart/lock/sleep/empty bin/
# settings/control panel) are fixed and provided by ann itself. This merely
# adds a personal one; ann does not add a calculator/web/clipboard.
# The proc, its registered id, and its label all agree: it locks the
# workstation, nothing more.
proc lock_workstation {result} {
    ann::run shell {rundll32.exe user32.dll,LockWorkStation}
}
ann::action lock_workstation -kinds {system_cmd} \
    -label "Lock workstation" lock_workstation
```

This single file demonstrates the whole extensibility story: **options, an alias, a custom result provider proc, and a custom action proc** — all plain Tcl, all hot-reloaded, no compilation, no plugin install.

---

## 12. Extensibility Philosophy

### 12.1 Resolving the "no plugins" / "full scripting" tension

There is an apparent contradiction in the requirements — "no plugins" yet "full Tcl scripting." The resolution is precise and intentional:

> **There is no separate compiled/loadable plugin system to install.** There is no plugin API, no plugin SDK, no plugin base class, no plugin marketplace, and no mechanism by which third-party binaries or downloadable packages are loaded into `ann`. **Instead, the Tcl config is fully programmable.** Power users extend behavior by **writing Tcl procs in their own config** — aliases, custom result providers, and custom actions — rather than by installing third-party plugins.

So `ann` is **programmable without being pluggable.** You don't install an extension; you write a proc. The config *is* the extension surface, and it is the only one.

### 12.2 What this buys (and costs)

**Advantages:**
- **No plugin supply chain.** There is nothing to download from a marketplace, so there is no third-party-plugin attack surface, no version-compat matrix, no "this plugin broke the launcher" failure mode.
- **Tiny, self-contained binary.** No runtime to install (unlike .NET-based Flow Launcher / PowerToys Run / Wox), no plugin loader, no IPC to plugin hosts.
- **One language, one interpreter.** Config and extension are the same thing; everything is hot-reloaded the same way.
- **Portability stays intact.** Your extensions travel inside `ann.config.tcl` in the same folder (§13).

**Tradeoffs (stated honestly):**
- **No ecosystem / no store.** You cannot one-click install someone else's "Spotify controls" extension. You write what you need, or copy a snippet.
- **Power requires Tcl.** A non-programmer cannot extend `ann` beyond options and aliases. That is an accepted cost of the minimalist stance.
- **No process isolation for extensions.** Config procs run **in-process, in the GUI interpreter** (see §15 for the safety implications). A heavy or buggy provider proc can slow a keystroke; we mitigate with per-keystroke timeouts and by running expensive work off-thread where the API allows.

### 12.3 Compared to Keypirinha's C++/Python split

Keypirinha is the closest model: a fast C++ core with a **Python** plugin/config layer, where packages can be dropped in. `ann` keeps the **native-core + scripted-surface** shape but makes two deliberate departures:

| Aspect | Keypirinha | **ann** |
|---|---|---|
| Core | C++ | **C23** |
| Script layer | **Python** (CPython embedded) | **Tcl/Tk 9.0.4 (static)** |
| Extension unit | Installable **packages/plugins** (a `Plugin` subclass) | **Procs in your own config** — no package unit |
| Third-party distribution | Package files you install | **None** — you copy snippets into your config |
| GUI | Custom | Tk widgets composed in the same script language |
| Isolation | Plugins are still in-process Python | Config is in-process Tcl |

The net: Keypirinha is *pluggable* (drop in a package); `ann` is *programmable* (edit your config). We trade the package ecosystem for radical simplicity and zero plugin supply chain.

---

## 13. Packaging & Distribution

### 13.1 Fully portable single-folder layout

Everything lives in **one folder**; no installer, no registry writes, runs from a USB stick:

```
ann/
├─ ann.exe                 # the C23 host with Tcl/Tk 9.0.4 + SQLite statically linked
├─ ann.config.tcl          # the Tcl config (created from a default on first run)
├─ ann.db                  # SQLite database (catalog, usage, frecency, FTS); WAL
├─ ann.db-wal              # WAL file (created at runtime)
├─ ann.db-shm              # WAL shared-memory file (created at runtime)
├─ assets/                 # bundled UI glyphs (SVG) + ttk theme assets (if not baked)
├─ LICENSE                 # MIT or BSD text
└─ README.md
```

- **No external Tcl/Tk install required** — the script library is baked into the binary via **Tcl 9 zipfs** (the appended library zip mounted by `TclZipfs_AppHook`, §4.2/§4.3), so there is no `lib/tcl9.0` directory to ship.
- **DB path is relative to the EXE**, so the whole folder is relocatable. Moving the folder moves the index with it.
- **First run** seeds `ann.config.tcl` from a default (§11.1) and creates `ann.db` with the schema in §5; subsequent runs detect and reuse them.
- **No autostart** is written (locked, §10). The user copies the folder and runs `ann.exe`.
- **One honest caveat — the UCRT.** We link **`-static`** (§4.3), so `ann.exe` carries libgcc/libstdc++/libwinpthread and the CRT internally and imports **only system DLLs**. The Universal C Runtime (`ucrtbase.dll` / `api-ms-win-crt-*`) is an **OS component on Windows 10/11**, always present, so "runs from USB, no installer" holds for every supported target. Only a pre-Win10 OS (not a target) would need a UCRT redistributable.

### 13.2 Build artifacts

A single `ann.exe` (x64), one runtime model (UCRT), Per-Monitor-V2 manifest embedded. Optionally a zipped release `ann-vX.Y.Z-win-x64.zip` containing exactly the folder above.

### 13.3 License

**Open source under a permissive license — MIT or BSD.** We default to **MIT** for brevity and ubiquity (BSD-2-Clause is an acceptable alternative). We must honor the licenses of bundled components: **Tcl/Tk** ships under a BSD-style license and **SQLite** is public domain — both are compatible with shipping a permissively-licensed static binary. Any embedded ttk theme assets we ship must be under a compatible permissive license (or authored by us).

---

## 14. Performance Targets

| Metric | Target | How it is met |
|---|---|---|
| **Hotkey → popup visible** | ≤ 50 ms | Window pre-created and hidden, not built on each show; show = `wm deiconify`/map + force focus. DWM corner pref set once. |
| **Keystroke → rendered results** | ≤ ~16 ms (one frame) | SQL prefilter (≤3 ms) → tiny candidate set → C fuzzy DP (≤2 ms) → blend/sort (≤1 ms) → virtualized render (≤6 ms). Keystrokes debounced ~10–20 ms and coalesced. |
| **Idle CPU** | ~0% | GUI thread blocks in `Tcl_DoOneEvent(0)` (no spin); indexer blocks in `GetQueuedCompletionStatus`; hotkey thread blocks in `GetMessage`. No polling loops. |
| **Idle memory** | small (target < ~40 MB) | Single native process, no .NET; C-side LRU icon cache bounded; only visible rows hold Tk photo images; thousands of live photo images explicitly avoided. |
| **Cold full index (typical catalog)** | seconds, non-blocking | Indexer runs in background; UI is usable immediately and results stream in via queued events. |
| **Incremental update latency** | ~200 ms after FS change | `ReadDirectoryChangesW` (IOCP) → ~200 ms debounce → upsert → FTS triggers. |
| **DB read under concurrent write** | non-blocking | WAL snapshot reads; reader never blocks the single writer. |

**Hot-path discipline:** no allocation per keystroke beyond the candidate buffer (reused); icon bytes cached in C, not re-extracted; frecency read from the stored `decayed_score` with one query-time `exp()` re-decay (§6.4) rather than re-scanning events; FTS used only as a prefilter, never for relevance on trigram tokens.

---

## 15. Security & Safety

### 15.1 Executing arbitrary Tcl from the config

The config is a full Tcl script run **in-process in the GUI interpreter** — it is, by design, **as privileged as `ann.exe` itself.** This is the same trust model as a shell `rc` file or a Vim/Emacs config: **the config can do anything the user can do.** Safety posture:

- **Trust boundary = the user's own file.** `ann.config.tcl` lives in the (portable) install folder and is authored/owned by the user. On first run the file does not exist and `ann` writes our **trusted default template** (§11.1); we do **not** download or auto-execute configs from anywhere, and we never source a config from a network path by default.
- **No sandbox claim.** We do **not** advertise the config as sandboxed. (A Tcl *safe interpreter* could restrict it, but that would cripple the legitimate use cases — launching processes, shelling out — so the main config runs unrestricted and we are explicit about that in the docs.)
- **Hot-reload safety:** a config that throws on load does **not** replace the running config; the previous good config stays live and the error is surfaced. This prevents a typo from bricking the launcher. A hotkey chord that fails to register is likewise non-fatal (§11.1).
- **Per-keystroke guardrails:** custom provider procs run on the hot path; we bound them with a timeout and isolate failures (a throwing provider is dropped for that keystroke, logged, not fatal).

### 15.2 Run-as-administrator

- Elevation uses `ShellExecuteEx` with the **`runas` verb** — the standard UAC path; the user explicitly chooses it from the action panel. `ann` itself runs **unelevated**; it never silently elevates.
- A **cancelled UAC prompt** (`ERROR_CANCELLED`, 1223) is handled as a normal "user declined" outcome, not an error.
- We never store credentials and never bypass UAC.

### 15.3 Path & quoting handling

- **All paths are treated as data, never concatenated into a command string** when we can avoid it. Launches go through `ShellExecuteEx`/`CreateProcess`/`IApplicationActivationManager` with the path and arguments passed as **separate parameters**, so a path containing spaces, quotes, `&`, or `%` cannot break out into command injection.
- When a path *must* become a string (e.g. a user `ann::run shell` command), we apply correct Windows argument quoting (CommandLineToArgvW-compatible escaping). The Tcl layer uses `list`/`exec`-style argument vectors, not string splicing.
- **AUMIDs vs. paths are never confused:** the catalog records `launch_kind`, and UWP AUMIDs are only ever passed to `ActivateApplication`, never to `CreateProcess`.
- **Untrusted catalog data** (file names, window titles) is only ever displayed and matched, never `eval`'d.
- **COM/GDI handle hygiene** (security-adjacent robustness): every `HICON`/`HBITMAP`/`PIDL`/interface pointer is released on every path (`DestroyIcon`/`DeleteObject`/`CoTaskMemFree`/`Release`) to avoid resource exhaustion in a long-running resident process.

### 15.4 Destructive actions

Shutdown, restart, and "empty recycle bin" are the **destructive system commands** (§8) and are gated behind an in-panel confirmation by default (`confirm_destructive`, §9.5), to avoid a fat-fingered Enter powering off the machine or irreversibly emptying the bin. The confirmation is the inline two-choice step described in §9.5 (Enter to confirm, Esc to cancel) — no separate modal — and the gate can be turned off in the Tcl config. This set (shutdown + restart + empty recycle bin) is the single, consistent definition of "destructive-gated" used throughout the doc.

---

## 16. Risks & Open Questions

**Technical risks (with mitigations):**

1. **`overrideredirect` + DWM polish is imperfect (or absent).** Rounded corners/shadow via `DWMWA_WINDOW_CORNER_PREFERENCE` on an unmanaged, frameless window can be inconsistent and on some Win11 builds may produce **no rounding at all**, precisely because `overrideredirect` strips the non-client frame DWM relies on; pure-Tk anti-aliased rounded corners are impossible. *Mitigation:* request DWM `DWMWCP_ROUND` and treat any rounding as best-effort for v1 (§9.2); treat a Win32 layered-window shim as optional later polish.
2. **Hotkey delivery through Tk's pump.** A thread-targeted `WM_HOTKEY` can be swallowed. *Mitigation:* dedicated hotkey thread + owned message-only HWND + `Tcl_ThreadQueueEvent` bridge (§3.4, §10). Must be validated early.
3. **Foreground-activation denial.** `SetForegroundWindow` may only flash the taskbar. *Mitigation:* AttachThreadInput sequence + `AllowSetForegroundWindow`/`CoAllowSetForegroundWindow` before launch (§7.3). Inherently a bit fragile across Windows versions.
4. **Static build friction.** Linking a `msvcrt`-built archive into the UCRT host (heap/`FILE*` crossing), or the zipfs library zip not being mounted (missing `TclZipfs_AppHook`), causes crashes or `Tk_Init` failure. *Mitigation:* build everything in one UCRT64 environment; call `TclZipfs_AppHook` first; the `Tk_Init`-with-no-lib-dir smoke test gates the build (§4.2/§4.3).
5. **C23 / Tcl 9 header friction.** C23 keyword promotion (`bool`/`true`/`false`) and Tcl 9's 64-bit `Tcl_Size` width changes can break compilation. *Mitigation:* verify `tcl.h`/`tk.h` compile under `-std=gnu23` on the pinned GCC before committing, gate `#embed` behind `#if __has_embed` (needs GCC ≥ 15), and use `Tcl_Size` for all lengths.
6. **`ReadDirectoryChangesW` overflow / network shares.** Silent event loss; >64 KB buffer fails on shares. *Mitigation:* overflow-triggered full re-scan + periodic backstop scan; cap buffer; debounce.
7. **Icon pipeline correctness.** BGRA↔RGBA swap, row order, the `Tk_PhotoPutBlock` alpha-offset trap, and GDI leaks. *Mitigation:* the documented `pixelSize=4, offset={0,1,2,3}`, negative-height DIB, mask-derived alpha; verified by a visual smoke test.

**Open questions:**

- **Default hotkey value (not whether it's configurable — that's locked):** the default ships as **`Alt+Space`** (§10.1, §11.4); the only open question is whether that default should instead be `Ctrl+Space`, since `Alt+Space` collides with the system window menu in some contexts (`Win+Space` is rejected as a default — it collides with the IME/layout switcher). To be decided by testing; the mechanism (single configurable chord) is fixed regardless.
- **Half-life default:** 14 days vs. Mozilla's 30 — needs real-usage tuning.
- **Single-instance scope:** per-install-path (allow USB + local concurrently) vs. one global instance. Defaulting to per-path; revisit.
- **MIT vs. BSD-2-Clause** final choice.
- ~~MSVC vs. MinGW as the canonical toolchain~~ — **decided: MinGW-exclusive** (MSYS2 UCRT64, GCC ≥ 15, `-std=gnu23`, `-static`; no MSVC build). The host is therefore genuinely **C23** (§4.3).

(Note: a tray icon is **not** an open question — it is explicitly out of scope, §10.2; liveness/quit is handled inside the popup, §9.6.)

---

## 17. Milestones

A phased roadmap from skeleton to v1. Each milestone ends with the relevant verification check.

**M0 — Stack proof (the riskiest bits first).**
- Static-build Tcl/Tk 9.0.4 (MinGW/UCRT64, `./configure --disable-shared`; zipfs library zip + `TclZipfs_AppHook`, §4.3) + SQLite (FTS5 + math) into the C23 host, one UCRT model, `-static`.
- Verify: `tcl.h`/`tk.h` compile under `-std=gnu23` and a one-line `#if __has_embed` test passes on the pinned GCC; **`TclZipfs_AppHook` + `Tk_Init` return `TCL_OK` with no external lib dir**; a worker thread `Tcl_ThreadQueueEvent` round-trips to the GUI thread.
- A bare borderless `overrideredirect` + `-topmost` window appears, centered on the active monitor, and **gets keyboard focus** (`focus -force` + `SetForegroundWindow`).

**M1 — Hotkey + event loop.**
- Dedicated hotkey thread, message-only HWND, `RegisterHotKey` (with `MOD_NOREPEAT`), `WM_HOTKEY` → `Tcl_ThreadQueueEvent` → toggle popup.
- GUI thread runs the blocking `Tcl_DoOneEvent(0)` loop (verified ~0% idle CPU).
- Single-instance named mutex; configurable hotkey wiring stubbed, including the cross-thread rebind path (§11.2).
- Verify: **hotkey fires while Tk's loop runs**; idle CPU ~0%; a stubbed rebind unregisters the old chord before registering the new one.

**M2 — Data model + indexer skeleton.**
- Schema (§5) created; WAL; indexer thread owns the writer connection; GUI opens read-only.
- App discovery: Start Menu `.lnk` resolution (with the mtime-keyed resolved-target cache, §7.1) + `FOLDERID_AppsFolder` enumeration → catalog; index-time normalization matches query-time (§7.2).
- Verify: catalog populated; concurrent read during write does not block; unchanged `.lnk`s are not re-resolved on a second scan.

**M3 — Search pipeline.**
- FTS5 trigram prefilter + LIKE fallback for 1–2 chars; C fzy-style subsequence scorer; frecency aggregate with query-time `exp()` re-decay; blend with pinned `norm()`/`k`; **fixed source-priority bucketing with per-bucket reserved slots**; exact-alias top-pin (§6.7).
- Verify: `gc`→Chrome, `vsc`→VS Code; an exact alias jumps to the top of its bucket; a single matching file/window still appears under a 9-row limit dominated by apps; latency budget (§6.6) met.

**M4 — Icons + virtualized list UI.**
- HICON→RGBA pipeline (`IShellItemImageFactory`/`GetDIBits`/`Tk_PhotoPutBlock`), C-side LRU cache, virtualized rows; vertical icon list; entry on top; arrows + Enter.
- Verify: **an extracted Windows icon renders right-side-up with correct colors and alpha**; thousands of catalog rows with no photo-image blow-up.

**M5 — Launch + window switcher + foreground rules.**
- Launch desktop/UWP/system commands; `EnumWindows` live switcher with `IsWindow()` revalidation on activate/close (§7.3); AttachThreadInput activation; `AllowSetForegroundWindow`/`CoAllowSetForegroundWindow` handoff.
- Verify: activating a background window reliably raises it (not just taskbar flash); UWP launches via `ActivateApplication`; a window closed between enumeration and action drops silently and refreshes.

**M6 — Action panel + system commands.**
- Tab/Ctrl+K action panel, kind-contextual actions (run as admin, open containing folder w/ select, copy path/name, close window), the in-panel destructive confirm step (§9.5); the fixed system-command list (§8) with `SE_SHUTDOWN_NAME` privilege enabling; "Quit ann" command (§9.6).
- Verify: run-as-admin handles `ERROR_CANCELLED`; open-folder-and-select works; shutdown/restart/empty-bin all require the inline confirm; "Quit ann" exits and releases the hotkey.

**M7 — File index live updates.**
- `ReadDirectoryChangesW` over IOCP; debounce; overflow→full-rescan; periodic backstop scan.
- Verify: creating/renaming/deleting a watched file updates results within ~200 ms; overflow recovers.

**M8 — Config + hot reload + extensibility.**
- `ann::*` command set; first-run default-config write (§11.1); source `ann.config.tcl`; hot reload via fresh interpreter swap; cross-thread hotkey rebind (unregister-old-then-register-new, §11.2); aliases, custom providers, custom actions (the §11 example works end-to-end), `-launch` as the documented default action.
- Verify: editing the config live re-registers the hotkey (old chord unregistered first), adds a provider's results, and adds a panel action — with a bad config kept out without bricking, and a conflicting chord reported non-fatally.

**M9 — Polish + packaging (v1).**
- DWM rounded corners (best-effort, §9.2); fixed dark ttk styling baked in; Per-Monitor-V2 manifest; fade `-alpha`; empty/no-result/indexing-footer states (§9.6); LRU/handle-leak hardening over long sessions.
- Portable single-folder layout; UCRT-dependency note honored (§13.1); MIT/BSD `LICENSE`; release zip.
- Verify: full run-from-USB on Win10/11; long-running session shows no GDI/handle growth; all §6.6/§14 targets met.

**Post-v1 (explicitly deferred, not promised):** optional Win32 layered-window shim for pixel-perfect shadow; an optional **llvm-mingw** (Clang) CI lane for ASan/UBSan/CFG hardening. **Still never:** web search, calculator, clipboard manager, bookmarks, plugins, autostart, theming, number quick-pick — these remain out of scope (§1 Non-Goals). (The system tray was on this list until the §10.2 amendment reversed it: ann now lives in the tray.)