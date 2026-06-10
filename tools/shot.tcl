#!/usr/bin/env tclsh
# tools/shot.tcl — launch ann and screenshot ITS window to PNG, robustly.
#
# Window-finding via twapi (by PID); the capture is the cap extension's
# PrintWindow (occlusion-proof) -> a DIB, converted to PNG here. No clipboard,
# no foreground, no Snipping-Tool, no full-screen crop — it grabs only the one
# window, even if covered or in the background.
#
#   tclsh90.exe tools/shot.tcl <ann.exe> - <out.png> [args ...]   # single-exe
#   tclsh90.exe tools/shot.tcl <wish.exe> <ann.tcl> <out.png> [args ...]
#   tclsh90.exe tools/shot.tcl --selftest        ;# headless converter checks
#
# Set ANN_SHOT_TITLE to capture a specific toplevel/dialog by title.
# Requires build/cap.dll (`x build-ext`).

package require Tk
wm withdraw .

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ::SHOT_ROOT [script_root]
lappend auto_path [file join $::SHOT_ROOT .toolchain twapi-dl]

proc ::shot_tmpdir {} {
    if {[info exists ::env(TEMP)] && $::env(TEMP) ne ""} { return $::env(TEMP) }
    return $::SHOT_ROOT
}

# ---- DIB (BITMAPINFOHEADER) -> Tk photo (24/32-bpp uncompressed) ------------
proc dib_to_photo {dib} {
    binary scan $dib iiissiiiiii \
        biSize biWidth biHeight biPlanes biBitCount biCompression \
        biSizeImage bppmX bppmY biClrUsed biClrImportant
    set width  $biWidth
    set height [expr {abs($biHeight)}]
    set topDown [expr {$biHeight < 0}]
    set bpp [expr {$biBitCount & 0xffff}]
    if {$bpp != 24 && $bpp != 32} { error "unsupported DIB bit depth: $bpp" }
    if {$biCompression != 0 && $biCompression != 3} { error "unsupported DIB compression: $biCompression" }
    set bytesPP [expr {$bpp / 8}]
    set rowStride [expr {(($width * $bpp + 31) / 32) * 4}]
    set maskBytes [expr {$biCompression == 3 ? 12 : 0}]
    set pixelStart [expr {$biSize + ($biClrUsed * 4) + $maskBytes}]

    set rows [list "P6\n$width $height\n255\n"]
    set rowLen [expr {$width * $bytesPP}]
    for {set oy 0} {$oy < $height} {incr oy} {
        set sy [expr {$topDown ? $oy : $height - 1 - $oy}]
        set off [expr {$pixelStart + $sy * $rowStride}]
        binary scan [string range $dib $off [expr {$off + $rowLen - 1}]] cu* bs
        set rgb {}
        if {$bytesPP == 4} {
            foreach {b g r a} $bs { lappend rgb $r $g $b }
        } else {
            foreach {b g r} $bs { lappend rgb $r $g $b }
        }
        lappend rows [binary format c* $rgb]
    }
    set ppm [join $rows ""]
    set tmp [file join [::shot_tmpdir] _annshot_[pid].ppm]
    set fh [::open $tmp w]
    try { fconfigure $fh -translation binary ; puts -nonewline $fh $ppm } finally { close $fh }
    try { set img [image create photo -file $tmp] } finally { file delete -force $tmp }
    return $img
}

# ---- live capture -----------------------------------------------------------
proc ann_window_for_pid {pid timeoutMs {title ""}} {
    set deadline [expr {[clock milliseconds] + $timeoutMs}]
    while {[clock milliseconds] < $deadline} {
        foreach hwin [twapi::find_windows -toplevel 1 -visible 1] {
            if {[catch {twapi::get_window_process $hwin} wp]} { continue }
            if {$wp != $pid} { continue }
            if {$title eq ""} { return $hwin }
            if {[catch {twapi::get_window_text $hwin} wt]} { continue }
            if {$wt eq $title || [string match $title $wt]} { return $hwin }
        }
        after 120
    }
    return ""
}

proc hwnd_int {h} {
    set a [lindex $h 0]
    if {[regexp {(0x[0-9a-fA-F]+|[0-9]+)} $a -> n]} { return $n }
    return $a
}

proc main {argv} {
    if {[lindex $argv 0] eq "--selftest"} { selftest ; return }
    package require twapi
    load [file join $::SHOT_ROOT build cap.dll] Cap
    catch {load [file join $::SHOT_ROOT build annplat.dll] Annplat}

    lassign $argv app script out
    set rest [lrange $argv 3 end]
    if {$app eq "" || $script eq "" || $out eq ""} {
        puts stderr "usage: shot.tcl <ann.exe> - <out.png> \[args ...]"
        exit 2
    }
    if {$script eq "-"} {
        set pid [exec $app {*}$rest &]
    } else {
        set pid [exec $app $script {*}$rest &]
    }
    set title [expr {[info exists ::env(ANN_SHOT_TITLE)] ? $::env(ANN_SHOT_TITLE) : ""}]
    set hwin [ann_window_for_pid $pid 12000 $title]
    if {$hwin eq ""} {
        catch {twapi::end_process $pid -force}
        puts stderr "window for pid $pid never appeared"
        exit 3
    }
    after 700                     ;# let Tk finish painting
    # optional: wait for the index to settle, then type a query before capturing
    if {[info exists ::env(ANN_SHOT_DELAY)] && $::env(ANN_SHOT_DELAY) ne ""} {
        after $::env(ANN_SHOT_DELAY)
    }
    if {[info exists ::env(ANN_SHOT_QUERY)] && $::env(ANN_SHOT_QUERY) ne ""} {
        catch {twapi::set_foreground_window $hwin}
        after 150
        twapi::send_keys $::env(ANN_SHOT_QUERY)
        after 500
    }
    if {[info exists ::env(ANN_SHOT_KEYS)] && $::env(ANN_SHOT_KEYS) ne ""} {
        twapi::send_keys $::env(ANN_SHOT_KEYS)   ;# e.g. {TAB} to open the panel
        after 400
    }
    try {
        set img [dib_to_photo [anncap::window [hwnd_int $hwin]]]
        $img write $out -format png
        puts "wrote $out ([image width $img]x[image height $img])"
    } finally {
        catch {annplat::post_message [hwnd_int $hwin] 0x10 0 0}   ;# WM_CLOSE
        after 400
        catch {twapi::end_process $pid -force}
    }
}

# ---- headless converter self-test -------------------------------------------
proc make_dib {width height bpp pixels} {
    set bytesPP [expr {$bpp / 8}]
    set rowStride [expr {(($width * $bpp + 31) / 32) * 4}]
    set pad [expr {$rowStride - $width * $bytesPP}]
    set hdr [binary format iiissiiiiii 40 $width $height 1 $bpp 0 0 2835 2835 0 0]
    set body ""
    for {set y [expr {$height - 1}]} {$y >= 0} {incr y -1} {
        for {set x 0} {$x < $width} {incr x} {
            set i [expr {($y * $width + $x) * $bytesPP}]
            append body [binary format c* [lrange $pixels $i [expr {$i + $bytesPP - 1}]]]
        }
        if {$pad > 0} { append body [binary format x$pad] }
    }
    return $hdr$body
}

proc selftest {} {
    set fails 0
    set px {
        0 0 255 0   0 255 0 0   255 0 0 0
        255 255 255 0   0 0 0 0   128 128 128 0
    }
    set dib [make_dib 3 2 32 $px]
    set img [dib_to_photo $dib]
    foreach {x y want} {0 0 {255 0 0}  1 0 {0 255 0}  2 0 {0 0 255}
                        0 1 {255 255 255}  1 1 {0 0 0}  2 1 {128 128 128}} {
        set got [lrange [$img get $x $y] 0 2]
        if {$got ne $want} { puts "FAIL 32bpp ($x,$y): got {$got} want {$want}"; incr fails }
    }
    if {[image width $img] != 3 || [image height $img] != 2} { incr fails }
    image delete $img
    if {$fails == 0} { puts "shot.tcl converter selftest: OK" ; exit 0 }
    puts "shot.tcl converter selftest: $fails FAILURE(S)" ; exit 1
}

if {[catch {main $argv} err]} { puts stderr $err ; exit 1 }
exit 0
