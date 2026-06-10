# ttk::button

*Tk Themed Widget*

## NAME

ttk::button - Widget that issues a command when pressed

## SYNOPSIS

**ttk::button** *pathName* ?*options*?

## DESCRIPTION

A **ttk::button** widget displays a textual label and/or image, and evaluates a command when pressed.

**Standard options** — see the referenced options manual:

- `-class`
- `-compound`
- `-cursor`
- `-image`
- `-justify`
- `-state`
- `-style`
- `-takefocus`
- `-text`
- `-textvariable`
- `-underline`
- `-width`

## WIDGET-SPECIFIC OPTIONS

- **`-command`** — database name `command`, class `Command`

A script to evaluate when the widget is invoked.

- **`-default`** — database name `default`, class `Default`

May be set to one of  **normal**, **active**, or **disabled**. In a dialog box, one button may be designated the “default” button (meaning, roughly, “the one that gets invoked when the user presses <Enter>”). **active** indicates that this is currently the default button; **normal** means that it may become the default button, and **disabled** means that it is not defaultable. The default is **normal**.

  Depending on the theme, the default button may be displayed with an extra highlight ring, or with a different border color.

## WIDGET COMMAND

In addition to the standard **cget**, **configure**, **identify element**, **instate**, **state** and **style** commands (see **ttk::widget**), button widgets support the following additional commands:

*pathName* **invoke**

Invokes the command associated with the button.

## STANDARD STYLES

**Ttk::button** widgets support the **Toolbutton** style in all standard themes, which is useful for creating widgets for toolbars.

In the Aqua theme there are several other styles which can be used to produce replicas of many of the different button types that are discussed in Apple's Human Interface Guidelines.  These include **DisclosureButton**, **DisclosureTriangle**, **HelpButton**, **ImageButton**, **InlineButton**, **GradientButton**, **RoundedRectButton**, and **RecessedButton**.

## STYLING OPTIONS

The class name for a **ttk::button** is **TButton**.

Dynamic states: **active**, **disabled**, **pressed**, **readonly**.

**TButton** styling options configurable with **ttk::style** are:

**-anchor** *anchor*

**-background** *color*

**-bordercolor** *color*

**-compound** *compound*

**-darkcolor** *color*

**-foreground** *color*

**-font** *font*

**-highlightcolor** *color*

**-highlightthickness** *amount*

**-lightcolor** *color*

**-padding** *padding*

**-relief** *relief*

**-shiftrelief** *amount*

  **-shiftrelief** specifies how far the button contents are shifted down and right in the *pressed* state. This action provides additional skeuomorphic feedback.

**-width** *amount*

Some options are only available for specific themes.

See the **ttk::style** manual page for information on how to configure ttk styles.

## SEE ALSO

ttk::widget(n), button(n)

## KEYWORDS

widget, button, default, command
