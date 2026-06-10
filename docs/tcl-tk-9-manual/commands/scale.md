# scale

*Tk Built-In Commands*

## NAME

scale - Create and manipulate 'scale' value-controlled slider widgets

## SYNOPSIS

**scale** *pathName* ?*options*?

**Standard options** — see the referenced options manual:

- `-activebackground`
- `-foreground`
- `-relief`
- `-background`
- `-highlightbackground`
- `-repeatdelay`
- `-borderwidth`
- `-highlightcolor`
- `-repeatinterval`
- `-cursor`
- `-highlightthickness`
- `-takefocus`
- `-font`
- `-orient`
- `-troughcolor`

## WIDGET-SPECIFIC OPTIONS

- **`-bigincrement`** — database name `bigIncrement`, class `BigIncrement`

Some interactions with the scale cause its value to change by “large” increments;  this option specifies the size of the large increments.  If specified as 0, the large increments default to 1/10 the range of the scale.

- **`-command`** — database name `command`, class `Command`

Specifies the prefix of a Tcl command to invoke whenever the scale's value is changed via a widget command. The actual command consists of this option followed by a space and a real number indicating the new value of the scale.

- **`-digits`** — database name `digits`, class `Digits`

An integer specifying how many significant digits should be retained when converting the value of the scale to a string. If the number is negative or zero, then the scale picks the smallest value that guarantees that every possible slider position prints as a different string.

- **`-from`** — database name `from`, class `From`

A real value corresponding to the left or top end of the scale.

- **`-label`** — database name `label`, class `Label`

A string to display as a label for the scale.  For vertical scales the label is displayed just to the right of the top end of the scale.  For horizontal scales the label is displayed just above the left end of the scale.  If the option is specified as an empty string, no label is displayed.

- **`-length`** — database name `length`, class `Length`

Specifies the desired long dimension of the scale in screen units (i.e. any of the forms acceptable to **Tk_GetPixels**). For vertical scales this is the scale's height;  for horizontal scales it is the scale's width.

- **`-resolution`** — database name `resolution`, class `Resolution`

A real value specifying the resolution for the scale. If this value is greater than zero then the scale's value will always be rounded to an even multiple of this value, as will the endpoints of the scale.  If the value is negative then no rounding occurs.  Defaults to 1 (i.e., the value will be integral).

- **`-showvalue`** — database name `showValue`, class `ShowValue`

Specifies a boolean value indicating whether or not the current value of the scale is to be displayed.

- **`-sliderlength`** — database name `sliderLength`, class `SliderLength`

Specifies the size of the slider, measured in screen units along the slider's long dimension.  The value may be specified in any of the forms acceptable to **Tk_GetPixels**.

- **`-sliderrelief`** — database name `sliderRelief`, class `SliderRelief`

Specifies the relief to use when drawing the slider, such as **raised** or **sunken**.

- **`-state`** — database name `state`, class `State`

Specifies one of three states for the scale:  **normal**, **active**, or **disabled**. If the scale is disabled then the value may not be changed and the scale will not activate. If the scale is active, the slider is displayed using the color specified by the **-activebackground** option.

- **`-tickinterval`** — database name `tickInterval`, class `TickInterval`

Must be a real value. Determines the spacing between numerical tick marks displayed below or to the left of the slider. The values will all be displayed with the same number of decimal places, which will be enough to ensure they are all accurate to within 20% of a tick interval. If 0, no tick marks will be displayed.

- **`-to`** — database name `to`, class `To`

Specifies a real value corresponding to the right or bottom end of the scale. This value may be either less than or greater than the **-from** option.

- **`-variable`** — database name `variable`, class `Variable`

Specifies the name of a global variable to link to the scale.  Whenever the value of the variable changes, the scale will update to reflect this value. Whenever the scale is manipulated interactively, the variable will be modified to reflect the scale's new value.

- **`-width`** — database name `width`, class `Width`

Specifies the desired narrow dimension of the scale in screen units (i.e. any of the forms acceptable to **Tk_GetPixels**). For vertical scales this is the scale's width;  for horizontal scales this is the scale's height.

## DESCRIPTION

The **scale** command creates a new window (given by the *pathName* argument) and makes it into a scale widget. Additional options, described above, may be specified on the command line or in the option database to configure aspects of the scale such as its colors, orientation, and relief.  The **scale** command returns its *pathName* argument.  At the time this command is invoked, there must not exist a window named *pathName*, but *pathName*'s parent must exist.

A scale is a widget that displays a rectangular *trough* and a small *slider*.  The trough corresponds to a range of real values (determined by the **-from**, **-to**, and **-resolution** options), and the position of the slider selects a particular real value. The slider's position (and hence the scale's value) may be adjusted with the mouse or keyboard as described in the **BINDINGS** section below.  Whenever the scale's value is changed, a Tcl command is invoked (using the **-command** option) to notify other interested widgets of the change. In addition, the value of the scale can be linked to a Tcl variable (using the **-variable** option), so that changes in either are reflected in the other.

Three annotations may be displayed in a scale widget:  a label appearing at the top right of the widget (top left for horizontal scales), a number displayed just to the left of the slider (just above the slider for horizontal scales), and a collection of numerical tick marks just to the left of the current value (just below the trough for horizontal scales).  Each of these three annotations may be enabled or disabled using the configuration options.

## WIDGET COMMAND

The **scale** command creates a new Tcl command whose name is *pathName*.  This command may be used to invoke various operations on the widget.  It has the following general form:

```tcl
pathName option ?arg ...?
```

*Option* and the *arg*s determine the exact behavior of the command.  The following commands are possible for scale widgets:

*pathName* **cget** *option*

Returns the current value of the configuration option given by *option*. *Option* may have any of the values accepted by the **scale** command.

*pathName* **configure** ?*option*? ?*value option value ...*?

Query or modify the configuration options of the widget. If no *option* is specified, returns a list describing all of the available options for *pathName* (see **Tk_ConfigureInfo** for information on the format of this list).  If *option* is specified with no *value*, then the command returns a list describing the one named option (this list will be identical to the corresponding sublist of the value returned if no *option* is specified).  If one or more *option-value* pairs are specified, then the command modifies the given widget option(s) to have the given value(s);  in this case the command returns an empty string. *Option* may have any of the values accepted by the **scale** command.

*pathName* **coords** ?*value*?

Returns a list whose elements are the x and y coordinates of the point along the centerline of the trough that corresponds to *value*. If *value* is omitted then the scale's current value is used.

*pathName* **get** ?*x y*?

If *x* and *y* are omitted, returns the current value of the scale.  If *x* and *y* are specified, they give pixel coordinates within the widget;  the command returns the scale value corresponding to the given pixel. Only one of *x* or *y* is used:  for horizontal scales *y* is ignored, and for vertical scales *x* is ignored.

*pathName* **identify** *x y*

Returns a string indicating what part of the scale lies under the coordinates given by *x* and *y*. A return value of **slider** means that the point is over the slider;  **trough1** means that the point is over the portion of the slider above  or to the left of the slider; and **trough2** means that the point is over the portion of the slider below or to the right of the slider. If the point is not over one of these elements, an empty string is returned.

*pathName* **set** *value*

This command is invoked to change the current value of the scale, and hence the position at which the slider is displayed.  *Value* gives the new value for the scale. The command has no effect if the scale is disabled.

## BINDINGS

Tk automatically creates class bindings for scales that give them the following default behavior. Where the behavior is different for vertical and horizontal scales, the horizontal behavior is described in parentheses.

If button 1 is pressed in the trough, the scale's value will be incremented or decremented by the value of the **-resolution** option so that the slider moves in the direction of the cursor. If the button is held down, the action auto-repeats.

If button 1 is pressed over the slider, the slider can be dragged with the mouse.

If button 1 is pressed in the trough with the Control key down, the slider moves all the way to the end of its range, in the direction towards the mouse cursor.

If button 2 is pressed, the scale's value is set to the mouse position.  If the mouse is dragged with button 2 down, the scale's value changes with the drag.

The Up and Left keys move the slider up (left) by the value of the **-resolution** option.

The Down and Right keys move the slider down (right) by the value of the **-resolution** option.

Control-Up and Control-Left move the slider up (left) by the value of the **-bigincrement** option.

Control-Down and Control-Right move the slider down (right) by the value of the **-bigincrement** option.

Home moves the slider to the top (left) end of its range.

End moves the slider to the bottom (right) end of its range.

If the scale is disabled using the **-state** option then none of the above bindings have any effect.

The behavior of scales can be changed by defining new bindings for individual widgets or by redefining the class bindings.

## SEE ALSO

ttk::scale(n)

## KEYWORDS

scale, slider, trough, widget
