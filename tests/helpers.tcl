# tests/helpers.tcl — shared scaffolding for the ann test suite.
#
# Loads tcltest and the ann library (ann.tcl's main is guarded by an
# `info script eq argv0` check, so sourcing it here does NOT launch the popup).
# Tests are white-box, in-process, and headless.

if {[info exists ::ann_helpers_loaded]} { return }
set ::ann_helpers_loaded 1

package require Tk
package require tcltest

# Keep the test UI invisible without unmapping it (keyboard event generate needs
# a mapped, focusable window): make the root fully transparent.
catch {wm attributes . -alpha 0.0}
# POSITION-ONLY: an explicit WxH would freeze the toplevel's size and pack
# would silently unmap rows that no longer fit (caught by scroll-1.1)
wm geometry . +100+100

set ::ANN_SCRIPT [info script]
if {[file pathtype $::ANN_SCRIPT] ne "absolute"} { set ::ANN_SCRIPT [file join [pwd] $::ANN_SCRIPT] }
set ::ANN_ROOT [file dirname [file dirname $::ANN_SCRIPT]]
set ::ANN_TMP  [file join $::ANN_ROOT tests _tmp]
# start-of-run sweep: previous runs' per-pid homes/dbs (nothing holds them now)
catch {file delete -force $::ANN_TMP}
file mkdir $::ANN_TMP

# Put build/ on auto_path BEFORE sourcing ann.tcl, so its `package require
# anndb/annplat` loads the dev .dll's when `x build-ext` has produced them.
lappend auto_path [file join $::ANN_ROOT build]

# ---- no dialog ever reaches the screen --------------------------------------
set ::ANN_TEST_ERRLOG [file join $::ANN_TMP bgerror.log]
set ::ann_test_bgerrors {}
proc ::ann_test_bgerror {msg {opts {}}} {
    lappend ::ann_test_bgerrors $msg
    catch { set fh [open $::ANN_TEST_ERRLOG a] ; puts $fh "---- bgerror ----\n$msg\n$::errorInfo" ; close $fh }
    catch {puts stderr "BGERROR: $msg"}
}
catch {interp bgerror {} ::ann_test_bgerror}
proc ::bgerror {msg} { ::ann_test_bgerror $msg }
proc ::tk_messageBox {args} { return ok }
proc ::tk_getOpenFile {args} { return "" }
proc ::tk_getSaveFile {args} { return "" }
proc ::grab {args} {}

# Load the ann library (UI not launched on source).
source [file join $::ANN_ROOT ann.tcl]

# Keep tests hermetic: redirect the app log into the temp dir (ann.tcl points it
# at the install dir = repo root in dev) and clear any line written during source.
catch {file delete -force [file join $::ANN_ROOT ann.log]}
set ::ann::logfile [file join $::ANN_TMP ann.log]

# Hermetic watched roots: scans must walk a tiny temp tree, never the user's real
# Desktop/Documents/Downloads (slow + machine-dependent).
set ::ANN_FSROOT [file join $::ANN_TMP fsroot]
file mkdir $::ANN_FSROOT
catch {annindex::set_roots [list $::ANN_FSROOT]}

# ---- RE-install the no-dialog error trap AFTER ann.tcl (which installed its
# own spine over ours at source time). Errors still reach ann::log; the suite
# additionally captures them in ::ann_test_bgerrors and FAILS the run if any
# leak through (tests/run.tcl checks at the end).
proc ::ann_test_bgerror {msg {opts {}}} {
    lappend ::ann_test_bgerrors $msg
    catch { set fh [open $::ANN_TEST_ERRLOG a] ; puts $fh "---- bgerror ----\n$msg\n$::errorInfo" ; close $fh }
    catch {ann::log ERROR "test-bgerror: $msg"}
    catch {puts stderr "BGERROR: $msg"}
}
catch {interp bgerror {} ::ann_test_bgerror}
proc ::bgerror {msg} { ::ann_test_bgerror $msg }
proc ::ann::bgerror {msg {opts {}}} { ::ann_test_bgerror $msg }

# Are the C extensions present (built by `x build-ext`)? Gates the C-backed tests.
::tcltest::testConstraint hasext \
    [expr {[ann::has anndb::selftest] && [ann::has annplat::active_monitor_rect]}]
::tcltest::testConstraint hashotkey [ann::has annhotkey::start]
::tcltest::testConstraint hasindex  [ann::has annindex::scan]
::tcltest::testConstraint hasicon   [ann::has annicon::fill]
