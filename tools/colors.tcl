#!/usr/bin/env wish
# tools/colors.tcl — browse every named color Tk knows, grouped by color family,
# each with its #RRGGBB.  Scrollable, with a live filter; click a swatch to copy
# its name.  Run via `x colors`.
#
# Base names are Tk's built-in set (from its xcolors.c table); numbered shades
# (name1..4) and gray/grey 0..100 are generated, then winfo rgb keeps only what
# Tk actually recognizes.  Families are assigned by hue/saturation/value.
package require Tk

set BASE {
    aliceBlue antiqueWhite aqua aquamarine azure beige bisque black
    blanchedAlmond blue blueViolet brown burlywood cadetBlue chartreuse
    chocolate coral cornflowerBlue cornsilk crimson cyan darkBlue darkCyan
    darkGoldenrod darkGray darkGreen darkGrey darkKhaki darkMagenta
    darkOliveGreen darkOrange darkOrchid darkRed darkSalmon darkSeaGreen
    darkSlateBlue darkSlateGray darkSlateGrey darkTurquoise darkViolet deepPink
    deepSkyBlue dimGray dimGrey dodgerBlue firebrick floralWhite forestGreen
    fuchsia gainsboro ghostWhite gold goldenrod gray green greenYellow grey
    honeydew hotPink indianRed indigo ivory khaki lavender lavenderBlush
    lawnGreen lemonChiffon lightBlue lightCoral lightCyan lightGoldenrod
    lightGoldenrodYellow lightGray lightGreen lightGrey lightPink lightSalmon
    lightSeaGreen lightSkyBlue lightSlateBlue lightSlateGray lightSlateGrey
    lightSteelBlue lightYellow lime limeGreen linen magenta maroon
    mediumAquamarine mediumBlue mediumOrchid mediumPurple mediumSeaGreen
    mediumSlateBlue mediumSpringGreen mediumTurquoise mediumVioletRed
    midnightBlue mintCream mistyRose moccasin navajoWhite navy navyBlue oldLace
    olive oliveDrab orange orangeRed orchid paleGoldenrod paleGreen
    paleTurquoise paleVioletRed papayaWhip peachPuff peru pink plum powderBlue
    purple red rosyBrown royalBlue saddleBrown salmon sandyBrown seaGreen
    seashell sienna silver skyBlue slateBlue slateGray slateGrey snow
    springGreen steelBlue tan teal thistle tomato turquoise violet violetRed
    wheat white whiteSmoke yellow yellowGreen
}

proc rgb2hsv {r g b} {
    set r [expr {$r/255.0}] ; set g [expr {$g/255.0}] ; set b [expr {$b/255.0}]
    set mx [expr {max($r,max($g,$b))}] ; set mn [expr {min($r,min($g,$b))}]
    set d [expr {$mx-$mn}] ; set v $mx
    set s [expr {$mx==0.0 ? 0.0 : $d/$mx}]
    if {$d==0.0} {
        set h 0.0
    } elseif {$mx==$r} { set h [expr {60.0*fmod(($g-$b)/$d,6.0)}]
    } elseif {$mx==$g} { set h [expr {60.0*(($b-$r)/$d+2.0)}]
    } else             { set h [expr {60.0*(($r-$g)/$d+4.0)}] }
    if {$h < 0} { set h [expr {$h+360.0}] }
    return [list $h $s $v]
}

# Assign a color family from H/S/V.
proc family {r g b} {
    lassign [rgb2hsv $r $g $b] h s v
    if {$s < 0.12} { return Neutral }
    if {$h < 16 || $h >= 345} { set f Red
    } elseif {$h < 45}  { set f Orange
    } elseif {$h < 66}  { set f Yellow
    } elseif {$h < 163} { set f Green
    } elseif {$h < 195} { set f Cyan
    } elseif {$h < 255} { set f Blue
    } elseif {$h < 295} { set f Purple
    } else              { set f Pink }
    # muted, darker warm tones read as brown; pale red-hues read as pink
    if {$f eq "Orange" && $v < 0.78 && $s >= 0.3} { set f Brown }
    if {$f eq "Red" && $v > 0.85 && $s < 0.42} { set f Pink }
    return $f
}

set FAMORDER {Red Orange Brown Yellow Green Cyan Blue Purple Pink Neutral}

# ---- build the color tables ---------------------------------------------
. configure -bg "#1E1E1E"
set candidates {}
foreach c $BASE {
    lappend candidates $c
    foreach n {1 2 3 4} { lappend candidates $c$n }
}
for {set i 0} {$i <= 100} {incr i} { lappend candidates gray$i grey$i }

set HEX [dict create] ; set HSV [dict create] ; set FAM [dict create]
foreach name [lsort -unique -dictionary $candidates] {
    if {[catch {winfo rgb . $name} rgb]} { continue }
    lassign $rgb R G B
    set r [expr {$R/256}] ; set g [expr {$G/256}] ; set b [expr {$B/256}]
    dict set HEX $name [format "#%02X%02X%02X" $r $g $b]
    dict set HSV $name [rgb2hsv $r $g $b]
    dict lappend FAM [family $r $g $b] $name
}
proc cmpcolor {a b} {
    lassign [dict get $::HSV $a] ha sa va
    lassign [dict get $::HSV $b] hb sb vb
    if {abs($ha-$hb) > 0.5} { return [expr {$ha < $hb ? -1 : 1}] }
    if {abs($va-$vb) > 0.003} { return [expr {$va > $vb ? -1 : 1}] }
    return [string compare $a $b]
}
proc cmpval {a b} {
    lassign [dict get $::HSV $a] ha sa va ; lassign [dict get $::HSV $b] hb sb vb
    if {abs($va-$vb) > 0.003} { return [expr {$va < $vb ? -1 : 1}] }
    return [string compare $a $b]
}
dict for {fam names} $FAM {
    dict set FAM $fam [lsort -command [expr {$fam eq "Neutral" ? "cmpval" : "cmpcolor"}] $names]
}
set NCOLORS 0
dict for {fam names} $FAM { incr NCOLORS [llength $names] }

# ---- UI -----------------------------------------------------------------
wm title . "Tk named colors"
wm geometry . 1040x720
wm attributes . -topmost 1
font create cName -family {Segoe UI} -size 9
font create cHex  -family Consolas    -size 8
font create cHead -family {Segoe UI Semibold} -size 12

frame .top -bg "#1E1E1E"
label .top.l -bg "#1E1E1E" -fg "#E6E6E6" -text "Filter:" -font {{Segoe UI} 10}
entry .top.e -textvariable ::filter -width 22 -bg "#2C2C2C" -fg "#E6E6E6" \
    -insertbackground "#DC322F" -relief flat
label .top.n -bg "#1E1E1E" -fg "#8A8F98" -textvariable ::countlbl -font {{Segoe UI} 9}
label .top.s -bg "#1E1E1E" -fg "#C8CDD4" -textvariable ::status -font {Consolas 9} -anchor w
pack .top.l -side left -padx {12 5} -pady 7
pack .top.e -side left -pady 7
pack .top.n -side left -padx 12
pack .top.s -side right -padx 12 -fill x
pack .top -side top -fill x

canvas .c -bg "#1E1E1E" -highlightthickness 0 -yscrollcommand {.vs set}
ttk::scrollbar .vs -orient vertical -command {.c yview}
pack .vs -side right -fill y
pack .c -side left -fill both -expand 1

# DPI-aware layout: derive everything from the real font line-heights (which
# already scale with screen DPI), so name and hex never collide.
set LSname  [font metrics cName -linespace]
set LShex   [font metrics cHex  -linespace]
set LShead  [font metrics cHead -linespace]
set u       $LSname
set PAD     [expr {round($u*0.7)}]
set SWH     [expr {round($u*1.9)}]
set CW      [expr {round($u*7.6)}]
set NAMEGAP [expr {round($u*0.35)}]
set CH      [expr {$SWH + $NAMEGAP + $LSname + $LShex + round($u*0.5)}]
set HEADH   [expr {$LShead + round($u*0.7)}]
set GAP     [expr {round($u*0.8)}]

proc pick {name} {
    set hx [dict get $::HEX $name]
    clipboard clear ; clipboard append $name
    set ::status "$name  $hx   (name copied)"
}

proc redraw {} {
    global HEX FAM FAMORDER CW CH SWH PAD HEADH GAP filter countlbl NCOLORS LSname NAMEGAP
    .c delete all
    set f [string tolower $filter]
    set w [winfo width .c]
    set cols [expr {max(1, ($w - $PAD) / $CW)}]
    set y $PAD ; set total 0
    foreach fam $FAMORDER {
        if {![dict exists $FAM $fam]} { continue }
        set members {}
        foreach n [dict get $FAM $fam] {
            if {$f eq "" || [string match *$f* [string tolower $n]]} { lappend members $n }
        }
        if {![llength $members]} { continue }
        incr total [llength $members]
        .c create text $PAD $y -anchor nw -font cHead -fill "#E6E6E6" -text $fam
        .c create text [expr {$PAD+[font measure cHead $fam]+10}] [expr {$y+4}] \
            -anchor nw -font cName -fill "#7E848C" -text "([llength $members])"
        .c create line $PAD [expr {$y+$HEADH-11}] [expr {$w-$PAD}] [expr {$y+$HEADH-11}] \
            -fill "#3A3A3A"
        incr y $HEADH
        set i 0
        foreach n $members {
            set col [expr {$i % $cols}] ; set row [expr {$i / $cols}]
            set x [expr {$PAD + $col*$CW}] ; set yy [expr {$y + $row*$CH}]
            set tag c_$n
            set cx [expr {$x+($CW-$PAD)/2}]
            .c create rectangle $x $yy [expr {$x+$CW-$PAD}] [expr {$yy+$SWH}] \
                -fill [dict get $HEX $n] -outline "#0A0A0A" -width 1 -tags $tag
            .c create text $cx [expr {$yy+$SWH+$NAMEGAP}] -anchor n \
                -text $n -fill "#E6E6E6" -font cName -tags $tag
            .c create text $cx [expr {$yy+$SWH+$NAMEGAP+$LSname}] -anchor n \
                -text [dict get $HEX $n] -fill "#9AA0A8" -font cHex -tags $tag
            .c bind $tag <Button-1> [list pick $n]
            .c bind $tag <Enter> [list .c configure -cursor hand2]
            .c bind $tag <Leave> [list .c configure -cursor {}]
            incr i
        }
        set rows [expr {($i + $cols - 1) / $cols}]
        set y [expr {$y + $rows*$CH + $GAP}]
    }
    set countlbl "$total of $NCOLORS colors"
    .c configure -scrollregion [list 0 0 $w [expr {$y + $PAD}]]
}

proc schedule {} { catch {after cancel $::redraw_id} ; set ::redraw_id [after 80 redraw] }
set ::status "click a swatch to copy its name"
bind .top.e <KeyRelease> schedule
bind .c <Configure> schedule
bind .c <MouseWheel> {.c yview scroll [expr {-%D/120}] units}
bind . <Escape> {set ::filter ""; redraw}
focus .top.e
after 60 redraw
