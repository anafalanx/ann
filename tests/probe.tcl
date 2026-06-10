# tests/probe.tcl — dialog-quiet preamble for `x probe <script>`.
#
# Sourced (by tools/x.tcl) under the CONSOLE tclsh BEFORE the probe script, so any
# error goes to stderr (never a modal dialog) and ann's C extensions are findable.

package require Tk
catch {wm attributes . -alpha 0.0}

proc ::bgerror {m} { puts stderr "BGERROR: $m\n$::errorInfo" }
catch {interp bgerror {} ::bgerror}
proc ::tk_messageBox {args} { return ok }

set ::ANN_ROOT [file dirname [file dirname [file normalize [info script]]]]
lappend auto_path [file join $::ANN_ROOT build]
