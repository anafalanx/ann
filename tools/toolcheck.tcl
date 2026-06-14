#!/usr/bin/env tclsh
# tools/toolcheck.tcl — check the pinned mal bundle has what ann needs (and,
# with --deep, that it actually works).
#
#   x toolcheck          report what is present / missing / outdated (+ versions)
#   x toolcheck --deep   functional checks (compile C, load Tk, link SQLite + FTS5)
#
# The everyday `x` commands do NOT re-verify the whole toolchain (that would tax
# every invocation); they fast-check the one or two tools they need and point
# here.  This is the thorough, on-demand check.  ann does NOT vendor a toolchain:
# the bundle is mal's, read-only — so a MISSING core piece means the bundle is
# incomplete (run `mal verify <pin>` from the mal folder), not a fetch-here.  The
# only build-here product is build/libsqlite3.a (`x build-sqlite`).  Every temp
# artifact this script writes stays INSIDE the project (build/), never %TEMP%.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
# Discover the pinned bundle (canonical copy in tools/x.tcl): toolchain.pin names
# it; walk ancestors for X/<pin>/BUNDLE.manifest.
proc discover_store {root} {
    set pinfile [file join $root toolchain.pin]
    if {![file exists $pinfile]} { error "no toolchain.pin in $root" }
    set fh [open $pinfile r] ; set pin [string trim [read $fh]] ; close $fh
    if {$pin eq ""} { error "toolchain.pin is empty in $root" }
    set dir $root
    for {set i 0} {$i < 8} {incr i} {
        set cand [file join $dir X $pin]
        if {[file exists [file join $cand BUNDLE.manifest]]} { return [list $cand $pin] }
        set up [file dirname $dir]
        if {$up eq $dir} break
        set dir $up
    }
    error "bundle '$pin' not found in any ancestor X/ store from $root"
}
set ROOT [script_root]
lassign [discover_store $ROOT] TC PIN
proc P   {args} { return [file join $::ROOT {*}$args] }
proc TCp {args} { return [file join $::TC   {*}$args] }

foreach {var rel marker} {
    TCL_LIBRARY {tcllib tcl_library} init.tcl
    TK_LIBRARY  {tcllib tk_library}  tk.tcl
} {
    set p [TCp {*}$rel]
    if {[file exists [file join $p $marker]]} { set ::env($var) [file nativename $p] }
}
set pkgpaths {}
foreach p [list [TCp twapi-dl twapi-5.2.0] [TCp twapi-dl]] {
    if {[file isdirectory $p]} { lappend pkgpaths $p }
}
if {[llength $pkgpaths]} {
    set ::env(TCLLIBPATH) [expr {[info exists ::env(TCLLIBPATH)] && $::env(TCLLIBPATH) ne "" \
        ? [concat $pkgpaths $::env(TCLLIBPATH)] : $pkgpaths}]
    set auto_path [concat $pkgpaths $auto_path]
}

# Component manifest.  kind: core (build/test/run) | opt.  loc: tc (in the bundle)
# | root (a project product).  want: pinned version ("" = don't compare).
set ::COMPONENTS {
    {key tcl    name "Tcl/Tk 9 (shared)"   loc tc   probe {tcl9 bin tclsh90.exe}              kind core want 9.0.3}
    {key gcc    name "gcc / C23 (UCRT64)"  loc tc   probe {msys64 ucrt64 bin gcc.exe}         kind core want 16.1.0}
    {key tcls   name "Tcl/Tk 9 (static)"   loc tc   probe {tcl9s bin tclsh90s.exe}            kind core want 9.0.3}
    {key sqlsrc name "SQLite amalgamation" loc tc   probe {sqlite sqlite3.c}                  kind core want 3.51.0}
    {key sqlite name "SQLite static lib"   loc root probe {build libsqlite3.a}                kind core want 3.51.0}
    {key twapi  name "twapi"               loc tc   probe {twapi-dl twapi-5.2.0 pkgIndex.tcl} kind core want 5.2.0}
    {key manual name "Tcl/Tk + C-API manual" loc tc probe {manual INDEX.md}                   kind opt  want {}}
    {key tclsrc name "Tcl/Tk 9 source"     loc tc   probe {tclsrc tcl9.0.3 generic tcl.h}     kind opt  want {}}
}

proc comp_path {comp args} {
    set rel [concat [dict get $comp probe] $args]
    return [expr {[dict get $comp loc] eq "root" ? [P {*}$rel] : [TCp {*}$rel]}]
}
proc present {comp} { return [file exists [comp_path $comp]] }

proc sqlite_header_version {} {
    set h [TCp sqlite sqlite3.h]
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
        gcc   { catch {exec [TCp msys64 ucrt64 bin gcc.exe] -dumpversion} v }
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
    puts "ann toolcheck  —  bundle '$::PIN' at [file nativename $::TC]"
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
                           set note "run:  x build-sqlite"
                       } elseif {$kind eq "core"} {
                           set note "bundle incomplete — run:  mal verify $::PIN"
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
# Compile a tiny console program against build/libsqlite3.a, run it, prove FTS5.
proc deep_sqlite {} {
    set gcc [TCp msys64 ucrt64 bin gcc.exe]
    set lib [P build libsqlite3.a]
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
    return $f
}

# ---- main ---------------------------------------------------------------
set doDeep [expr {"--deep" in $argv}]
set issues [report]
if {$doDeep} { incr issues [deep] }
puts ""
if {$issues > 0} {
    puts "  $issues issue(s).  A MISSING core piece means the bundle is incomplete"
    puts "  (run `mal verify $PIN`); build/libsqlite3.a is `x build-sqlite`."
    exit 1
}
puts [expr {$doDeep ? "  all components present, current, and functional." \
                    : "  all core components present and current.  (`x toolcheck --deep` verifies they work)"}]
exit 0
