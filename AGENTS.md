# Agent Instructions

`ann` is a minimal, keystroke-driven application launcher for Windows: a C23 host
that statically embeds **Tcl/Tk 9.0.3** (GUI + programmable config) and **SQLite
(FTS5)** (catalog + search + frecency). The full product spec is
[`docs/DESIGN.md`](docs/DESIGN.md) — treat it as authoritative for *what* to build
and *how each subsystem must behave*. This file covers *how to work in the repo*.

## Read the Tcl/Tk 9 manual first

This repo vendors the **complete Tcl 9 & Tk 9 manual** as Markdown under
[`docs/tcl-tk-9-manual/`](docs/tcl-tk-9-manual/) (1293 pages: Tcl + Tk commands,
the C API, and `tclsh`/`wish`). It is the **authoritative reference** for this
codebase — prefer it over training-data recall, which may be stale or describe
Tcl 8.x behavior.

- **Before writing or changing any Tcl/Tk code — or the C that drives the
  embedded interpreter** (`Tcl_CreateObjCommand`, `Tcl_ThreadQueueEvent`,
  `Tk_PhotoPutBlock`, `TclZipfs_AppHook`, …) — **consult the manual.** Start at
  [`docs/tcl-tk-9-manual/INDEX.md`](docs/tcl-tk-9-manual/INDEX.md) and read the
  pages relevant to your change (each file is named after the command/function,
  e.g. `commands/wm.md`, `commands/ttk_entry.md`, `c-api/Tcl_CreateThread.md`).
- Do **not** read all 1293 pages into context — open the few that matter. Grep
  the tree to find the right page.
- The pages are generated from the vendored nroff by `tools/man2md.tcl`; to
  refresh them, rerun `tclsh90 tools/man2md.tcl` (do not hand-edit the output).

## The build is native (custom C23 entry point)

`ann.exe` is a **real native Windows PE**: a custom C23 entry point
(`src/ann_main.c`) with **Tcl, Tk, and SQLite statically linked in**, plus the
Tcl/Tk script libraries and `ann.tcl` riding inside an appended zipfs image.
`ann.tcl` is ordinary Tcl, unchanged by the C entry point. The platform layer
(global hotkey, icon extraction, window enumeration, shell actions) is C; the UI
composition and the fully-programmable config are Tcl; SQLite owns the catalog,
the FTS5 prefilter, and frecency.

- **`x build-sqlite`** compiles the vendored amalgamation into
  `.toolchain/sqlite/libsqlite3.a` (FTS5 + math, one UCRT model). Run once; the
  native build links it.
- **`x build`** builds `ann.exe` (compile `src/ann_main.c` + the static
  extensions in `src/`; the PE icon/manifest/version `.rc`/`.manifest`/`.ico` are
  **generated from Tcl** by `tools/genres.tcl` + `tools/mkico.tcl` into the
  gitignored `build/`, then `windres`'d; link the static `.toolchain/tcl9s` libs
  + `libsqlite3.a` + the Win32 system libs; append the zipfs payload).
- The architecture, the static-link recipe, and the pitfalls are in
  [`docs/DESIGN.md`](docs/DESIGN.md) (§3 threading, §4 stack & static linking).
- Verify the exe headlessly: `ann.exe --selftest [report.txt]` writes a report
  file (GUI subsystem = no stderr); `x test` runs the in-process suite. **Never**
  debug a GUI build by running it on a failure — it can rain modal dialogs; read
  the file-report selftest, or build a console-subsystem twin (gcc without
  `-mwindows`) whose stderr is text.

## Language policy (same as the toolchain doc)

Only **Tcl 9** (the UI `ann.tcl`, all `tools/*.tcl`, `tests/*`), **C23** (the host
+ platform layer `src/*.c`, built with the vendored gcc), and **one** classical
Windows `cmd` file (`x.cmd`). No bash, **no PowerShell**, no Python. Where Tcl is
genuinely not suitable, use standard Windows command-line commands.

## General

- Use Tcl as much as possible for project tooling in this repo.
- Latency is the product (DESIGN §1): judge changes against keystroke-to-result.
  Do not add per-keystroke allocation, polling loops, or background taxes.
- Double-check UI/behavior changes through the exact user-facing interaction path
  before reporting them fixed.
- Be precise about verification: only claim behavior that was actually checked.
