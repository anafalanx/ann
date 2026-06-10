# ttk::combobox

*Tk Themed Widget*

## NAME

ttk::combobox - text field with popdown selection list

## SYNOPSIS

**ttk::combobox** *pathName* ?*options*?

## DESCRIPTION

A **ttk::combobox** combines a text field with a pop-down list of values; the user may select the value of the text field from among the values in the list.

**Standard options** — see the referenced options manual:

- `-class`
- `-cursor`
- `-takefocus`
- `-style`
- `-placeholder`
- `-placeholderforeground`

## WIDGET-SPECIFIC OPTIONS

- **`-exportselection`** — database name `exportSelection`, class `ExportSelection`

Boolean value. If set, the widget selection is linked to the X selection.

- **`-justify`** — database name `justify`, class `Justify`

Specifies how the text is aligned within the widget. Must be one of **left**, **center**, or **right**.

- **`-height`** — database name `height`, class `Height`

Specifies the height of the pop-down listbox, in rows.

- **`-postcommand`** — database name `postCommand`, class `PostCommand`

A Tcl script to evaluate immediately before displaying the listbox. The **-postcommand** script may specify the **-values** to display.

- **`-state`** — database name `state`, class `State`

One of **normal**, **readonly**, or **disabled**. In the **readonly** state, the value may not be edited directly, and the user can only select one of the **-values** from the dropdown list. In the **normal** state, the text field is directly editable. In the **disabled** state, no interaction is possible.

- **`-textvariable`** — database name `textVariable`, class `TextVariable`

Specifies the name of a global variable whose value is linked to the widget value. Whenever the variable changes value the widget value is updated, and vice versa.

- **`-values`** — database name `values`, class `Values`

Specifies the list of values to display in the drop-down listbox.

- **`-width`** — database name `width`, class `Width`

Specifies an integer value indicating the desired width of the entry window, in average-size characters of the widget's font.

## WIDGET COMMAND

In addition to the standard **cget**, **configure**, **identify element**, **instate**, **state** and **style** commands (see **ttk::widget**), combobox widgets support the following additional commands:

*pathName* **current** ?*newIndex*?

If *newIndex* is supplied, sets the combobox value to the element at position *newIndex* in the list of **-values** (in addition to integers, the **end** index is supported and indicates the last element of the list, moreover the same simple interpretation as for the command **string index** is supported, with simple integer index arithmetic and indexing relative to **end**). Otherwise, returns the index of the current value in the list of **-values** or **{}** if the current value does not appear in the list.

*pathName* **get**

Returns the current value of the combobox.

*pathName* **set** *value*

Sets the value of the combobox to *value*.

The combobox widget also supports the following **ttk::entry** widget commands:

```
bbox	delete	icursor
index	insert	selection
xview
```

## VIRTUAL EVENTS

The combobox widget generates a **<<ComboboxSelected>>** virtual event when the user selects an element from the list of values. If the selection action unposts the listbox, this event is delivered after the listbox is unposted.

## STYLING OPTIONS

The class name for a **ttk::combobox** is **TCombobox**. The **ttk::combobox** uses the **entry** and **listbox** widgets internally. The listbox frame has a class name of **ComboboxPopdownFrame**.

Dynamic states: **disabled**, **focus**, **pressed**, **readonly**.

**TCombobox** styling options configurable with **ttk::style** are:

**-arrowcolor** *color*

**-arrowsize** *amount*

**-background** *color*

**-bordercolor** *color*

**-darkcolor** *color*

**-focusfill** *color*

**-foreground** *color*

**-fieldbackground** *color*

  Can only be changed when using non-native and non-graphical themes.

**-insertcolor** *color*

**-insertwidth** *amount*

**-lightcolor** *color*

**-padding** *padding*

**-placeholderforeground** *color*

**-postoffset** *padding*

**-selectbackground** *color*

  Text entry select background.

**-selectforeground** *color*

  Text entry select foreground.

The **ttk::combobox** popdown listbox cannot be configured using **ttk::style** nor via the widget **configure** command.  The listbox can be configured using the option database.

option add *TCombobox*Listbox.background *color*

option add *TCombobox*Listbox.font *font*

option add *TCombobox*Listbox.foreground *color*

option add *TCombobox*Listbox.selectBackground *color*

option add *TCombobox*Listbox.selectForeground *color*

To configure a specific listbox (subject to future change):

```tcl
set popdown [ttk::combobox::PopdownWindow .mycombobox]
$popdown.f.l configure -font font
```

**ComboboxPopdownFrame** styling options configurable with **ttk::style** are:

**-borderwidth** *amount*

**-relief** *relief*

Some options are only available for specific themes.

See the **ttk::style** manual page for information on how to configure ttk styles.

## SEE ALSO

ttk::widget(n), ttk::entry(n)

## KEYWORDS

choice, entry, list box, text box, widget
