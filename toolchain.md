# ann toolchain

How `ann` is built, tested, and kept portable — now that it lives **inside the
mal master toolchain**. `ann` is a C23 host that statically embeds Tcl/Tk 9.0.3
(GUI + programmable config) and SQLite/FTS5 (catalog + search + frecency).

The general bundle/runtime model is mal's — see [`../TOOLCHAIN.md`](../TOOLCHAIN.md)
and the `tika` stack doc [`../docs/lineages/tika.md`](../docs/lineages/tika.md)
(paths relative to the mal root). This file is ann's slice of it.

## Pinned bundle, discovered — never vendored

ann does **not** carry its own toolchain. It pins a shared, read-only mal bundle
by name in **`toolchain.pin`** (one line; currently `tika26b`) and discovers it at
build time by walking ancestors for `X/<pin>/BUNDLE.manifest` — so the whole tree
is location-agnostic (mal can sit anywhere and be renamed). `x env` prints the
resolved bundle. The bundle gives ann, read-only:

| Need | In the bundle |
|---|---|
| gcc (C23) + binutils + windres | `msys64/ucrt64/bin/` |
| Tcl/Tk 9 headers | `tcl9/include/` (`tcl.h`, `tk.h`) |
| Tcl/Tk 9 static link libs | `tcl9s/lib/{libtcl9tk90.a,libtcl90.a,libtclstub.a,libtkstub.a}` |
| static interps (for packaging) | `tcl9s/bin/{tclsh90s.exe,wish90s.exe}` |
| script-library zipfs payload | `tcllib/{tcl_library,tk_library}` |
| SQLite amalgamation **sources** | `sqlite/{sqlite3.c,sqlite3.h}` |
| twapi (GUI tooling / tests) | `twapi-dl/` |
| the Tcl/Tk 9 + C-API manual | `manual/` (Markdown) |

Git is a mal-level shared tool (`mal git`), not a bundle component.

## Containment: ann writes only inside its own folder

The bundle is read-only (icacls-locked). Everything ann **produces** lands inside
`ann/`: compiled objects, `build/libsqlite3.a`, the dev `build/*.dll` extensions,
the zipfs staging dir, the exes, and `dist/` all go under `build/`/`dist/` or the
project root; `ann.config.tcl` (saved atomically via temp+rename), `ann.db`(+wal/
shm), and `ann.log` sit beside the exe; the screenshot and toolcheck temp files go
in `build/`, never the system `%TEMP%`. ann reads the bundle and mal's shared
git/python; it writes **nothing** outside `ann/`.

## Tcl/Tk version: always 9, never msys64's 8.6

MSYS2's `ucrt64` ships its own Tcl/Tk 8.6; ann never uses it. Tooling invokes the
interpreter only through the explicit bundle paths (`tcl9/bin/tclsh90.exe` /
`wish90.exe`, `tcl9s` for packaging) — never a bare `tclsh`/`wish` — and PATH puts
`tcl9/bin` ahead of `msys64/ucrt64/bin`. C builds pass `-I<bundle>/tcl9/include`.

## Ignition: `x.cmd`

The single non-Tcl file. It reads `toolchain.pin`, discovers the bundle (ancestor
walk; goto-based flow so a `)` in the folder path — e.g. an Explorer "ann (1)"
copy — can't break parsing), puts `tcl9/bin` + `msys64/ucrt64/bin` on PATH, then
hands off to `tools/x.tcl`. `x shell` (or a double-click) opens a shell with the
bundle on PATH; a missing/incomplete bundle prints a clear message.

## Task runner: `tools/x.tcl`

All tooling. `$TC` is the discovered bundle, `$ROOT` is the project. `x help`
lists the verbs:

```
x build-sqlite      compile build/libsqlite3.a (FTS5 + math) from the bundle's sqlite sources
x build [out]       native ann.exe — C23 host, static Tcl/Tk + SQLite, zipfs payload appended
x build-con [out]   console-subsystem debug twin (ann-con.exe; stderr is real text)
x build-ext         compile src/*.c -> build/*.dll dev extensions (for x run-dev / x shot)
x run [args]        launch the built ann.exe
x run-dev [args]    launch ann under wish + the dev .dll extensions (fast Tcl loop)
x selftest [exe]    ann.exe --selftest; print the headless report; exit code = result
x shot [out]        screenshot the popup (twapi + the cap.dll PrintWindow extension)
x test [--fast]     in-process suite (tcltest + Tk event generate)
x hktest            end-to-end: synthesize the global hotkey, verify the toggle
x launchtest        end-to-end: index, type a query, Enter, verify the app launches
x probe <f> [args]  run an ad-hoc verification script under the console tclsh
x icon              regenerate resources/icon*.png
x colors [name ...] browse Tk's named colors
x dist              build + selftest-gate + put the release exe in dist/
x toolcheck [--deep] check the pinned bundle has what ann needs (--deep runs them)
x env               print the resolved bundle + tool paths/versions
x shell             open a shell with the bundle's toolchain on PATH
```

`x.tcl` re-asserts PATH itself (robust when run directly under the bundle's
`tclsh90.exe`) and uses a cheap per-command guard (`need gcc tclsh` — a microsecond
`file exists`), not a full scan; the thorough scan is `x toolcheck`. The
toolchain-fetch tasks are gone — mal owns the toolchain; a missing core piece means
the bundle is incomplete (`mal verify <pin>`).

### Dev extensions: `x build-ext` / `x run-dev`

`x build-ext` compiles every `src/*.c` (except the entry point) into a
`build/<name>.dll` against the Tcl stubs (+ Tk stubs for `annicon`) and writes a
`build/pkgIndex.tcl`, so `x run-dev` can load them under `wish90.exe` for a fast
Tcl/C dev loop. `x shot` uses the same path to build `build/cap.dll` (the
occlusion-proof PrintWindow capture extension). All outputs stay in `build/`.

## SQLite: `x build-sqlite`

SQLite is compiled from the bundle's amalgamation **sources** into a static
`build/libsqlite3.a` — a **project build product** (DESIGN §3), never written into
the read-only bundle — with `-DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS
-DSQLITE_THREADSAFE=1 …`. `FTS5` powers the trigram prefilter; `MATH_FUNCTIONS`
gives `exp()` for frecency decay. Idempotent (skips when the `.a` is newer).

## Build: `x build` (native ann.exe)

One self-contained native PE from ann's own C23 entry point: `tools/genres.tcl` +
`tools/mkico.tcl` generate the PE resources (icon/manifest/version) into `build/`;
`windres` compiles them; gcc compiles `src/ann_main.c` + the static extensions
(`anndb`/`annplat`/`annhotkey`/`annindex`/`annicon`, headers from the bundle's
`tcl9/include`, SQLite from its `sqlite/`); links the **static** `tcl9s/lib` libs
(Tk before Tcl before stub) + `build/libsqlite3.a` + the Win32 system libs; then
`package.tcl` (under the static `tclsh90s`) appends the zipfs payload (`main.tcl`
= `ann.tcl`, `resources/`, `tcl_library`, `tk_library`) **after** the PE image so
the baked icon/manifest/version survive. Output: `ann.exe` in the project root.
Never debug a GUI build by launching it on failure — use `x selftest` (file report)
or the console twin `x build-con`.

## Portability

Copy-paste the whole **mal** folder (ann rides inside it): bundle and project
travel together, every path resolves relative to the invoking script (`%~dp0` in
`x.cmd`, `[info script]` in the Tcl) or is discovered, and the shipped `ann.exe`
imports only system DLLs (UCRT is an OS component on Win10/11). No install, no
provisioning, no network.
