# ttk::label

*Tk Themed Widget*

## NAME

ttk::label - Display a text string and/or image

## SYNOPSIS

**ttk::label** *pathName* ?*options*?

## DESCRIPTION

A **ttk::label** widget displays a textual label and/or image. The label may be linked to a Tcl variable to automatically change the displayed text.

**Standard options** — see the referenced options manual:

- `-anchor`
- `-class`
- `-compound`
- `-cursor`
- `-font`
- `-foreground`
- `-image`
- `-justify`
- `-padding`
- `-state`
- `-style`
- `-takefocus`
- `-text`
- `-textvariable`
- `-underline`
- `-width`
- `-wraplength`

## WIDGET-SPECIFIC OPTIONS

- **`-background`** — database name `frameColor`, class `FrameColor`

The widget's background color. If unspecified, the theme default is used.

- **`-relief`** — database name `relief`, class `Relief`

Specifies the 3-D effect desired for the widget border. Valid values are **flat**, **groove**, **raised**, **ridge**, **solid**, and **sunken**.

- **`-wraplength`** — database name `wrapLength`, class `WrapLength`

Specifies the maximum line length (in pixels). If this option is negative or zero, then automatic wrapping is not performed; otherwise the text is split into lines such that no line is longer than the specified value.

## WIDGET COMMAND

Label widgets support the standard commands **cget**, **configure**, **identify element**, **instate**, **state** and **style** (see **ttk::widget**).

## STYLING OPTIONS

The class name for a **ttk::label** is **TLabel**.

Dynamic states: **disabled**, **readonly**.

**TLabel** styling options configurable with **ttk::style** are:

**-background** *color*

**-compound** *compound*

**-foreground** *color*

**-font** *font*

Some options are only available for specific themes.

See the **ttk::style** manual page for information on how to configure ttk styles.

## SEE ALSO

ttk::widget(n), label(n)
