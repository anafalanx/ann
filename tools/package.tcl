# tools/package.tcl — append the ann zipfs payload onto a wrapper exe.
#
# Runs under the STATIC tclsh90s so zipfs can `lmkimg`-append the staged app
# payload — main.tcl (= ann.tcl), resources/, tcl_library/, tk_library/ at the
# archive root — onto our native wrapper, AFTER the PE image so the baked-in
# icon/manifest/version survive.  The wrapper is `--wrapper`:
#   * native build (`x build`):  build/ann-bare.exe (our custom C entry point)
#
#   tclsh90s.exe tools/package.tcl [out.exe] --wrapper W
#
# SQLite and the platform layer are compiled INTO ann.exe (no embedded DLLs), so
# there is no --with-ext payload for the native build.  tk_library is extracted
# from wish90s.exe's own appended archive (present regardless of the mkimg
# wrapper) or the bundle's tcllib payload; tcl_library from the static interp's
# //zipfs:/app or the bundle's tcllib.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
proc zmal_paths {root args} {
    return [list [file join $root zmal {*}$args] [file join [file dirname $root] zmal {*}$args]]
}
proc discover_tcltk {root} {
    set candidates {}
    if {[info exists ::env(Z_TCLTK)] && $::env(Z_TCLTK) ne ""} {
        lappend candidates $::env(Z_TCLTK)
    }
    lappend candidates {*}[zmal_paths $root r tcltk 9.0.3]
    foreach p $candidates {
        set p [file normalize $p]
        if {[file exists [file join $p tcl9 bin tclsh90.exe]]} { return $p }
    }
    error "zmal Tcl/Tk payload not found for $root"
}
set ROOT [script_root]
set TC   [discover_tcltk $ROOT]
proc TCp {args} { return [file join $::TC {*}$args] }
proc copy_tree {src dst} {
    file mkdir $dst
    foreach item [glob -nocomplain [file join $src *]] {
        set target [file join $dst [file tail $item]]
        if {[file isdirectory $item]} { copy_tree $item $target } else { file copy -force $item $target }
    }
}
proc zip_entries {root {rel ""}} {
    set out {}
    foreach item [glob -nocomplain [file join $root $rel *]] {
        set name [file tail $item]
        set zrel [expr {$rel eq "" ? $name : [file join $rel $name]}]
        if {[file isdirectory $item]} {
            lappend out {*}[zip_entries $root $zrel]
        } else {
            lappend out $item [string map {\\ /} $zrel]
        }
    }
    return $out
}

set positional {}
set wrapperOverride ""
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        --with-ext { }
        --wrapper  { incr i ; set wrapperOverride [lindex $argv $i] }
        default    { lappend positional [lindex $argv $i] }
    }
}
set out [lindex $positional 0]
if {$out eq ""} { set out [file join $ROOT ann.exe] }

set wish [TCp tcl9s bin wish90s.exe]
if {![file exists $wish]} { error "static wish missing: $wish" }
set mkimgWrapper [expr {$wrapperOverride ne "" ? $wrapperOverride : $wish}]
if {[file isdirectory //zipfs:/app/tcl_library]} {
    set tclLibrary //zipfs:/app/tcl_library
} elseif {[file isdirectory [TCp tcllib tcl_library]]} {
    set tclLibrary [TCp tcllib tcl_library]
} else {
    error "tcl_library not found in //zipfs:/app or the bundle's tcllib"
}

set stage [file join $ROOT build _pkg_stage]
file delete -force $stage
file mkdir $stage

# 1. tcl_library — from the static interp's //zipfs:/app when mounted, else the bundle's tcllib.
copy_tree $tclLibrary [file join $stage tcl_library]

# 2. tk_library — from the wish90s wrapper's appended archive, else the bundle's tcllib.
set copiedTk 0
if {![catch {zipfs mount $wish Wt}]} {
    if {[file isdirectory //zipfs:/Wt/tk_library]} {
        copy_tree //zipfs:/Wt/tk_library [file join $stage tk_library]
        set copiedTk 1
    }
    zipfs unmount Wt
}
if {!$copiedTk && [file isdirectory [TCp tcllib tk_library]]} {
    copy_tree [TCp tcllib tk_library] [file join $stage tk_library]
    set copiedTk 1
}
if {!$copiedTk} { error "tk_library not found in wish90s.exe or the bundle's tcllib" }

# 3. app: main.tcl (= ann.tcl) + resources/
file copy -force [file join $ROOT ann.tcl] [file join $stage main.tcl]
if {[file isdirectory [file join $ROOT resources]]} {
    copy_tree [file join $ROOT resources] [file join $stage resources]
}

# 4. fuse — the staged tree lands at the archive root, after the PE image.
file delete -force $out
set entries [zip_entries $stage]
if {![llength $entries]} { error "package stage is empty: $stage" }
zipfs lmkimg $out $entries {} $mkimgWrapper
file delete -force $stage
puts "built [file nativename $out]  ([file size $out] bytes)"
