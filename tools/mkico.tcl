#!/usr/bin/env tclsh
# tools/mkico.tcl -- pack PNG files into a standalone Windows .ico (PNG-compressed
# entries, supported by Windows Vista+ and read by windres into RT_ICON /
# RT_GROUP_ICON). Pure byte manipulation; runs under tclsh90 (no Tk needed).
#
#   tclsh90.exe tools/mkico.tcl out.ico in16.png in32.png in256.png ...
#
# Each PNG's dimensions are read from its IHDR; sizes >=256 are encoded as 0 in
# the directory entry (the .ico convention). Used by the native build to bake the
# app icon into ann.exe via build/ann.rc.

proc png_dim {bytes} {
    # PNG IHDR: 8-byte signature, then length(4)+"IHDR"(4), then width(4 BE) at
    # offset 16 and height(4 BE) at offset 20.
    if {[string range $bytes 1 3] ne "PNG"} { error "not a PNG" }
    binary scan $bytes "@16 Iu Iu" w h
    return [list $w $h]
}

set out  [lindex $argv 0]
set pngs  [lrange $argv 1 end]
if {$out eq "" || ![llength $pngs]} {
    puts stderr "usage: mkico.tcl out.ico in.png \[in.png ...\]"
    exit 2
}

set n [llength $pngs]
set entries "" ; set blobs ""
set offset [expr {6 + 16 * $n}]          ;# ICONDIR(6) + n * ICONDIRENTRY(16)
foreach p $pngs {
    set fh [open $p rb] ; fconfigure $fh -translation binary
    set png [read $fh] ; close $fh
    lassign [png_dim $png] w h
    set bw [expr {$w >= 256 ? 0 : $w}]
    set bh [expr {$h >= 256 ? 0 : $h}]
    set len [string length $png]
    # ICONDIRENTRY: bWidth bHeight bColorCount bReserved wPlanes wBitCount
    #               dwBytesInRes dwImageOffset  (little-endian)
    append entries [binary format "ccccssii" $bw $bh 0 0 1 32 $len $offset]
    append blobs $png
    incr offset $len
}
# ICONDIR: idReserved=0, idType=1 (icon), idCount=n  (little-endian)
set ico [binary format "sss" 0 1 $n]
append ico $entries $blobs

set fh [open $out wb] ; fconfigure $fh -translation binary
puts -nonewline $fh $ico ; close $fh
puts "wrote [file nativename $out] ($n image(s), [file size $out] bytes)"
