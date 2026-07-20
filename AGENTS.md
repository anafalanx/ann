# Agent Instructions

`ann` is a minimal, keystroke-driven application launcher for Windows: a C23 host
that statically embeds **Tcl/Tk 9.0.4** (GUI + programmable config) and **SQLite
(FTS5)** (catalog + search + frecency). The full product spec is
[`docs/DESIGN.md`](docs/DESIGN.md) — treat it as authoritative for *what* to build
and *how each subsystem must behave*. This file covers *how to work in the repo*.

`ann` lives as a hosted project under `C:\dev\_ann` and builds against
regular z runtime payloads under `..\r\` - see [`toolchain.md`](toolchain.md).
It reads those payloads read-only and writes generated outputs inside the
project. z owns the build environment; ann owns its source, [`z.json`](z.json),
build outputs, and release `ann.exe`.

Prefer running project work through z and the committed [`z.json`](z.json):
`z check`, `z smoke`, `z build`, `z test`, or `z x <task>` from `_ann`, or
`z in ann build` from the z workspace root. Use `..\z.exe <command>` if z is not on
PATH. Those commands invoke z's `tclsh90` tool with `tools/x.tcl`, so ann
keeps its Tcl task-runner contract while z stays the single outer door and
owns the runtime payloads.

Treat `z.exe` as the z workspace's only public entry point. Do not invoke `..\r\...`,
`..\t\...`, `..\s\...`, or vendored binaries
directly from docs, scripts, or agent commands; use `z <tool>`,
`z <project-command>`, or the commands declared in [`z.json`](z.json).
When running from PowerShell and passing quoted POSIX shell/awk/sed programs,
prefer PowerShell's stop-parsing form, e.g.
`z --% bash -c "awk '{print NR \":\" toupper($0)}' file"`.
Strongly avoid PowerShell and Windows cmd for z-backed work. Use them only as
the outer process needed to launch `z.exe`; do not add `.ps1`, `.bat`, `.cmd`,
or cmd/PowerShell recipes for durable workflows. Prefer
`z <tool>`, `z bash -c "..."` for transient POSIX pipelines, or named project
commands in [`z.json`](z.json).

## Read the Tcl/Tk 9 manual first

The **complete Tcl 9 & Tk 9 manual** (Tcl + Tk commands, the C API, and
`tclsh`/`wish`) ships as Markdown inside `..\r\tcltk\9.0.4\manual\` (`z x env` prints
the resolved Tcl/Tk payload path). It is the **authoritative reference** for this
codebase — prefer it over training-data recall, which may be stale or describe
Tcl 8.x behavior.

- **Before writing or changing any Tcl/Tk code — or the C that drives the
  embedded interpreter** (`Tcl_CreateObjCommand`, `Tcl_ThreadQueueEvent`,
  `Tk_PhotoPutBlock`, `TclZipfs_AppHook`, …) — **consult the manual.** Start at
  `..\r\tcltk\9.0.4\manual\INDEX.md` and read the pages relevant to your change (each
  file is named after the command/function, e.g. `commands/wm.md`,
  `commands/ttk_entry.md`, `c-api/Tcl_CreateThread.md`).
- Grep the tree to find the right page; open the few that matter.

## The build is native (custom C23 entry point)

`ann.exe` is a **real native Windows PE**: a custom C23 entry point
(`src/ann_main.c`) with **Tcl, Tk, and SQLite statically linked in**, plus the
Tcl/Tk script libraries and `ann.tcl` riding inside an appended zipfs image.
`ann.tcl` is ordinary Tcl, unchanged by the C entry point. The platform layer
(global hotkey, icon extraction, window enumeration, shell actions) is C; the UI
composition and the fully-programmable config are Tcl; SQLite owns the catalog,
the FTS5 prefilter, and frecency.

- **`z build-sqlite`** compiles z's SQLite amalgamation **sources** into
  `build/libsqlite3.a` (FTS5 + math, one UCRT model) — a project build product.
  Run once; the native build links it.
- **`z build`** builds `ann.exe` (compile `src/ann_main.c` + the static
  extensions in `src/`; the PE icon/manifest/version `.rc`/`.manifest`/`.ico` are
  **generated from Tcl** by `tools/genres.tcl` + `tools/mkico.tcl` into the
  gitignored `build/`, then `windres`'d; link z's static `tcl9s` libs
  + `build/libsqlite3.a` + the Win32 system libs; append the zipfs payload).
- The architecture, the static-link recipe, and the pitfalls are in
  [`docs/DESIGN.md`](docs/DESIGN.md) (§3 threading, §4 stack & static linking).
- Verify the exe headlessly: `ann.exe --selftest [report.txt]` writes a report
  file (GUI subsystem = no stderr); `z test` runs the in-process suite. **Never**
  debug a GUI build by running it on a failure — it can rain modal dialogs; read
  the file-report selftest, or build a console-subsystem twin (gcc without
  `-mwindows`) whose stderr is text.

## Language policy (same as the build-environment doc)

Only **Tcl 9** (the UI `ann.tcl`, all `tools/*.tcl`, `tests/*`) and **C23** (the
host + platform layer `src/*.c`, built with z's gcc) for committed
project code and durable tooling. No bash scripts, **no PowerShell**, no Python,
no project-local `.cmd` bootstrap. For transient agent-side shell pipelines,
prefer `z bash -c "..."` through z over PowerShell and Windows cmd; do not
commit that as ann tooling.

## General

- Use Tcl as much as possible for project tooling in this repo.
- Latency is the product (DESIGN §1): judge changes against keystroke-to-result.
  Do not add per-keystroke allocation, polling loops, or background taxes.
- Double-check UI/behavior changes through the exact user-facing interaction path
  before reporting them fixed.
- Be precise about verification: only claim behavior that was actually checked.
