#!/usr/bin/env tclsh
# tools/toolcheck.tcl — check zmal's runtime payloads have what ann needs
# (and, with --deep, that they actually work).
#
#   z check              report what is present / missing / outdated (+ versions)
#   z check --deep functional checks (compile C, load Tk, link SQLite + FTS5)
#
# The everyday `x` commands do NOT re-verify every zmal payload (that would tax
# every invocation); they fast-check the one or two tools they need and point
# here.  This is the thorough, on-demand check.  A MISSING core piece means
# a runtime payload was not restored completely, not a fetch-here.  The
# only build-here product is build/libsqlite3.a (`z build-sqlite`).  Every temp
# artifact this script writes stays INSIDE the project (build/), never %TEMP%.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
proc zmal_paths {root args} {
    set out {}
    if {[info exists ::env(Z_HOME)] && $::env(Z_HOME) ne ""} {
        lappend out [file join $::env(Z_HOME) {*}$args]
    }
    lappend out [file join [file dirname $root] .z {*}$args]
    return $out
}

proc discover_payload {root envs rel marker fallbacks missingPath label} {
    set candidates {}
    foreach var $envs {
        if {[info exists ::env($var)] && $::env($var) ne ""} {
            lappend candidates [list $::env($var) env:$var]
        }
    }
    foreach p [zmal_paths $root {*}$rel] { lappend candidates [list $p zmal] }
    foreach p $fallbacks { lappend candidates [list $p legacy] }
    foreach c $candidates {
        lassign $c p found
        set p [file normalize $p]
        if {[file exists [file join $p {*}$marker]]} { return [list $p $found] }
    }
    return [list [file normalize $missingPath] missing]
}

set ROOT [script_root]
lassign [discover_payload $ROOT {Z_TCLTK} {r tcltk 9.0.3} \
    {tcl9 bin tclsh90.exe} [list] [file join $ROOT zmal r tcltk 9.0.3] tcltk] TC PIN
lassign [discover_payload $ROOT {Z_MSYS2} {r msys2} \
    {ucrt64 bin gcc.exe} [list] [file join $ROOT zmal r msys2] msys2] MSYS2 MSYSPIN
lassign [discover_payload $ROOT {Z_SQLITE} {r sqlite 3.51.0} \
    {sqlite3.c} [list] [file join $ROOT zmal r sqlite 3.51.0] sqlite] SQLITE SQLITEPIN
lassign [discover_payload $ROOT {Z_TWAPI} {r twapi 5.2.0} \
    {pkgIndex.tcl} [list] [file join $ROOT zmal r twapi 5.2.0] twapi] TWAPI TWAPIPIN
proc P   {args} { return [file join $::ROOT {*}$args] }
proc TCp {args} { return [file join $::TC   {*}$args] }
proc MSYSp {args} { return [file join $::MSYS2 {*}$args] }
proc SQLITEp {args} { return [file join $::SQLITE {*}$args] }
proc TWAPIp {args} { return [file join $::TWAPI {*}$args] }

foreach {var rel marker} {
    TCL_LIBRARY {tcllib tcl_library} init.tcl
    TK_LIBRARY  {tcllib tk_library}  tk.tcl
} {
    set p [TCp {*}$rel]
    if {[file exists [file join $p $marker]]} { set ::env($var) [file nativename $p] }
}
set pkgpaths {}
foreach p [list $TWAPI] {
    if {[file isdirectory $p]} { lappend pkgpaths $p }
}
if {[llength $pkgpaths]} {
    set ::env(TCLLIBPATH) [expr {[info exists ::env(TCLLIBPATH)] && $::env(TCLLIBPATH) ne "" \
        ? [concat $pkgpaths $::env(TCLLIBPATH)] : $pkgpaths}]
    set auto_path [concat $pkgpaths $auto_path]
}

# Component manifest. kind: core (build/test/run) | opt. loc: tc, msys, sqlite,
# twapi, or root (a project product). want: pinned version ("" = don't compare).
set ::COMPONENTS {
    {key tcl    name "Tcl/Tk 9 (shared)"   loc tc   probe {tcl9 bin tclsh90.exe}              kind core want 9.0.3}
    {key gcc    name "gcc / C23 (UCRT64)"  loc msys probe {ucrt64 bin gcc.exe}                kind core want 16.1.0}
    {key tcls   name "Tcl/Tk 9 (static)"   loc tc   probe {tcl9s bin tclsh90s.exe}            kind core want 9.0.3}
    {key sqlsrc name "SQLite amalgamation" loc sqlite probe {sqlite3.c}                       kind core want 3.51.0}
    {key sqlite name "SQLite static lib"   loc root probe {build libsqlite3.a}                kind core want 3.51.0}
    {key twapi  name "twapi"               loc twapi probe {pkgIndex.tcl}                     kind core want 5.2.0}
    {key manual name "Tcl/Tk + C-API manual" loc tc probe {manual INDEX.md}                   kind opt  want {}}
    {key tclsrc name "Tcl/Tk 9 source"     loc tc   probe {tclsrc tcl9.0.3 generic tcl.h}     kind opt  want {}}
}

proc comp_path {comp args} {
    set rel [concat [dict get $comp probe] $args]
    switch [dict get $comp loc] {
        root { return [P {*}$rel] }
        msys { return [MSYSp {*}$rel] }
        sqlite { return [SQLITEp {*}$rel] }
        twapi { return [TWAPIp {*}$rel] }
        default { return [TCp {*}$rel] }
    }
}
proc present {comp} { return [file exists [comp_path $comp]] }

proc sqlite_header_version {} {
    set h [SQLITEp sqlite3.h]
    if {![catch {open $h r} fh]} {
        set d [read $fh] ; close $fh
        if {[regexp {define SQLITE_VERSION\s+"([0-9.]+)"} $d -> v]} { return $v }
    }
    return ""
}
proc version_of {comp} {
    set v ""
    switch [dict get $comp key] {
        tcl   { if {[catch {exec [TCp tcl9 bin tclsh90.exe]   << {puts [info patchlevel]}} v]} {
                    return "ERROR: [string map [list \n { }] [string trim $v]]" } }
        tcls  { if {[catch {exec [TCp tcl9s bin tclsh90s.exe] << {puts [info patchlevel]}} v]} {
                    return "ERROR: [string map [list \n { }] [string trim $v]]" } }
        gcc   { catch {exec [comp_path $comp] -dumpversion} v }
        sqlsrc { set v [sqlite_header_version] }
        sqlite { set v [sqlite_header_version] }
        twapi { set idx [comp_path $comp]
                if {![catch {open $idx r} fh]} { set d [read $fh] ; close $fh
                    regexp {package ifneeded\s+twapi\s+(\S+)} $d -> v } }
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
    puts "ann toolcheck  —  Tcl/Tk at [file nativename $::TC]"
    puts "                  MSYS2  at [file nativename $::MSYS2]"
    puts "                  SQLite at [file nativename $::SQLITE]"
    puts "                  twapi  at [file nativename $::TWAPI]"
    puts ""
    puts [format "  %-24s %-9s %s" COMPONENT STATUS VERSION/NOTE]
    puts "  [string repeat - 60]"
    set issues 0
    foreach c $::COMPONENTS {
        lassign [status_of $c] state v
        set kind [dict get $c kind]
        switch $state {
            ok       { set status "OK"     ; set note $v }
            broken   { set status "BROKEN" ; set note $v ; if {$kind eq "core"} { incr issues } }
            outdated { set status "UPDATE" ; set note "have $v, want [dict get $c want]"
                       if {$kind eq "core"} { incr issues } }
            missing  { set status [expr {$kind eq "core" ? "MISSING" : "(absent)"}]
                       if {[dict get $c key] eq "sqlite"} {
                           set note "run:  z build-sqlite"
                       } elseif {[dict get $c loc] ne "root"} {
                           set note "restore zmal runtime payloads"
                       } elseif {$kind eq "core"} {
                           set note "restore project build product"
                       } else { set note "" }
                       if {$kind eq "core"} { incr issues } }
        }
        puts [format "  %-24s %-9s %s" [dict get $c name] $status $note]
    }
    puts ""
    return $issues
}

# ---- deep functional checks (--deep): does it actually RUN? ---------------
# Temp work stays INSIDE the project (build/), never %TEMP% — containment.
proc tmpdir {} { return [P build _toolcheck_[pid]] }
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
    set gcc [MSYSp ucrt64 bin gcc.exe]
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
        lassign [tcl_eval "load {[fwd $dll]} Tcverify; puts \[tcverify\]"] loadOk lout
        if {!$loadOk || [string trim $lout] ne "1234"} { set ok 0; set detail "load failed: $lout" }
    }
    file delete -force $t
    return [deep_line "C23<->Tcl extension" $ok $detail]
}
# Confirm the C build resolves Tcl 9's header — NOT msys64's bundled 8.6.
proc deep_header {} {
    set gcc [MSYSp ucrt64 bin gcc.exe]
    if {![file exists $gcc]} { return [deep_line "C build uses Tcl 9 header" 0 "gcc missing"] }
    set t [tmpdir] ; file delete -force $t ; file mkdir $t
    set c [file join $t hv.c]
    set fh [open $c w] ; puts $fh "#include <tcl.h>" ; puts $fh {const char *V = TCL_PATCH_LEVEL;} ; close $fh
    set v ""
    if {![catch {exec $gcc -I[TCp tcl9 include] -E $c} out]} { regexp {const char \*V = "([0-9.]+)"} $out -> v }
    file delete -force $t
    return [deep_line "C build uses Tcl 9 header" [string match 9.* $v] "tcl.h = $v"]
}
# Compile a tiny console program against build/libsqlite3.a, run it, prove FTS5.
proc deep_sqlite {} {
    set gcc [MSYSp ucrt64 bin gcc.exe]
    set lib [P build libsqlite3.a]
    if {![file exists $gcc]} { return [deep_line "SQLite FTS5 links + runs" 0 "gcc missing"] }
    if {![file exists $lib]} { return [deep_line "SQLite FTS5 links + runs" 0 "libsqlite3.a missing — run: z build-sqlite"] }
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
    if {[catch {exec $gcc -std=gnu23 -O1 -I$::SQLITE $c $lib -o $exe} e]} {
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
    return $f
}

# ---- main ---------------------------------------------------------------
set doDeep [expr {"--deep" in $argv}]
set issues [report]
if {$doDeep} { incr issues [deep] }
puts ""
if {$issues > 0} {
    puts "  $issues issue(s).  A MISSING core piece means ann's zmal runtime payload is incomplete;"
    puts "  build/libsqlite3.a is `z build-sqlite`."
    exit 1
}
puts [expr {$doDeep ? "  all components present, current, and functional." \
                    : "  all core components present and current.  (`z check --deep` verifies they work)"}]
exit 0
