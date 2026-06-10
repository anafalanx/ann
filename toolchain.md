# ann toolchain

How `ann` is built, tested, packaged, and kept portable, plus the rules that keep
it that way. `ann` is a C23 host that statically embeds Tcl/Tk 9 (GUI +
programmable config) and SQLite/FTS5 (catalog + search + frecency). The whole
project, toolchain included, is **self-contained and copy-paste portable**: drop
the folder onto any Windows 11 machine and everything works, with no installs and
no dependency on anything already present on the system. (It is deliberately a
true copy — `.toolchain/` contains real files, never a junction/symlink to a
sibling project.)

## Language policy

The project and its tooling use **only two languages**, plus one boot script:

| Allowed | Used for |
|---|---|
| **Tcl 9** | the UI (`ann.tcl`), all tooling (`tools/*.tcl`), tests (`tests/*`) |
| **C23** | the native host + platform layer (`src/*.c`), built with the vendored gcc |
| **classical Windows `cmd`** | exactly one file: `x.cmd` |

No bash, **no PowerShell**, no Python, nothing else. The single `.cmd` file exists
only because PATH has to be set *before* Tcl is reachable (a chicken-and-egg the
shell must solve). It is deliberately tiny; all real logic lives in Tcl.

The native `ann.exe` needs Windows PE resources — an icon, an application
manifest, and version info — which are normally `.rc`/`.ico`/`.manifest` files.
`ann` keeps them **out of the committed source**: they are *generated from Tcl* at
build time (`tools/genres.tcl`, `tools/mkico.tcl`) into the gitignored `build/`,
and compiled by the already-vendored `windres`. So the policy holds — the repo is
Tcl + C + one `.cmd`, with no new languages or dependencies.

## What's vendored: `.toolchain/`

Everything the project needs lives here. It is **gitignored** (large,
machine-built), so it travels by *copy-paste of the folder*, not by `git clone`.

| Path | What | Version |
|---|---|---|
| `.toolchain/tcl9/` | Tcl/Tk 9 **shared** build: `tclsh90.exe`, `wish90.exe`, stubs (`lib/libtclstub.a`), headers (`include/tcl.h`, `tk.h`) | 9.0.3 |
| `.toolchain/tcl9s/` | Tcl/Tk 9 **static**, DLL-free: link libs `lib/libtcl90.a` + `libtcl9tk90.a` (the native `x build` links these into ann.exe), plus `tclsh90s.exe` / `wish90s.exe` (carry the script-library zipfs the packager reuses) | 9.0.3 |
| `.toolchain/sqlite/` | the **SQLite amalgamation** (`sqlite3.c`/`.h`/`ext.h`) + the built `libsqlite3.a` (FTS5 + math). `x build-sqlite` compiles the lib. | 3.51.0 |
| `.toolchain/msys64/ucrt64/` | gcc (C23), binutils, gdb, windres (MSYS2 UCRT64) | gcc 16.1.0 |
| `.toolchain/msys64/usr/bin/` | `curl.exe` etc. (used by the fetch tasks) | n/a |
| `.toolchain/twapi-dl/` | twapi: Windows API extension for the GUI tooling (screenshots) | 5.2.0 |
| `.toolchain/git/` | MinGit: git-for-windows' slim, GUI-less build | 2.54.0 |

`x toolcheck` reports the status and version of each.

### Tcl/Tk version: always 9, never msys64's 8.6

MSYS2's `ucrt64` bundles its own **Tcl/Tk 8.6**. It is left intact, but `ann`
never uses it. The rule:

- Tooling invokes the interpreter only through the explicit vendored paths
  `tcl9/bin/tclsh90.exe` / `wish90.exe` (and `tcl9s` for packaging), **never a
  bare `tclsh`/`wish`**, which on PATH could resolve to the 8.6 build.
- PATH puts `tcl9/bin` **ahead of** `msys64/ucrt64/bin`.
- C builds pass `-I.toolchain/tcl9/include` so `tcl.h` is the 9.x header.

`x toolcheck --deep` enforces this: it confirms the live interpreters are 9.0.x
and that a freshly compiled C extension links the 9.0 stubs and reports a 9.x
`tcl.h`.

## Ignition: `x.cmd`

The single entry point. It resolves the toolchain **relative to its own
location** (`%~dp0`), so the folder is relocatable to any path, then hands off to
the Tcl task runner:

```cmd
set "PATH=%TC%\tcl9\bin;%TC%\msys64\ucrt64\bin;%PATH%"
if exist "%TC%\git\cmd" set "PATH=%TC%\git\cmd;%PATH%"   &:: git is optional
"%TC%\tcl9\bin\tclsh90.exe" "%ANN_ROOT%tools\x.tcl" %*
```

`x shell` (and a double-click in Explorer) opens an interactive `cmd` with PATH
set; if the core Tcl is missing, `x.cmd` prints a clear message instead of a
cryptic error.

## Task runner: `tools/x.tcl`

All tooling. Run `x help`:

```
x build-sqlite       compile .toolchain/sqlite/libsqlite3.a (FTS5 + math)
x build [out]        build the native ann.exe (custom C23 entry, static Tcl+Tk+SQLite)
x build-con [out]    the console-subsystem debug twin (stderr is readable text)
x build-ext          compile src/*.c -> build/*.dll dev extensions
x run [args]         launch the built ann.exe (builds it first if missing)
x run-dev [args]     launch ann under wish + the dev .dll extensions (fast Tcl loop)
x selftest [exe]     ann.exe --selftest, print the report; exit code = result
x test [--fast]      in-process test suite (tcltest + Tk event generate)
x hktest             end-to-end: synthesize the global hotkey, verify the toggle
x launchtest         end-to-end: index, type a query, Enter, verify the app starts
x probe <f> [args]   run an ad-hoc verification script under the CONSOLE tclsh
x shot <out> [args]  screenshot the popup (twapi + PrintWindow, all-Tcl)
x dist               build + selftest-gate + put the release ann.exe in dist/
x icon               regenerate resources/icon*.png
x toolcheck [--prep] check the vendored toolchain (--prep fetches/builds, --deep functional)
x shell              a shell with the vendored toolchain on PATH
x env                print the resolved toolchain paths + versions
```

`x.tcl` re-asserts PATH itself (so it is robust when run directly with the
vendored `tclsh90.exe`) and uses a **cheap per-command guard**: each task declares
only the one or two tools it needs (`need gcc tclsh`), a microsecond `file
exists`, *not* a full toolchain scan on every invocation. The thorough scan is
`x toolcheck`, on demand.

## SQLite: `x build-sqlite`

SQLite ships into `ann.exe` as a **static archive compiled from the amalgamation**
in one UCRT model (no DLL, no mixing runtimes). `x build-sqlite` compiles
`.toolchain/sqlite/sqlite3.c` → `libsqlite3.a` with the launcher's required
features:

```
gcc -std=gnu23 -O2 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS \
    -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
    -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_DQS=0 -DSQLITE_OMIT_DEPRECATED \
    -c sqlite3.c -o sqlite3.o   &&   gcc-ar rcs libsqlite3.a sqlite3.o
```

`FTS5` powers the trigram substring prefilter (DESIGN §5/§6); `MATH_FUNCTIONS`
gives `exp()` for the frecency decay (DESIGN §6.4); `THREADSAFE=1` because the
indexer thread holds the single writer connection while the GUI thread reads
(DESIGN §3.2). The task is idempotent — it skips when `libsqlite3.a` is newer than
the source.

## Build: `x build` (native ann.exe)

`x build` produces one self-contained **native** `ann.exe` from our own C23 entry
point — a real Windows PE, not a stock interpreter with scripts bolted on. Tcl,
Tk, and SQLite are statically linked in; the Tcl/Tk script libraries + `ann.tcl`
ride inside an appended zipfs image. Steps (`tools/x.tcl` `task_build`):

1. `tools/genres.tcl` generates `build/ann.rc` + `build/ann.exe.manifest` from Tcl
   (version from `ann.tcl`'s `variable version`; **Per-Monitor-V2** DPI, UTF-8
   code page, long-path aware — DESIGN §9.8), and `tools/mkico.tcl` packs
   `resources/icon*.png` into `build/ann.ico`. Gitignored build artifacts.
2. `windres` compiles `build/ann.rc` (icon + manifest + VERSIONINFO) →
   `build/ann.res`.
3. gcc compiles `src/ann_main.c` (the entry point) and the static extensions
   (`src/ann_db.c`, `src/ann_plat.c`), built `-municode -DUNICODE -DSTATIC_BUILD
   -std=gnu23` with the `ANN_STATIC_*` switches.
4. gcc links them + `ann.res` against the **static** Tcl/Tk libs in
   `.toolchain/tcl9s/lib` + `libsqlite3.a` + the Win32 system libs the platform
   layer needs (DESIGN §4.3: `dwmapi shell32 ole32 oleaut32 uuid propsys shlwapi
   powrprof user32 gdi32 …`), with `-mwindows` (GUI subsystem) and
   `--gc-sections`; then `strip`. Headers come from `.toolchain/tcl9/include`
   (the static tree ships none; they are ABI-identical 9.0.3).
5. `package.tcl` (under static `tclsh90s`) appends the zipfs payload onto our exe
   — `main.tcl` (= `ann.tcl`), `resources/`, `tcl_library/`, `tk_library/`. **No
   DLL is embedded**; SQLite and the platform layer are compiled in. At boot,
   `TclZipfs_AppHook` self-mounts the appended zip at `//zipfs:/app` and runs
   `main.tcl`.

The PE **icon + manifest + version info** are baked at link time by windres and
survive the zipfs append because the zip lands *after* the PE image. `/ann.exe`
and `/build/` are gitignored; rebuild them, ship the exe via releases.

### The static-link rules that matter (DESIGN §4)

- **One runtime model (UCRT) across all objects.** Tcl/Tk, SQLite, and our C are
  all built in the same UCRT64 environment. Never link a `msvcrt`-built archive
  into the UCRT host (heap/`FILE*`-crossing crashes).
- **No stubs for the host.** `ann.exe` is a host, not an extension: it does
  **not** define `USE_TCL_STUBS` and does **not** link `tclstub`/`tkstub`. It
  statically links the full `libtcl90.a` + `libtcl9tk90.a` and calls the real
  entry points. (Dev `.dll` extensions built by `x build-ext` *do* use stubs.)
- **`TclZipfs_AppHook` must run first**, before `Tcl_FindExecutable`/the interp,
  or `Tk_Init` cannot find `init.tcl`/`tk.tcl`. The smoke test for the whole
  static-build effort: does `Tk_Init` return `TCL_OK` with no external library
  directory present? (DESIGN §4.2.)
- **`Tcl_Size`, not `int`, for all lengths** (Tcl 9.0 widened them to 64-bit).
- **`#define INITGUID` in exactly one `.c`** (the TU that `CoCreateInstance`s the
  ApplicationActivationManager / uses `PKEY_*`); every other TU stays without it
  to avoid duplicate GUID symbols.

### Testing the exe safely

`ann.exe --selftest [report.txt]` is a headless mode that boots the app, writes a
result file, and exits (a GUI-subsystem exe has no stderr). Verify the appended
zipfs structure (`main.tcl`, `tcl_library/init.tcl`, `tk_library/tk.tcl`,
`resources/`) is intact. **NEVER debug by running a GUI build directly on a
failure** — it can rain modal dialogs; read the file-report selftest, or build a
console-subsystem twin (gcc without `-mwindows`) whose stderr is text.

## C23 ↔ Tcl extensions

The platform layer and the SQLite bridge are exposed to Tcl as ordinary commands.
The native `ann.exe` **statically links them in** (registered in `ann_main.c`'s
app-init). During development every `src/*.c` extension also builds as a
standalone `.dll` against the Tcl **stubs** (`x build-ext`) so `x run` can load
them under stock `wish90.exe` — the same dev/prod split els uses. A dev `.dll`
imports only `KERNEL32` + the UCRT and is built `-static-libgcc`.

## Tests: `tests/`

White-box and **in-process**: `tcltest` drives the real Tk widgets via Tk's
`event generate`, with full introspection. `ann.tcl`'s `main` is guarded by an
`info script eq argv0` check, so the suite sources the UI without launching it.
Run `x test`.

## Distribution & portability

**Copy-paste the whole folder.** Because `.toolchain/` (gitignored) travels with
the folder, dropping it onto a fresh Windows 11 machine just works: no install, no
provisioning, no network. Portable **by construction**: every path resolves
relative to the invoking script (`%~dp0` in `x.cmd`, `[info script]` in the Tcl).
The shipped `ann.exe` itself imports only system DLLs (UCRT is an OS component on
Win10/11), so it runs from a USB stick (DESIGN §13).
