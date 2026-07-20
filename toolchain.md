# ann build environment

How `ann` is built, tested, and kept portable with z-owned runtime payloads.
`ann` is a C23 host that statically embeds Tcl/Tk 9.0.4 (GUI + programmable
config) and SQLite/FTS5 (catalog + search + frecency).

## Principle

MSYS2, Tcl/Tk, SQLite sources, twapi, and the Tcl/Tk manual are regular parts of
z unless a concrete reason appears to keep one of them project-local. ann owns
source, task definitions, generated build products, runtime state, and release
artifacts. z owns the developer runtime payloads.

Current z payloads:

| Need | In z |
|---|---|
| MSYS2 UCRT64 gcc/binutils/windres | `..\r\msys2\` |
| Tcl/Tk 9 shared + static builds | `..\r\tcltk\9.0.4\{tcl9,tcl9s}` |
| Tcl/Tk script-library payload | `..\r\tcltk\9.0.4\tcllib\` |
| Tcl/Tk 9 + C-API manual | `..\r\tcltk\9.0.4\manual\` |
| Tcl/Tk source | `..\r\tcltk\9.0.4\tclsrc\` |
| SQLite amalgamation sources | `..\r\sqlite\3.51.0\` |
| twapi | `..\r\twapi\5.2.0\` |

## z front door

The committed [`z.json`](z.json) maps ann commands to z's `tclsh90` tool:

```json
{ "commands": { "build": ["tclsh90", "tools/x.tcl", "build"] } }
```

That keeps the developer boundary clean: invoke `z build`, `z test`, `z x env`,
and so on. Do not call paths under `..\r`, `..\t`, or `..\s`
directly from project docs or automation.

From `_ann`, use `..\z.exe <command>` or plain `z <command>` if `C:\dev`
is on PATH. From the z workspace root, use `z in ann <command>`.

## Resolution

`tools/x.tcl` discovers z payloads in this order:

1. Explicit environment override (`Z_TCLTK`, `Z_MSYS2`, `Z_SQLITE`,
   `Z_TWAPI`) — optional per-payload variables read by `tools/x.tcl` itself;
   `z.exe` does not set them.
2. The z workspace root from `Z_ROOT` (which `z.exe` exports).
3. Hosted layout: project parent `../r/...`.
4. Historical fallback probes for the pre-rename transition layouts: embedded
   `zmal/r/...` or sibling `../zmal/r/...` (kept so old checkouts still resolve).

`z x env` prints the resolved paths. `z check` verifies the required payloads.

## Containment

The z payloads are read-only from ann's point of view. Everything ann
produces lands inside `ann/`: compiled objects, `build/libsqlite3.a`, dev
`build/*.dll` extensions, generated PE resources, zipfs staging, exes, `dist/`,
`ann.config.tcl`, `ann.db`, `ann.log`, screenshots, and toolcheck temp files.

## Tcl/Tk version: always 9

MSYS2's `ucrt64` may include Tcl/Tk 8.6 for its own packages. ann never uses it.
Tooling invokes z's explicit Tcl/Tk 9 executables (`tclsh90`, `wish90`,
`tclsh90s`, `wish90s`) and puts Tcl/Tk 9 ahead of MSYS2 on PATH. C builds pass
`-I..\r\tcltk\9.0.4\tcl9\include` through the resolved path, never a bare
system include.

## Common commands

```
z check          run x toolcheck
z smoke          fast in-process suite
z build          build the native ann.exe
z build-con      build the console-subsystem debug twin
z test           full in-process suite
z selftest       ann.exe --selftest
z hktest         global-hotkey end-to-end test
z launchtest     launch end-to-end test
z shot out.png   screenshot the popup
z dist           build + selftest-gate + stage dist/ann.exe
z x help         pass through to the Tcl task runner
```

## Build products

`z build-sqlite` compiles z's SQLite amalgamation into
`build/libsqlite3.a`, a project build product. `z build` then compiles the C23
host and extensions with z's MSYS2 UCRT64, links z's Tcl/Tk static libs and
`build/libsqlite3.a`, generates PE resources into `build/`, and appends the
zipfs payload with `package.tcl`.

The shipped product remains simple: `ann.exe` is self-contained, imports only
system DLLs, and does not need z to run.
