# tools/probe_latency.tcl — measure anndb::search latency against a (full-size)
# catalog db. Usage: x probe probe_latency.tcl <dbpath>
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] build]
package require anndb

set db [lindex $argv 0]
if {$db eq "" || ![file exists $db]} { puts stderr "usage: probe_latency.tcl <db>" ; exit 2 }
set c [anndb::open $db -readonly]
puts "rows: total [anndb::count $c] · file [anndb::count $c file] · folder [anndb::count $c folder] · shortcut [anndb::count $c shortcut]"
foreach q {"" "c" "co" "cod" "code" "vsc" "report 2024" "mahlzeit"} {
    # warm once, then time 5 runs
    anndb::search $c $q 80
    set t0 [clock microseconds]
    for {set i 0} {$i < 5} {incr i} { set r [anndb::search $c $q 80] }
    set dt [expr {([clock microseconds] - $t0) / 5000.0}]
    puts [format "  %-14s %6.1f ms   (%d hits)" [list $q] $dt [llength $r]]
}
anndb::close $c
exit 0
