#!/usr/bin/env tclsh
# tools/icon.tcl -- generate the ann app icon (a search lens on a dark rounded
# tile) into resources/icon*.png. Pure photo-image pixel math with signed-distance
# anti-aliasing, so it is deterministic and needs no mapped window.
#
#   wish90.exe tools/icon.tcl            # writes resources/icon.png + 32 + 16
#
# Re-run after changing the glyph; the PNGs are committed assets (the source the
# native build packs into ann.ico via tools/mkico.tcl).

package require Tk
wm withdraw .

# --- palette (the one fixed dark look, DESIGN §9.9) --------------------------
set BG    {22 24 29}      ;# #16181D dark tile
set RING  {230 230 230}   ;# light lens ring
set ACCENT {90 160 242}   ;# #5AA0F2 calm blue (lens glass + handle)

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

proc render {N path} {
    global BG RING ACCENT
    set img [image create photo -width $N -height $N]
    set s [expr {$N/256.0}]
    # geometry in 256-space, scaled by s
    set cx [expr {110*$s}] ; set cy [expr {110*$s}]   ;# lens center
    set R  [expr {66*$s}]                              ;# lens outer radius
    set ring [expr {16*$s}]                            ;# ring thickness
    # handle: a thick segment from lens edge to lower-right
    set hx0 [expr {$cx+($R-4*$s)*0.7071}] ; set hy0 [expr {$cy+($R-4*$s)*0.7071}]
    set hx1 [expr {200*$s}] ; set hy1 [expr {200*$s}]
    set hw [expr {15*$s}]                              ;# handle half-width
    for {set y 0} {$y < $N} {incr y} {
        set row {}
        for {set x 0} {$x < $N} {incr x} {
            set fx [expr {$x+0.5}] ; set fy [expr {$y+0.5}]
            # tile background (transparent outside the rounded tile)
            set dtile [sd_rrect $fx $fy [expr {$N/2.0}] [expr {$N/2.0}] \
                          [expr {120*$s}] [expr {120*$s}] [expr {46*$s}]]
            set aTile [smooth 1.0 -1.0 $dtile]
            set col $BG ; set a $aTile
            # lens glass fill (accent, faint) inside ring
            set dl [expr {hypot($fx-$cx,$fy-$cy)-$R}]
            set glass [smooth 1.0 -1.0 [expr {$dl+$ring}]]
            if {$glass > 0} { set col [mix $col $ACCENT [expr {0.20*$glass}]] }
            # lens ring (light annulus)
            set ringcov [expr {[smooth 1.0 -1.0 $dl]*[smooth -1.0 1.0 [expr {$dl+$ring}]]}]
            if {$ringcov > 0} { set col [mix $col $RING $ringcov] ; set a [expr {max($a,$ringcov)}] }
            # handle (accent capsule)
            set vx [expr {$hx1-$hx0}] ; set vy [expr {$hy1-$hy0}]
            set wx [expr {$fx-$hx0}]  ; set wy [expr {$fy-$hy0}]
            set tt [expr {($vx*$vx+$vy*$vy)>0 ? ($wx*$vx+$wy*$vy)/($vx*$vx+$vy*$vy) : 0}]
            set tt [clamp $tt 0.0 1.0]
            set dh [expr {hypot($fx-($hx0+$tt*$vx),$fy-($hy0+$tt*$vy))-$hw}]
            set hcov [smooth 1.0 -1.0 $dh]
            if {$hcov > 0} { set col [mix $col $ACCENT $hcov] ; set a [expr {max($a,$hcov)}] }
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
