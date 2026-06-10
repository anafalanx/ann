# ttk::scale

*Tk Themed Widget*

## NAME

ttk::scale - Create and manipulate a scale widget

## SYNOPSIS

**ttk::scale** *pathName* ?*options...*?

## DESCRIPTION

A **ttk::scale** widget is typically used to control the numeric value of a linked variable that varies uniformly over some range. A scale displays a *slider* that can be moved along over a *trough*, with the relative position of the slider over the trough indicating the value of the variable.

**Standard options** — see the referenced options manual:

- `-class`
- `-cursor`
- `-style`
- `-takefocus`

## WIDGET-SPECIFIC OPTIONS

- **`-command`** — database name `command`, class `Command`

Specifies the prefix of a Tcl command to invoke whenever the scale's value is changed via a widget command. The actual command consists of this option followed by a space and a real number indicating the new value of the scale.

- **`-from`** — database name `from`, class `From`

A real value corresponding to the left or top end of the scale.

- **`-length`** — database name `length`, class `Length`

Specifies the desired long dimension of the scale in screen units (i.e. any of the forms acceptable to **Tk_GetPixels**). For vertical scales this is the scale's height; for horizontal scales it is the scale's width.

- **`-orient`** — database name `orient`, class `Orient`

Specifies which orientation whether the widget should be laid out horizontally or vertically. Must be either **horizontal** or **vertical** or an abbreviation of one of these.

- **`-to`** — database name `to`, class `To`

Specifies a real value corresponding to the right or bottom end of the scale. This value may be either less than or greater than the **-from** option.

- **`-value`** — database name `value`, class `Value`

Specifies the current floating-point value of the variable. If **-variable** is set to an existing variable, specifying **-value** has no effect (the variable value takes precedence).

- **`-variable`** — database name `variable`, class `Variable`

Specifies the name of a global variable to link to the scale. Whenever the value of the variable changes, the scale will update to reflect this value. Whenever the scale is manipulated interactively, the variable will be modified to reflect the scale's new value.

## WIDGET COMMAND

In addition to the standard **cget**, **configure**, **identify element**, **instate**, **state** and **style** commands (see **ttk::widget**), scale widgets support the following additional commands:

*pathName* **get** ?*x y*?

Get the current value of the **-value** option, or the value corresponding to the coordinates *x,y* if they are specified. *X* and *y* are pixel coordinates relative to the scale widget origin.

*pathName* **set** *value*

Set the value of the widget (i.e. the **-value** option) to *value*. The value will be clipped to the range given by the **-from** and **-to** options. Note that setting the linked variable (i.e. the variable named in the **-variable** option) does not cause such clipping.

## INTERNAL COMMANDS

*pathName* **coords** ?*value*?

Get the coordinates corresponding to *value*, or the coordinates corresponding to the current value of the **-value** option if *value* is omitted.

## STYLING OPTIONS

The class name for a **ttk::scale** is **TScale**.

Dynamic states: **active**.

**TScale** styling options configurable with **ttk::style** are:

**-background** *color*

**-borderwidth** *amount*

**-darkcolor** *color*

**-groovewidth** *amount*

**-lightcolor** *color*

**-sliderwidth** *amount*

**-troughcolor** *color*

**-troughrelief** *relief*

Some options are only available for specific themes.

See the **ttk::style** manual page for information on how to configure ttk styles.

## SEE ALSO

ttk::widget(n), scale(n)

## KEYWORDS

scale, slider, trough, widget
