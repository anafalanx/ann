#!/usr/bin/env tclsh
# tools/toolcheck.tcl — check (and optionally prep) the vendored toolchain.
#
#   x toolcheck          report what is present / missing / outdated (+ versions)
#   x toolcheck --prep   fetch/update/build the auto-installable pieces
#   x toolcheck --deep   functional checks (compile C, load Tk, link SQLite, run)
#
# The everyday `x` commands do NOT re-verify the whole toolchain (that would tax
# every invocation); they only fast-check the one or two tools they need and, if
# something is missing, point here.  This is the thorough, on-demand check.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
set TC   [file join $ROOT .toolchain]
proc TCp {args} { return [file join $::TC {*}$args] }

foreach {var rel marker} {
    TCL_LIBRARY {appfull tcl_library} init.tcl
    TK_LIBRARY  {appfull tk_library}  tk.tcl
} {
    set p [TCp {*}$rel]
    if {[file exists [file join $p $marker]]} { set ::env($var) [file nativename $p] }
}
set pkgpaths {}
foreach p [list [file join $ROOT tools tclpkg] \
                [TCp twapi-dl twapi-5.2.0] \
                [TCp twapi-dl]] {
    if {[file isdirectory $p]} { lappend pkgpaths $p }
}
foreach p [glob -nocomplain [TCp tcl9 lib *]] {
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

# Component manifest.  kind: core (build/test/run) | opt (extra).  want: the
# pinned version (empty = don't compare).  prep: {auto <x-task>} | {manual "…"}.
set ::COMPONENTS {
    {key tcl    name "Tcl/Tk 9 (shared)"  probe {tcl9 bin tclsh90.exe}              kind core want 9.0.3            prep {manual "rebuild Tcl/Tk 9 from source (see toolchain.md)"}}
    {key gcc    name "gcc / C23 (UCRT64)" probe {msys64 ucrt64 bin gcc.exe}         kind core want 16.1.0           prep {manual "vendor the MSYS2 UCRT64 toolchain (gcc/binutils/gdb/windres)"}}
    {key tcls   name "Tcl/Tk 9 (static)"  probe {tcl9s bin tclsh90s.exe}            kind core want 9.0.3            prep {manual "static build (--disable-shared); its libs link into ann.exe via `x build`"}}
    {key sqlsrc name "SQLite amalgamation" probe {sqlite sqlite3.c}                 kind core want 3.51.0           prep {manual "vendor sqlite3.c/.h/ext.h into .toolchain/sqlite/"}}
    {key sqlite name "SQLite static lib"  probe {sqlite libsqlite3.a}               kind core want 3.51.0           prep {auto build-sqlite}}
    {key twapi  name "twapi"              probe {twapi-dl twapi-5.2.0 pkgIndex.tcl} kind core want 5.2.0            prep {auto fetch-twapi}}
    {key git    name "Git (MinGit)"       probe {git cmd git.exe}                   kind opt  want 2.54.0.windows.1 prep {auto fetch-git}}
    {key curl   name "curl"               probe {msys64 usr bin curl.exe}           kind opt  want {}               prep {manual "ships with MSYS2; used by the fetch tasks"}}
}

proc present {comp} { return [file exists [TCp {*}[dict get $comp probe]]] }

proc sqlite_header_version {} {
    set h [TCp sqlite sqlite3.h]
    if {![catch {open $h r} fh]} {
        set d [read $fh] ; close $fh
        if {[regexp {define SQLITE_VERSION\s+"([0-9.]+)"} $d -> v]} { return $v }
    }
    return ""
}

proc version_of {comp} {
    set key [dict get $comp key]
    set v ""
    switch $key {
        tcl   { if {[catch {exec [TCp tcl9 bin tclsh90.exe]   << {puts [info patchlevel]}} v]} {
                    return "ERROR: [string map [list \n { }] [string trim $v]]" } }
        tcls  { if {[catch {exec [TCp tcl9s bin tclsh90s.exe] << {puts [info patchlevel]}} v]} {
                    return "ERROR: [string map [list \n { }] [string trim $v]]" } }
        gcc   { catch {exec [TCp msys64 ucrt64 bin gcc.exe] -dumpversion} v }
        git   { catch {exec [TCp git cmd git.exe] --version} v
                set v [string trim [string map {{git version} {}} $v]] }
        sqlsrc { set v [sqlite_header_version] }
        sqlite { set v [sqlite_header_version] }
        twapi { set idx [TCp {*}[dict get $comp probe]]
                if {![catch {open $idx r} fh]} {
                    set d [read $fh] ; close $fh
                    regexp {package ifneeded\s+twapi\s+(\S+)} $d -> v } }
        curl  { catch {exec [TCp msys64 usr bin curl.exe] --version} out
                regexp {curl (\S+)} $out -> v }
    }
    return $v
}

# {state version}  — state in {ok outdated missing broken}
proc status_of {comp} {
    if {![present $comp]} { return [list missing ""] }
    set v [version_of $comp]
    if {[string match {ERROR:*} $v]} { return [list broken $v] }
    set want [dict get $comp want]
    if {$want ne "" && $v ne $want} { return [list outdated $v] }
    return [list ok $v]
}

proc report {} {
    puts ""
    puts "ann toolcheck  —  .toolchain under [file nativename $::TC]"
    puts ""
    puts [format "  %-22s %-9s %s" COMPONENT STATUS VERSION/NOTE]
    puts "  [string repeat - 58]"
    set issues 0
    foreach c $::COMPONENTS {
        lassign [status_of $c] state v
        set kind [dict get $c kind]
        lassign [dict get $c prep] ptype parg
        switch $state {
            ok       { set status "OK"       ; set note $v }
            broken   { set status "BROKEN"   ; set note $v
                       if {$kind eq "core"} { incr issues } }
            outdated { set status "UPDATE"   ; set note "have $v, want [dict get $c want]"
                       if {$kind eq "core"} { incr issues } }
            missing  { set status [expr {$kind eq "core" ? "MISSING" : "(absent)"}]
                       set note [expr {$ptype eq "auto" ? "run:  x $parg" : $parg}]
                       if {$kind eq "core"} { incr issues } }
        }
        puts [format "  %-22s %-9s %s" [dict get $c name] $status $note]
    }
    puts ""
    return $issues
}

proc prep {} {
    set xtcl [file join $::ROOT tools x.tcl]
    foreach c $::COMPONENTS {
        lassign [status_of $c] state v
        if {$state eq "ok"} continue
        lassign [dict get $c prep] ptype parg
        if {$ptype ne "auto"} {
            if {[dict get $c kind] eq "core"} { puts ">> [dict get $c name]: manual — $parg" }
            continue
        }
        puts ">> $state [dict get $c name]:  x $parg"
        catch {exec [TCp tcl9 bin tclsh90.exe] $xtcl $parg >@ stdout 2>@ stderr}
    }
}

# ---- deep functional checks (--deep): does it actually RUN? ---------------
proc tmpdir {} {
    set d [expr {[info exists ::env(TEMP)] && $::env(TEMP) ne "" ? $::env(TEMP) : $::TC}]
    return [file join $d ann_toolcheck_[pid]]
}
proc fwd {p} { return [string map {\\ /} [file nativename $p]] }
proc tcl_eval {script} {
    if {[catch {exec [TCp tcl9 bin tclsh90.exe] << $script} out]} { return [list 0 $out] }
    return [list 1 $out]
}
proc deep_line {name ok detail} {
    puts [format "  %-26s %-5s %s" $name [expr {$ok ? {PASS} : {FAIL}}] $detail]
    return [expr {$ok ? 0 : 1}]
}

# Compile a tiny stubs extension and load it — proves gcc + headers + stubs + load.
proc deep_ext {} {
    set gcc [TCp msys64 ucrt64 bin gcc.exe]
    if {![file exists $gcc]} { return [deep_line "C23<->Tcl extension" 0 "gcc missing"] }
    set t [tmpdir]; file delete -force $t; file mkdir $t
    set c [file join $t tcverify.c]; set dll [file join $t tcverify.dll]
    set fh [open $c w]
    puts $fh {#include <tcl.h>}
    puts $fh {static int Tc(void*cd,Tcl_Interp*ip,int o,Tcl_Obj*const v[]){Tcl_SetObjResult(ip,Tcl_NewIntObj(1234));return TCL_OK;}}
    puts $fh {int Tcverify_Init(Tcl_Interp*ip){if(Tcl_InitStubs(ip,"9.0",0)==NULL)return TCL_ERROR;Tcl_CreateObjCommand(ip,"tcverify",Tc,NULL,NULL);return TCL_OK;}}
    close $fh
    set ok 1; set detail "gcc -std=c23 compile + stubs load OK"
    if {[catch {exec $gcc -std=c23 -O1 -shared -DUSE_TCL_STUBS -I[TCp tcl9 include] \
            $c -o $dll -L[TCp tcl9 lib] -ltclstub -static-libgcc} e]} {
        set ok 0; set detail "compile failed: $e"
    } else {
        lassign [tcl_eval "load {[fwd $dll]} Tcverify; puts \[tcverify\]"] lok lout
        if {!$lok || [string trim $lout] ne "1234"} { set ok 0; set detail "load failed: $lout" }
    }
    file delete -force $t
    return [deep_line "C23<->Tcl extension" $ok $detail]
}

# Confirm the C build resolves Tcl 9's header — NOT msys64's bundled 8.6.
proc deep_header {} {
    set gcc [TCp msys64 ucrt64 bin gcc.exe]
    if {![file exists $gcc]} { return [deep_line "C build uses Tcl 9 header" 0 "gcc missing"] }
    set t [tmpdir] ; file delete -force $t ; file mkdir $t
    set c [file join $t hv.c]
    set fh [open $c w] ; puts $fh "#include <tcl.h>" ; puts $fh {const char *V = TCL_PATCH_LEVEL;} ; close $fh
    set v ""
    if {![catch {exec $gcc -I[TCp tcl9 include] -E $c} out]} { regexp {const char \*V = "([0-9.]+)"} $out -> v }
    file delete -force $t
    return [deep_line "C build uses Tcl 9 header" [string match 9.* $v] "tcl.h = $v"]
}

# Compile a tiny console program against libsqlite3.a, run it, prove FTS5 works.
proc deep_sqlite {} {
    set gcc [TCp msys64 ucrt64 bin gcc.exe]
    set lib [TCp sqlite libsqlite3.a]
    if {![file exists $gcc]} { return [deep_line "SQLite FTS5 links + runs" 0 "gcc missing"] }
    if {![file exists $lib]} { return [deep_line "SQLite FTS5 links + runs" 0 "libsqlite3.a missing — run: x build-sqlite"] }
    set t [tmpdir]; file delete -force $t; file mkdir $t
    set c [file join $t sqv.c]; set exe [file join $t sqv.exe]
    set fh [open $c w]
    puts $fh {#include <stdio.h>
#include "sqlite3.h"
int main(void){
  sqlite3 *db; if (sqlite3_open(":memory:", &db)) return 2;
  char *e = 0;
  if (sqlite3_exec(db,
        "CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram');"
        "INSERT INTO t VALUES('google chrome');", 0, 0, &e)) {
    printf("ERR %s", e ? e : ""); return 3;
  }
  sqlite3_stmt *s;
  sqlite3_prepare_v2(db, "SELECT count(*) FROM t WHERE t MATCH 'chr'", -1, &s, 0);
  sqlite3_step(s); int n = sqlite3_column_int(s, 0); sqlite3_finalize(s);
  double r = 0;
  sqlite3_prepare_v2(db, "SELECT exp(0.0)", -1, &s, 0);
  sqlite3_step(s); r = sqlite3_column_double(s, 0); sqlite3_finalize(s);
  sqlite3_close(db);
  printf("FTS5 %s; exp %s; v=%s", n==1?"OK":"BAD", r==1.0?"OK":"BAD", sqlite3_libversion());
  return 0;
}}
    close $fh
    set ok 1 ; set detail ""
    if {[catch {exec $gcc -std=gnu23 -O1 -I[TCp sqlite] $c $lib -o $exe} e]} {
        set ok 0 ; set detail "link failed: $e"
    } else {
        if {[catch {exec $exe} out]} { set ok 0; set detail "run failed: $out" } else {
            set detail [string trim $out]
            if {![string match "FTS5 OK; exp OK*" $detail]} { set ok 0 }
        }
    }
    file delete -force $t
    return [deep_line "SQLite FTS5 links + runs" $ok $detail]
}

proc deep {} {
    puts ""
    puts "  functional checks (does it actually run?):"
    set f 0
    lassign [tcl_eval {puts [expr {6*7}]}] ok out
    incr f [deep_line "Tcl evaluates a script" [expr {$ok && [string trim $out] eq "42"}] [string trim $out]]
    lassign [tcl_eval {package require Tk; label .l -text hi; puts [winfo class .l]; exit}] ok out
    incr f [deep_line "Tk creates a widget" [expr {$ok && [string match *abel [string trim $out]]}] [string trim $out]]
    incr f [deep_ext]
    incr f [deep_header]
    incr f [deep_sqlite]
    if {[file exists [TCp git cmd git.exe]]} {
        set ok [expr {![catch {exec [TCp git cmd git.exe] --version}]}]
        incr f [deep_line "git runs" $ok ""]
    }
    return $f
}

# ---- main ---------------------------------------------------------------
set doPrep [expr {("--prep" in $argv) || ("--fix" in $argv)}]
set doDeep [expr {"--deep" in $argv}]
set issues [report]
if {$doPrep} {
    if {$issues == 0} { puts "  nothing to do — all core components present and current." } else {
        prep ; puts "--- re-check ---" ; set issues [report]
    }
}
if {$doDeep} { incr issues [deep] }
puts ""
if {$issues > 0} {
    puts "  $issues issue(s). `x toolcheck --prep` fetches/updates/builds; `--deep` runs functional checks."
    exit 1
}
puts [expr {$doDeep ? "  all components present, current, and functional." \
                    : "  all core components present and current.  (run `x toolcheck --deep` to verify they work)"}]
exit 0
