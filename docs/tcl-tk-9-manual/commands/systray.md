# tk

*Tk*

## NAME

systray - Creates an icon display in the platform-specific system tray.

## SYNOPSIS

```
tk systray create -image image ?-text text? ?-button1 callback? ?-button3 callback?
tk systray configure ?option? ?value option value ...?
tk systray exists
tk systray destroy
```

## DESCRIPTION

The **tk systray create** command creates an icon in the platform-specific tray. The widget is configured with a Tk image for the icon display, an optional string for display in a tooltip, and optional callbacks that are bound to <Button-1> and <Button-3>.

The **tk systray configure** command sets one or more options of the systray icon. Configurable options are the same as for the **create** subcommand. When a single option name is given, the command returns the current value of this option. When no option is given this command returns the list of all options and their current value.

The **tk systray exists** command checks whether a systray icon was created. It returns a boolean.

The **tk systray destroy** command removes the icon from display and deallocates it.

From a user-interface standpoint, only one icon per interpreter is supported; attempts to create additional icons will return an error. The existing tray icon can be modified with different images and strings to indicate app state. Loading additional interpreters into a running instance of Wish will allow additional icons to be displayed.

## EXAMPLE

Here is an example of the **tk systray** code:

```tcl
image create photo book -data \
        R0lGODlhDwAPAKIAAP//////AP8AAMDAwICAgAAAAAAAAAAAACwAAAAADwAPAAADSQhA2u5ksPeKABKSCaya29d4WKgERFF0l1IMQCAKatvBJ0OTdzzXI1xMB3TBZAvATtB6NSLKleXi3OBoLqrVgc0yv+DVSEUuFxIAOw==
tk systray create -image book -text "tk systray sample" \
        -button1 {puts "Here is the tk systray output"} \
        -button3 {puts "here is alternate output"}
```

Here is an example of modifying the **tk systray** icon:

```tcl
image create photo book_page -data \
        R0lGODlhCwAPAKIAAP//////AMDAwICAgAAA/wAAAAAAAAAAACwAAAAACwAPAAADMzi6CzAugiAgDGE68aB0RXgRJBFVX0SNpQlUWfahQOvSsgrX7eZJMlQMWBEYj8iQchlKAAA7
tk systray configure -image book_page -text "Updated sample" \
        -button1 {puts "Different output from the tk systray"} \
        -button3 {puts "and more different output from the tk systray"}
```

## PLATFORM NOTES

The X11 implementation is supported on a "best efforts" basis because it is dependent on the window manager. The "text" flag, which is implemented as a tooltip, does not always display if the WM does not support such features; the systray icon itself may not even display with some window managers.

On Windows, the Tk image provided in the **-image** option must be a photo image. On other platforms either a bitmap image or a photo image may be provided.

## KEYWORDS

image, callback
