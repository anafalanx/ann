# ttk::sizegrip

*Tk Themed Widget*

## NAME

ttk::sizegrip - Bottom-right corner resize widget

## SYNOPSIS

**ttk::sizegrip** *pathName* ?*options*?

## DESCRIPTION

A **ttk::sizegrip** widget (also known as a *grow box*) allows the user to resize the containing toplevel window by pressing and dragging the grip.

**Standard options** — see the referenced options manual:

- `-class`
- `-cursor`
- `-style`
- `-takefocus`

## WIDGET COMMAND

Sizegrip widgets support the standard commands **cget**, **configure**, **identify element**, **instate**, **state** and **style** (see **ttk::widget**).

## PLATFORM-SPECIFIC NOTES

On macOS, toplevel windows automatically include a built-in size grip by default. Adding a **ttk::sizegrip** there is harmless, since the built-in grip will just mask the widget.

## EXAMPLES

Using pack:

```tcl
pack [ttk::frame $top.statusbar] -side bottom -fill x
pack [ttk::sizegrip $top.statusbar.grip] -side right -anchor se
```

Using grid:

```tcl
grid [ttk::sizegrip $top.statusbar.grip] \
    -row $lastRow -column $lastColumn -sticky se
# ... optional: add vertical scrollbar in $lastColumn,
# ... optional: add horizontal scrollbar in $lastRow
```

## BUGS

If the containing toplevel's position was specified relative to the right or bottom of the screen (e.g., “**wm geometry ...** *w***x***h***-***x***-***y*” instead of “**wm geometry ...** *w***x***h***+***x***+***y*”), the sizegrip widget will not resize the window.

**ttk::sizegrip** widgets only support “southeast” resizing.

## STYLING OPTIONS

The class name for a **ttk::sizegrip** is **TSizegrip**.

**TSizegrip** styling options configurable with **ttk::style** are:

**-background** *color*

Some options are only available for specific themes.

See the **ttk::style** manual page for information on how to configure ttk styles.

## SEE ALSO

ttk::widget(n)

## KEYWORDS

widget, sizegrip, grow box
