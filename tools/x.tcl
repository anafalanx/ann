#!/usr/bin/env tclsh
# tools/x.tcl — the ann task runner.  ALL project tooling lives here (Tcl), plus
# C built by the vendored gcc.  Normally invoked through x.cmd (which sets PATH to
# the vendored toolchain first); this script re-asserts PATH itself so it is also
# robust when run directly with the vendored tclsh.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
# Discover the pinned bundle in mal's store: read toolchain.pin (one line: the
# bundle name) and walk ancestors for X/<pin>/ (verified by its BUNDLE.manifest
# marker). No absolute path is assumed — mal and this whole tree can live
# anywhere and be renamed freely. This is the canonical rae/els/ann discovery.
proc discover_store {root} {
    set pinfile [file join $root toolchain.pin]
    if {![file exists $pinfile]} {
        error "no toolchain.pin in $root — a mal project pins its bundle by name"
    }
    set fh [open $pinfile r] ; set pin [string trim [read $fh]] ; close $fh
    if {$pin eq ""} { error "toolchain.pin is empty in $root" }
    set dir $root
    for {set i 0} {$i < 8} {incr i} {
        set cand [file join $dir X $pin]
        if {[file exists [file join $cand BUNDLE.manifest]]} { return $cand }
        set up [file dirname $dir]
        if {$up eq $dir} break
        set dir $up
    }
    error "bundle '$pin' not found in any ancestor X/ store from $root —\
           is this project inside the mal folder, and the bundle present?"
}
set ROOT [script_root]
set TC   [discover_store $ROOT]

foreach {var rel marker} {
    TCL_LIBRARY {tcllib tcl_library} init.tcl
    TK_LIBRARY  {tcllib tk_library}  tk.tcl
} {
    set p [file join $TC {*}$rel]
    if {[file exists [file join $p $marker]]} { set ::env($var) [file nativename $p] }
}
set pkgpaths {}
foreach p [list [file join $TC twapi-dl twapi-5.2.0] \
                [file join $TC twapi-dl] \
                [file join $ROOT build]] {
    if {[file isdirectory $p]} { lappend pkgpaths $p }
}
foreach p [glob -nocomplain [file join $TC tcl9 lib *]] {
    if {[file isdirectory $p]} { lappend pkgpaths $p }
}
if {[llength $pkgpaths]} {
    if {[info exists ::env(TCLLIBPATH)] && $::env(TCLLIBPATH) ne ""} {
        set ::env(TCLLIBPATH) [concat $pkgpaths $::env(TCLLIBPATH)]
    } else {
        set ::env(TCLLIBPATH) $pkgpaths
    }
    set auto_path [concat $pkgpaths $auto_path]
}

# Vendored toolchain wins on PATH (idempotent with x.cmd).  Tcl/Tk 9 BEFORE
# msys64 (which ships its own Tcl/Tk 8.6 that ann must never use).
set vbins {}
foreach b [list [file join $TC tcl9 bin] [file join $TC msys64 ucrt64 bin]] {
    if {[file isdirectory $b]} { lappend vbins [file nativename $b] }
}
if {[llength $vbins]} { set ::env(PATH) "[join $vbins {;}];$::env(PATH)" }
if {![info exists ::env(MSYSTEM)]} { set ::env(MSYSTEM) UCRT64 }

# ---- path helpers -------------------------------------------------------
proc P   {args} { return [file join $::ROOT {*}$args] }
proc TCp {args} { return [file join $::TC   {*}$args] }
# RULE: always go through these explicit vendored Tcl/Tk 9 paths — NEVER a bare
# `tclsh`/`wish`, which on PATH could resolve to msys64's Tcl/Tk 8.6.
proc tclsh   {} { return [TCp tcl9 bin tclsh90.exe] }
proc wish    {} { return [TCp tcl9 bin wish90.exe] }
proc tclshs  {} { return [TCp tcl9s bin tclsh90s.exe] }
proc gcc     {} { return [TCp msys64 ucrt64 bin gcc.exe] }
proc gcc-ar  {} { return [TCp msys64 ucrt64 bin gcc-ar.exe] }
proc windres {} { return [TCp msys64 ucrt64 bin windres.exe] }
proc strip-exe {} { return [TCp msys64 ucrt64 bin strip.exe] }
# libsqlite3.a is a PROJECT build product (compiled from the bundle's read-only
# sqlite sources by `x build-sqlite`); it lives in the project's build/, never in
# the bundle (DESIGN sec.3 — products stay in the project).
proc sqlitelib {} { return [P build libsqlite3.a] }

# Stream a child's stdout/stderr through to ours; propagate the child's own exit
# code (a failing test / missing tool is a NORMAL signal), re-raise a genuine
# exec failure.
proc stream {args} {
    if {[catch {exec {*}$args >@ stdout 2>@ stderr} err opts]} {
        if {[lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
            exit [lindex [dict get $opts -errorcode] 2]
        }
        return -options $opts $err
    }
}

# Cheap per-command guard: a task declares the tool(s) it needs; we only check
# those exist (a microsecond `file exists`), and point at `x toolcheck`.
proc tool_path {tool} {
    switch $tool {
        tclsh { return [tclsh] }
        wish  { return [wish] }
        gcc   { return [gcc] }
        twapi { return [TCp twapi-dl twapi-5.2.0 pkgIndex.tcl] }
        default { return "" }
    }
}
proc need {args} {
    foreach tool $args {
        set p [tool_path $tool]
        if {$p eq "" || ![file exists $p]} {
            error "required tool '$tool' is missing — the pinned bundle is incomplete (run: mal verify <pin>)"
        }
    }
}

# ---- tasks --------------------------------------------------------------
proc task_help {args} {
    puts {ann task runner — usage: x <command> [args]

  build-sqlite [--force]  compile build/libsqlite3.a (FTS5 + math) from the bundle's sqlite sources
  build [out]        build the native ann.exe — a custom C23 entry point with
                     Tcl+Tk+SQLite statically linked in and PE icon/manifest/
                     version baked via windres (see toolchain.md)
  build-con [out]    build ann-con.exe — the console-subsystem debug twin whose
                     stderr is real text (startup/runtime errors are readable)
  build-ext          compile src/*.c -> build/*.dll dev extensions (for x run-dev)
  run [args]         launch the built ann.exe (builds it first if missing)
  run-dev [args]     launch ann under wish + the dev .dll extensions (fast Tcl loop)
  selftest [exe]     run ann.exe --selftest and print the headless report
  shot <out> [args]  screenshot the popup to <out>.png (twapi + PrintWindow)
  test [--fast]      in-process test suite (tcltest + Tk event generate)
  hktest             end-to-end global-hotkey test: synthesize Alt+Space, check toggle
  launchtest         end-to-end launch test: index, type a query, Enter, check app starts
  probe <f> [args]   run an ad-hoc verification script under the CONSOLE tclsh
                     with the dialog-quiet preamble (tests/probe.tcl) preloaded
  icon               regenerate resources/icon*.png (the key app icon)
  colors [name ...]  browse Tk's named colors (swatches + hex)
  dist               build + selftest-gate + put the release exe in dist/
  toolcheck [--deep] check the pinned bundle has what ann needs (--deep runs
                     functional checks: compile C, load Tk, link SQLite, run)
  shell              open a shell with the vendored toolchain on PATH
  env                print the resolved toolchain paths + versions
  help               this message}
}

proc task_env {args} {
    puts "ROOT  = $::ROOT"
    foreach {label path} [list tclsh [tclsh] wish [wish] gcc [gcc] sqlite-lib [sqlitelib]] {
        puts [format "  %-10s %s  (%s)" $label $path \
            [expr {[file exists $path] ? "ok" : "MISSING"}]]
    }
    catch {puts "  gcc       [exec [gcc] -dumpversion]"}
    catch {puts "  tcl       [exec [tclsh] << {puts [info patchlevel]}]"}
}

proc task_toolcheck {args} { stream [tclsh] [P tools toolcheck.tcl] {*}$args }

# Compile the SQLite amalgamation into a static lib (FTS5 + math, one UCRT model).
# Idempotent: skips when libsqlite3.a is newer than the source unless --force.
proc task_build-sqlite {args} {
    need gcc
    set src [TCp sqlite sqlite3.c]
    set lib [sqlitelib]
    if {![file exists $src]} { error "sqlite amalgamation missing in the bundle: $src" }
    if {[file exists $lib] && [file mtime $lib] >= [file mtime $src] && "--force" ni $args} {
        puts "libsqlite3.a up to date"; return
    }
    file mkdir [P build]
    set obj [P build sqlite3.o]
    puts "cc  sqlite3.c -> libsqlite3.a (FTS5 + math)"
    stream [gcc] -std=gnu23 -O2 \
        -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS \
        -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
        -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_DQS=0 -DSQLITE_OMIT_DEPRECATED \
        -c $src -o $obj
    catch {file delete -force $lib}
    stream [gcc-ar] rcs $lib $obj
    file delete -force $obj
    puts "built [file nativename $lib]  ([file size $lib] bytes)"
}

# Compile every src/*.c (except the entry point ann_main.c) into build/<name>.dll
# against the Tcl stubs, and emit a pkgIndex.tcl so `package require <name>` works.
# Init proc = Titlecased name (anndb.c -> Anndb_Init), matching Tcl's load.
proc task_build-ext {args} {
    need gcc tclsh
    if {![file exists [sqlitelib]]} { task_build-sqlite }
    set inc [TCp tcl9 include]
    set lib [TCp tcl9 lib]
    set sqinc [TCp sqlite]
    file mkdir [P build]
    set sources {}
    foreach s [lsort [glob -nocomplain [P src *.c]]] {
        if {[file tail $s] eq "ann_main.c"} continue
        lappend sources $s
    }
    if {![llength $sources]} { puts "no src/*.c to build"; return }
    set idx [open [P build pkgIndex.tcl] w]
    puts $idx "# auto-generated by `x build-ext` — do not edit"
    foreach src $sources {
        set name [file rootname [file tail $src]]
        set dll  [P build $name.dll]
        set init [string totitle $name]
        puts "cc  [file tail $src] -> build/$name.dll"
        # annicon drives Tk's photo C API -> needs the Tk stubs as well (the
        # static tree's libtkstub.a; ABI-identical 9.0.3). Others are Tcl-only.
        set tkflags {}
        if {$name eq "annicon"} {
            set tkflags [list -DUSE_TK_STUBS -L[TCp tcl9s lib] -ltkstub]
        }
        stream [gcc] -std=gnu23 -O2 -shared -DUSE_TCL_STUBS -D_WIN32_WINNT=0x0A00 \
            -I$inc -I$sqinc $src -o $dll -L$lib -ltclstub {*}$tkflags [sqlitelib] \
            -static-libgcc -ldwmapi -lshlwapi -lole32 -loleaut32 -luuid \
            -lshell32 -luser32 -lgdi32 -lpowrprof -ladvapi32
        puts $idx "package ifneeded $name 0.1 \[list load \[file join \$dir $name.dll\] $init\]"
    }
    close $idx
    puts "built [llength $sources] extension(s); wrote build/pkgIndex.tcl"
}

# Build the native ann.exe (THE canonical build): a custom C23 entry point
# (src/ann_main.c) statically linked against Tcl+Tk (the bundle's tcl9s) + SQLite
# (libsqlite3.a) with the platform layer compiled in and the PE resources baked
# via windres, then the zipfs payload (tcl_library/tk_library/main.tcl/resources)
# appended.  Headers come from the SHARED tree (tcl9/include); libs from the
# STATIC tree (tcl9s/lib).  See toolchain.md / DESIGN §4.
proc task_build {args} {
    need gcc tclsh
    if {![file exists [tclshs]]} { error "static tclsh missing in the bundle (tcl9s/bin) — run `mal verify <pin>`" }
    if {![file exists [sqlitelib]]} { task_build-sqlite }
    # --console builds the GUI-error-proof debug twin (console subsystem, stderr is
    # real text) named ann-con.exe; otherwise the shipped GUI ann.exe.
    set console 0 ; set out ""
    foreach a $args {
        if {$a eq "--console"} { set console 1 } elseif {$out eq ""} { set out $a }
    }
    if {$out eq ""} { set out [P [expr {$console ? "ann-con.exe" : "ann.exe"}]] }
    set inc  [TCp tcl9 include]
    set sqinc [TCp sqlite]
    set libd [TCp tcl9s lib]
    set tag  [expr {$console ? "con" : ""}]
    file mkdir [P build]
    # Tk's Win32 deps (proven set) + ann's platform libs (DESIGN §4.3).
    set syslibs {
        -lnetapi32 -lkernel32 -luser32 -ladvapi32 -luserenv -lws2_32
        -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luuid -lole32
        -loleaut32 -lwinspool -ldwmapi -lshlwapi -lpropsys -lpowrprof -luxtheme
    }
    # 1. generate PE resource inputs from Tcl (icon needs the PNGs first).
    if {![file exists [P resources icon.png]]} {
        need wish ; puts "gen  resources/icon*.png" ; stream [wish] [P tools icon.tcl]
    }
    puts "gen  build/ann.rc + ann.exe.manifest + ann.ico"
    stream [tclsh] [P tools genres.tcl] [P build]
    stream [tclsh] [P tools mkico.tcl] [P build ann.ico] \
        [P resources icon16.png] [P resources icon32.png] [P resources icon.png]
    # 2. compile resources (icon + manifest + VERSIONINFO) -> COFF object.
    puts "windres build/ann.rc -> build/ann.res"
    stream [windres] --include-dir [P build] --include-dir $inc \
        [P build ann.rc] -O coff -o [P build ann.res]
    # 3. compile the entry point (UNICODE + STATIC) and the static extensions.
    set conflag [expr {$console ? {-DANN_CONSOLE} : {}}]
    puts "cc  ann_main.c + anndb.c + annplat.c + annhotkey.c + annindex.c + annicon.c[expr {$console ? { (console twin)} : {}}]"
    stream [gcc] -std=gnu23 -O2 -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
        -D_WIN32_WINNT=0x0A00 -D__USE_MINGW_ANSI_STDIO=1 {*}$conflag \
        -DANN_STATIC_DB -DANN_STATIC_PLAT -DANN_STATIC_HOTKEY -DANN_STATIC_INDEX \
        -DANN_STATIC_ICON \
        -ffunction-sections -fdata-sections \
        -c [P src ann_main.c] -o [P build ann_main$tag.o] -I$inc
    foreach {cfile extra} {
        anndb.c     {sqinc}
        annplat.c   {}
        annhotkey.c {}
        annindex.c  {sqinc}
        annicon.c   {}
    } {
        set xinc [expr {$extra eq "sqinc" ? [list -I$sqinc] : {}}]
        stream [gcc] -std=gnu23 -O2 -DSTATIC_BUILD=1 -D_WIN32_WINNT=0x0A00 \
            -ffunction-sections -fdata-sections \
            -c [P src $cfile] -o [P build [file rootname $cfile].o] -I$inc {*}$xinc
    }
    # 4. link: GUI (or console) subsystem; Tk before Tcl before stub; SQLite; sys libs.
    set bare [P build ann-bare$tag.exe]
    set subsys [expr {$console ? {} : {-mwindows}}]
    puts "ld  -> [file tail $bare]"
    stream [gcc] -municode {*}$subsys -static -Wl,--gc-sections \
        [P build ann_main$tag.o] [P build anndb.o] [P build annplat.o] [P build annhotkey.o] \
        [P build annindex.o] [P build annicon.o] [P build ann.res] \
        [file join $libd libtcl9tk90.a] [file join $libd libtcl90.a] \
        [file join $libd libtclstub.a] [sqlitelib] {*}$syslibs -o $bare
    catch {stream [strip-exe] $bare}      ;# shrink before the payload append
    # 5. append the zipfs payload onto OUR exe.
    stream [tclshs] [P tools package.tcl] --wrapper $bare $out
}

# The console-subsystem twin: identical app, but stderr is real text so startup
# and runtime errors are READABLE (never a modal dialog). The everyday debug path.
proc task_build-con {args} { task_build --console {*}$args }

proc task_run {args} {
    set exe [P ann.exe]
    if {![file exists $exe]} { puts "ann.exe not built — building..." ; task_build }
    exec $exe {*}$args &
    puts "launched ann"
}

proc task_run-dev {args} {
    need wish
    if {![file exists [sqlitelib]]} { task_build-sqlite }
    if {![file exists [P build anndb.dll]] || ![file exists [P build annplat.dll]]} { task_build-ext }
    exec [wish] [P ann.tcl] {*}$args &
    puts "launched ann (dev: wish + dev dlls)"
}

proc task_selftest {args} {
    set exe [lindex $args 0] ; if {$exe eq ""} { set exe [P ann.exe] }
    if {![file exists $exe]} { error "exe not found: $exe — run `x build`" }
    set rpt [P build selftest.txt]
    catch {file delete -force $rpt}
    set rc [catch {exec $exe --selftest $rpt} err opts]
    if {![file exists $rpt]} { error "no selftest report written by $exe" }
    set fh [open $rpt r] ; puts -nonewline [read $fh] ; close $fh
    # the exe exits 1 on FAIL — propagate so callers/scripts can rely on it
    if {$rc && [lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
        exit [lindex [dict get $opts -errorcode] 2]
    }
}

proc task_test {args} {
    need tclsh
    stream [tclsh] [P tests run.tcl] {*}$args
}

proc task_probe {args} {
    need tclsh
    if {![llength $args]} { error "usage: x probe <script.tcl> \[args ...]" }
    set script [lindex $args 0]
    if {![file exists $script]} { error "probe script not found: $script" }
    set pp [string map {\\ /} [P tests probe.tcl]]
    set sp [string map {\\ /} [file normalize $script]]
    set boot "set ::argv0 {$sp}\nset ::argv {[lrange $args 1 end]}\nsource {$pp}\nsource {$sp}"
    if {[catch {exec [tclsh] << $boot >@ stdout 2>@ stderr} err opts]} {
        if {[lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
            exit [lindex [dict get $opts -errorcode] 2]
        }
        return -options $opts $err
    }
}

proc task_hktest {args} {
    need tclsh twapi
    if {![file exists [P ann.exe]]} { puts "building ann.exe..." ; task_build }
    stream [tclsh] [P tools hktest.tcl] [P ann.exe]
}

proc task_launchtest {args} {
    need tclsh twapi
    if {![file exists [P ann.exe]]} { puts "building ann.exe..." ; task_build }
    stream [tclsh] [P tools launchtest.tcl] [P ann.exe]
}

proc task_icon {args} { need wish ; stream [wish] [P tools icon.tcl] {*}$args }

# Browse Tk's named colors (swatches + hex, filter, click-to-copy) — copied from
# the els tooling per the methodology (a real copy, never a link).
proc task_colors {args} {
    need wish
    exec [wish] [P tools colors.tcl] {*}$args &
    puts "launched color viewer"
}

# Screenshot the popup: launch ann.exe, find its window by PID (twapi), capture it
# with the cap extension's PrintWindow (occlusion-proof), write a PNG, close it.
proc task_shot {args} {
    need tclsh twapi
    if {[lindex $args 0] eq "--selftest"} { stream [tclsh] [P tools shot.tcl] --selftest ; return }
    if {![llength $args]} { error "usage: x shot <out.png> \[args ...]" }
    if {![file exists [P build cap.dll]]} { puts "building capture extension..." ; task_build-ext }
    if {![file exists [P ann.exe]]}       { puts "building ann.exe..."           ; task_build }
    set out [lindex $args 0]
    stream [tclsh] [P tools shot.tcl] [P ann.exe] - $out {*}[lrange $args 1 end]
}

# Stage the release: build the exe, verify it headlessly, drop it in dist/.
# The exe IS the distribution (els convention) — config and db are created next
# to it on first run, wherever the user puts it.
proc task_dist {args} {
    need gcc tclsh
    task_build
    # headless gate: a release must pass its own selftest
    set rpt [P build selftest.txt]
    catch {file delete -force $rpt}
    if {[catch {exec [P ann.exe] --selftest $rpt} err opts]} {
        if {[lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
            error "selftest FAILED — not releasing (see $rpt)"
        }
    }
    file mkdir [P dist]
    file copy -force [P ann.exe] [P dist ann.exe]
    puts "release staged: [file nativename [P dist ann.exe]]  ([file size [P dist ann.exe]] bytes)"
}

# ---- dispatch -----------------------------------------------------------
set cmd [lindex $argv 0]
if {$cmd eq ""} { set cmd help }
set proc "task_$cmd"
if {[llength [info commands $proc]] == 0} {
    puts stderr "x: unknown command '$cmd' (try: x help)"
    exit 2
}
if {[catch {$proc {*}[lrange $argv 1 end]} err]} {
    puts stderr "x $cmd: $err"
    exit 1
}
