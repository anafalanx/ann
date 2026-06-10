# ttk::separator

*Tk Themed Widget*

## NAME

ttk::separator - Separator bar

## SYNOPSIS

**ttk::separator** *pathName* ?*options*?

## DESCRIPTION

A **ttk::separator** widget displays a horizontal or vertical separator bar.

**Standard options** — see the referenced options manual:

- `-class`
- `-cursor`
- `-style`
- `-takefocus`

## WIDGET-SPECIFIC OPTIONS

- **`-orient`** — database name `orient`, class `Orient`

One of **horizontal** or **vertical**. Specifies the orientation of the separator.

## WIDGET COMMAND

Separator widgets support the standard commands **cget**, **configure**, **identify element**, **instate**, **state** and **style** (see **ttk::widget**).

## STYLING OPTIONS

The class name for a **ttk::separator** is **TSeparator**.

**TSeparator** styling options configurable with **ttk::style** are:

**-background** *color*

Some options are only available for specific themes.

See the **ttk::style** manual page for information on how to configure ttk styles.

## SEE ALSO

ttk::widget(n)

## KEYWORDS

widget, separator
