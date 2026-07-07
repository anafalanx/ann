#!/usr/bin/env tclsh
# tools/hktest.tcl — end-to-end global-hotkey integration test (DESIGN §3.4 risk #2).
#
# Launches ann.exe, then SYNTHESIZES the global hotkey (Alt+Space) at the OS input
# level via twapi and verifies the popup toggles visible<->hidden. This proves
# WM_HOTKEY is delivered to our dedicated hotkey thread and bridged to the GUI
# thread WHILE Tk's own message pump is running — the central risk of the design.
# Fully scriptable; no manual key press.
#
#   tclsh90.exe tools/hktest.tcl <ann.exe>

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
proc zmal_paths {root args} {
    return [list [file join $root zmal {*}$args] [file join [file dirname $root] zmal {*}$args]]
}
proc discover_twapi {root} {
    set candidates {}
    if {[info exists ::env(Z_TWAPI)] && $::env(Z_TWAPI) ne ""} {
        lappend candidates $::env(Z_TWAPI)
    }
    lappend candidates {*}[zmal_paths $root r twapi 5.2.0]
    foreach p $candidates {
        set p [file normalize $p]
        if {[file exists [file join $p pkgIndex.tcl]]} { return $p }
    }
    error "zmal twapi payload not found for $root"
}
set ROOT [script_root]
lappend auto_path [discover_twapi $ROOT]
package require twapi

proc visible_for_pid {pid} {
    foreach h [twapi::find_windows -toplevel 1 -visible 1] {
        if {![catch {twapi::get_window_process $h} wp] && $wp == $pid} { return 1 }
    }
    return 0
}
proc wait_state {pid want timeoutMs} {
    set deadline [expr {[clock milliseconds] + $timeoutMs}]
    while {[clock milliseconds] < $deadline} {
        if {[visible_for_pid $pid] == $want} { return 1 }
        after 80
    }
    return 0
}

set exe [lindex $argv 0]
if {$exe eq "" || ![file exists $exe]} { puts stderr "usage: hktest.tcl <ann.exe>" ; exit 2 }

# Make sure we are the only instance (single-instance mutex would make a 2nd exit).
catch {exec taskkill /IM [file tail $exe] /F}
after 300

set pids [exec $exe &]
set pid [lindex $pids 0]
puts "launched [file tail $exe] (pid $pid)"

set fails 0
proc fail {msg} { puts "  FAIL: $msg" ; incr ::fails }

# 1. popup should be shown on launch
if {[wait_state $pid 1 8000]} { puts "  launch -> popup VISIBLE  OK" } else { fail "popup never appeared on launch" }

# 2. synthesize Alt+Space three times; expect hidden, visible, hidden.
foreach {n want} {1 0  2 1  3 0} {
    after 500
    twapi::send_keys "%{SPACE}"     ;# % = Alt, {SPACE} = space  -> global Alt+Space
    set label [expr {$want ? "VISIBLE" : "hidden "}]
    if {[wait_state $pid $want 4000]} {
        puts "  hotkey #$n -> $label  OK"
    } else {
        fail "hotkey #$n: expected $label, popup is [expr {[visible_for_pid $pid] ? {visible} : {hidden}}]"
    }
}

catch {twapi::end_process $pid -force}
if {$fails} { puts "HOTKEY INTEGRATION: $fails FAILURE(S)" ; exit 1 }
puts "HOTKEY INTEGRATION: OK (global Alt+Space toggles the popup through Tk's loop)"
exit 0
