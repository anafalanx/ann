# ttk::frame

*Tk Themed Widget*

## NAME

ttk::frame - Simple container widget

## SYNOPSIS

**ttk::frame** *pathName* ?*options*?

## DESCRIPTION

A **ttk::frame** widget is a container, used to group other widgets together.

**Standard options** — see the referenced options manual:

- `-class`
- `-cursor`
- `-padding`
- `-style`
- `-takefocus`

## WIDGET-SPECIFIC OPTIONS

- **`-borderwidth`** — database name `borderWidth`, class `BorderWidth`

The desired width of the widget border.  Defaults to 0. May be ignored depending on the theme used.

- **`-relief`** — database name `relief`, class `Relief`

One of the standard Tk border styles: **flat**, **groove**, **raised**, **ridge**, **solid**, or **sunken**. Defaults to **flat**.

- **`-width`** — database name `width`, class `Width`

If specified, the widget's requested width in pixels.

- **`-height`** — database name `height`, class `Height`

If specified, the widget's requested height in pixels.

## WIDGET COMMAND

Frame widgets support the standard commands **cget**, **configure**, **identify element**, **instate**, **state** and **style** (see **ttk::widget**).

## NOTES

Note that if the **pack**, **grid**, or other geometry managers are used to manage the children of the **frame**, by the GM's requested size will normally take precedence over the **frame** widget's **-width** and **-height** options. **pack propagate** and **grid propagate** can be used to change this.

## STYLING OPTIONS

The class name for a **ttk::frame** is **TFrame**.

**TFrame** styling options configurable with **ttk::style** are:

**-background** *color*

**-relief** *relief*

Some options are only available for specific themes.

See the **ttk::style** manual page for information on how to configure ttk styles.

## BINDINGS

When a new **ttk::frame** is created, it has no default event bindings; **ttk::frame**s are not intended to be interactive.

## SEE ALSO

ttk::widget(n), ttk::labelframe(n), frame(n)

## KEYWORDS

widget, frame, container
