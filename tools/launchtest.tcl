#!/usr/bin/env tclsh
# tools/launchtest.tcl — end-to-end launch test.
#
# Launches ann.exe, lets it index, types a query that resolves to Notepad,
# presses Enter, and verifies notepad.exe actually started — proving the whole
# chain: indexer -> catalog -> search -> render -> annplat::launch (ShellExecute).
# Fully scriptable via twapi; reaps the ann instance and ONLY the Notepad it
# spawns (any Notepad the user already had open is left alone).
#
#   tclsh90.exe tools/launchtest.tcl <ann.exe>

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
proc discover_store {root} {
    set pinfile [file join $root toolchain.pin]
    if {![file exists $pinfile]} { error "no toolchain.pin in $root" }
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
    error "bundle '$pin' not found in any ancestor X/ store from $root"
}
set ROOT [script_root]
lappend auto_path [file join [discover_store $ROOT] twapi-dl]
package require twapi

proc win_for_pid {pid} {
    foreach h [twapi::find_windows -toplevel 1 -visible 1] {
        if {![catch {twapi::get_window_process $h} wp] && $wp == $pid} { return $h }
    }
    return ""
}

set exe [lindex $argv 0]
if {$exe eq "" || ![file exists $exe]} { puts stderr "usage: launchtest.tcl <ann.exe>" ; exit 2 }

catch {exec taskkill /IM [file tail $exe] /F}
# Do NOT blanket-kill Notepad — the user may have their own windows open with
# unsaved work. Snapshot the pre-existing instances so that, at the end, we reap
# ONLY the one this test spawns.
set preNotepad [twapi::get_process_ids -name notepad.exe]
after 400

set pid [lindex [exec $exe &] 0]
puts "launched [file tail $exe] (pid $pid)"

# wait for the popup
set h "" ; set t0 [clock milliseconds]
while {$h eq "" && [clock milliseconds] - $t0 < 8000} { set h [win_for_pid $pid] ; after 100 }
if {$h eq ""} { catch {twapi::end_process $pid -force} ; puts "FAIL: popup never appeared" ; exit 1 }

after 2800                      ;# let the background index finish
catch {twapi::set_foreground_window $h} ; after 200
twapi::send_keys "notepad"      ;# fuzzy -> the Notepad shortcut
after 600
twapi::send_keys "{ENTER}"      ;# launch the selected result
after 1500

# Only the Notepad(s) that appeared AFTER we launched are ours to reap; any
# instance the user already had open is left untouched.
set postNotepad [twapi::get_process_ids -name notepad.exe]
set mine {}
foreach p $postNotepad { if {$p ni $preNotepad} { lappend mine $p } }
puts "notepad spawned by this test: $mine"

catch {twapi::end_process $pid -force}
foreach p $mine { catch {twapi::end_process $p -force} }

if {[llength $mine] > 0} { puts "LAUNCH TEST: OK (Enter launched Notepad)" ; exit 0 }
puts "LAUNCH TEST: FAIL (Notepad did not start)" ; exit 1
