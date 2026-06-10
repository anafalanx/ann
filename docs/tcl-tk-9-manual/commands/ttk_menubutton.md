# ttk::menubutton

*Tk Themed Widget*

## NAME

ttk::menubutton - Widget that pops down a menu when pressed

## SYNOPSIS

**ttk::menubutton** *pathName* ?*options*?

## DESCRIPTION

A **ttk::menubutton** widget displays a textual label and/or image, and displays a menu when pressed.

**Standard options** — see the referenced options manual:

- `-class`
- `-compound`
- `-cursor`
- `-image`
- `-state`
- `-style`
- `-takefocus`
- `-text`
- `-textvariable`
- `-underline`
- `-width`

## WIDGET-SPECIFIC OPTIONS

- **`-direction`** — database name `direction`, class `Direction`

Specifies where the menu is to be popped up relative to the menubutton. One of: **above**, **below**, **left**, **right**, or **flush**.  The default is **below**. **flush** pops the menu up directly over the menubutton.

- **`-menu`** — database name `menu`, class `Menu`

Specifies the path name of the menu associated with the menubutton. To be on the safe side, the menu ought to be a direct child of the menubutton.

## WIDGET COMMAND

Menubutton widgets support the standard commands **cget**, **configure**, **identify element**, **instate**, **state** and **style** (see **ttk::widget**).

## STANDARD STYLES

**Ttk::menubutton** widgets support the **Toolbutton** style in all standard themes, which is useful for creating widgets for toolbars.

## STYLING OPTIONS

The class name for a **ttk::menubutton** is **TMenubutton**.

Dynamic states: **active**, **disabled**, **readonly**.

**TMenubutton** styling options configurable with **ttk::style** are:

**-arrowsize** *amount*

**-background** *color*

**-compound** *compound*

**-foreground** *color*

**-font** *font*

**-padding** *padding*

**-relief** *relief*

**-width** *amount*

Some options are only available for specific themes.

See the **ttk::style** manual page for information on how to configure ttk styles.

## SEE ALSO

ttk::widget(n), menu(n), menubutton(n)

## KEYWORDS

widget, button, menu
