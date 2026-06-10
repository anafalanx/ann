#!/usr/bin/env tclsh
# tools/icon.tcl -- generate the ann app icon into resources/icon*.png.
#
# The KEY on the launcher's own page, in the els icon grammar (els tools/icon.tcl,
# "the awl on the editor's own page"): a light rounded tile in the app's page
# grey with a hairline edge ring, an ink object built from a few primitives, a
# steel-blue collar band, and exactly ONE accent at the business end — for ann
# that is the key's bit (the part that opens things), in ann's accent blue.
# ann is a keystroke launcher; the key is the object that opens everything else.
#
# Pure photo-image pixel math with signed-distance anti-aliasing: deterministic,
# no mapped window needed.
#
#   wish90.exe tools/icon.tcl            # writes resources/icon.png + 32 + 16
#
# Re-run after changing the glyph; the PNGs are committed assets (the source the
# native build packs into ann.ico via tools/mkico.tcl).

package require Tk
wm withdraw .

# --- palette (ann.tcl's els-derived look; accent differentiates from els) -----
set TILE   {242 242 242}   ;# #F2F2F2 the page (ann::C(bg), same as els::PAGE)
set EDGE   {212 212 212}   ;# #D4D4D4 hairline ring so the tile reads on white
set INK    {26 26 26}      ;# #1A1A1A bow + shaft
set FERR   {150 170 198}   ;# #96AAC6 collar band (els's ferrule blue)
set ACCENT {38 139 210}    ;# #268BD2 ann's blue — the key's bit (els uses red)
set EDGEW  3               ;# edge-ring width in 256-scale px

proc clamp {x lo hi} { expr {$x < $lo ? $lo : ($x > $hi ? $hi : $x)} }
proc smooth {edge0 edge1 x} {
    if {$edge1 == $edge0} { return [expr {$x < $edge0 ? 0.0 : 1.0}] }
    set t [clamp [expr {double($x-$edge0)/($edge1-$edge0)}] 0.0 1.0]
    return [expr {$t*$t*(3-2*$t)}]
}
proc mix {a b t} {
    lassign $a ar ag ab ; lassign $b br bg bb
    list [expr {int(round($ar+($br-$ar)*$t))}] \
         [expr {int(round($ag+($bg-$ag)*$t))}] \
         [expr {int(round($ab+($bb-$ab)*$t))}]
}
# rounded-rect signed distance (negative inside)
proc sd_rrect {px py cx cy hw hh r} {
    set qx [expr {abs($px-$cx)-($hw-$r)}]
    set qy [expr {abs($py-$cy)-($hh-$r)}]
    set ax [expr {$qx>0?$qx:0}] ; set ay [expr {$qy>0?$qy:0}]
    set mn [expr {max($qx,$qy)<0?max($qx,$qy):0}]
    expr {hypot($ax,$ay)+$mn-$r}
}
# capsule (segment with radius) signed distance
proc sd_cap {px py ax ay bx by r} {
    set vx [expr {$bx-$ax}] ; set vy [expr {$by-$ay}]
    set wx [expr {$px-$ax}] ; set wy [expr {$py-$ay}]
    set d2 [expr {$vx*$vx+$vy*$vy}]
    set t [expr {$d2 > 0 ? [clamp [expr {($wx*$vx+$wy*$vy)/$d2}] 0.0 1.0] : 0.0}]
    expr {hypot($px-($ax+$t*$vx),$py-($ay+$t*$vy)) - $r}
}

proc render {N path} {
    global TILE EDGE INK FERR ACCENT EDGEW
    set img [image create photo -width $N -height $N]
    set s [expr {$N/256.0}]

    # --- the key, laid on the 45-degree diagonal like els's awl ---------------
    # axis u = (cos45, sin45); the bow sits upper-left, the bit lower-right
    set ux 0.70710678 ; set uy 0.70710678
    set qx -0.70710678 ; set qy 0.70710678      ;# perpendicular: teeth side (down-left)
    set bx [expr {88*$s}] ; set by [expr {88*$s}]   ;# bow center
    proc P {t} {                                  ;# point on the axis, 256-scale t
        upvar bx bx by by ux ux uy uy s s
        list [expr {$bx+$ux*$t*$s}] [expr {$by+$uy*$t*$s}]
    }
    set rBow   [expr {33*$s}]   ;# bow outer radius
    set rHole  [expr {14*$s}]   ;# bow hole radius
    set rShaft [expr {8.5*$s}]  ;# shaft half-width
    lassign [P 28]  sx0 sy0     ;# shaft start (under the bow)
    lassign [P 126] sx1 sy1     ;# shaft tip
    lassign [P 40]  fx0 fy0     ;# collar band
    lassign [P 50]  fx1 fy1
    lassign [P 96]  t1x t1y     ;# tooth 1 (longer)
    lassign [P 116] t2x t2y     ;# tooth 2
    set tooth1 [expr {21*$s}] ; set tooth2 [expr {15*$s}] ; set rTooth [expr {6.5*$s}]

    for {set y 0} {$y < $N} {incr y} {
        set row {}
        for {set x 0} {$x < $N} {incr x} {
            set fx [expr {$x+0.5}] ; set fy [expr {$y+0.5}]
            # tile (transparent outside the rounded square) + hairline edge ring
            set dtile [sd_rrect $fx $fy [expr {$N/2.0}] [expr {$N/2.0}] \
                          [expr {120*$s}] [expr {120*$s}] [expr {46*$s}]]
            set aTile [smooth 1.0 -1.0 $dtile]
            set col $TILE ; set a $aTile
            set ringcov [expr {[smooth 1.0 -1.0 $dtile]*[smooth -1.0 1.0 [expr {$dtile+$EDGEW*$s}]]}]
            if {$ringcov > 0} { set col [mix $col $EDGE $ringcov] }
            # bow: ink ring (outer disc minus hole, hole repainted as tile)
            set dBow [expr {hypot($fx-$bx,$fy-$by)-$rBow}]
            set cBow [smooth 1.0 -1.0 $dBow]
            if {$cBow > 0} { set col [mix $col $INK $cBow] }
            set dHole [expr {hypot($fx-$bx,$fy-$by)-$rHole}]
            set cHole [smooth 1.0 -1.0 $dHole]
            if {$cHole > 0} { set col [mix $col $TILE $cHole] }
            # shaft (ink capsule along the axis)
            set dSh [sd_cap $fx $fy $sx0 $sy0 $sx1 $sy1 $rShaft]
            set cSh [smooth 1.0 -1.0 $dSh]
            if {$cSh > 0} { set col [mix $col $INK $cSh] }
            # collar band (els's ferrule blue, slightly wider than the shaft)
            set dFe [sd_cap $fx $fy $fx0 $fy0 $fx1 $fy1 [expr {$rShaft+2.5*$s}]]
            set cFe [smooth 1.0 -1.0 $dFe]
            if {$cFe > 0} { set col [mix $col $FERR $cFe] }
            # the bit: two accent teeth hanging off one side near the tip
            set dT1 [sd_cap $fx $fy $t1x $t1y \
                        [expr {$t1x+$qx*$tooth1}] [expr {$t1y+$qy*$tooth1}] $rTooth]
            set dT2 [sd_cap $fx $fy $t2x $t2y \
                        [expr {$t2x+$qx*$tooth2}] [expr {$t2y+$qy*$tooth2}] $rTooth]
            set dT [expr {min($dT1,$dT2)}]
            set cT [smooth 1.0 -1.0 $dT]
            if {$cT > 0} { set col [mix $col $ACCENT $cT] }
            lassign $col r g b
            set A [clamp [expr {int(round($a*255))}] 0 255]
            lappend row [format "#%02x%02x%02x%02x" $r $g $b $A]
        }
        $img put [list $row] -to 0 $y
    }
    $img write $path -format {png -alpha 1}
    image delete $img
    puts "wrote [file nativename $path] (${N}x${N})"
}

set root [file dirname [file dirname [file normalize [info script]]]]
set res  [file join $root resources]
file mkdir $res
render 256 [file join $res icon.png]
render 32  [file join $res icon32.png]
render 16  [file join $res icon16.png]
exit 0
