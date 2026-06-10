# tests/run.tcl — run the whole ann test suite in one process.
#   .toolchain/tcl9/bin/tclsh90.exe tests/run.tcl [--fast]
# Exits non-zero if any test fails.

set script [info script]
if {[file pathtype $script] ne "absolute"} { set script [file join [pwd] $script] }
set here [file dirname $script]
cd [file dirname $here]

set fast 0 ; set keep {}
foreach a $argv { if {$a eq "--fast"} { set fast 1 } else { lappend keep $a } }
set argv $keep

source [file join $here helpers.tcl]
::tcltest::testConstraint slow [expr {!$fast}]

foreach f [lsort [glob -nocomplain [file join $here *.test]]] {
    source $f
}

set failed $::tcltest::numTests(Failed)
tcltest::cleanupTests

# any background error that fired during the run is a failure: nothing may ever
# leak toward Tk's modal dialog path
if {[llength $::ann_test_bgerrors]} {
    puts stderr "BACKGROUND ERRORS captured during the run ([llength $::ann_test_bgerrors]):"
    foreach e $::ann_test_bgerrors { puts stderr "  - $e" }
    incr failed [llength $::ann_test_bgerrors]
}
exit [expr {$failed > 0 ? 1 : 0}]
