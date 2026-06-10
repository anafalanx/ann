# frame

*Tk Built-In Commands*

## NAME

frame - Create and manipulate 'frame' simple container widgets

## SYNOPSIS

**frame** *pathName* ?*options*?

**Standard options** — see the referenced options manual:

- `-borderwidth`
- `-highlightcolor`
- `-pady`
- `-cursor`
- `-highlightthickness`
- `-relief`
- `-highlightbackground`
- `-padx`
- `-takefocus`

## WIDGET-SPECIFIC OPTIONS

- **`-background`** — database name `background`, class `Background`

This option is the same as the standard **-background** option except that its value may also be specified as an empty string. In this case, the widget will display no background or border, and no colors will be consumed from its colormap for its background and border. An empty background will disable drawing the background image.

- **`-backgroundimage`** — database name `backgroundImage`, class `BackgroundImage`

This specifies an image to display on the frame's background within the border of the frame (i.e., the image will be clipped by the frame's highlight ring and border, if either are present); subwidgets of the frame will be drawn on top. The image must have been created with the **image create** command. If specified as the empty string, no image will be displayed.

- **`-class`** — database name `class`, class `Class`

Specifies a class for the window. This class will be used when querying the option database for the window's other options, and it will also be used later for other purposes such as bindings. The **-class** option may not be changed with the **configure** widget command.

- **`-colormap`** — database name `colormap`, class `Colormap`

Specifies a colormap to use for the window. The value may be either **new**, in which case a new colormap is created for the window and its children, or the name of another window (which must be on the same screen and have the same visual as *pathName*), in which case the new window will use the colormap from the specified window. If the **-colormap** option is not specified, the new window uses the same colormap as its parent. This option may not be changed with the **configure** widget command.

- **`-container`** — database name `container`, class `Container`

The value must be a boolean.  If true, it means that this window will be used as a container in which some other application will be embedded (for example, a Tk toplevel can be embedded using the **-use** option). The window will support the appropriate window manager protocols for things like geometry requests.  The window should not have any children of its own in this application. This option may not be changed with the **configure** widget command. Note that **-borderwidth**, **-padx** and **-pady** are ignored when configured as a container since a container has no border.

- **`-height`** — database name `height`, class `Height`

Specifies the desired height for the window in any of the forms acceptable to **Tk_GetPixels**.  If this option is negative or zero then the window will not request any size at all.  Note that this sets the total height of the frame, any **-borderwidth** or similar is not added.  Normally **-height** should not be used if a propagating geometry manager, such as **grid** or **pack**, is used within the frame since the geometry manager will override the height of the frame.

- **`-tile`** — database name `tile`, class `Tile`

This specifies how to draw the background image (see **-backgroundimage**) on the frame. If true (according to **Tcl_GetBoolean**), the image will be tiled to fill the whole frame, with the origin of the first copy of the image being the top left of the interior of the frame. If false (the default), the image will be centered within the frame.

- **`-visual`** — database name `visual`, class `Visual`

Specifies visual information for the new window in any of the forms accepted by **Tk_GetVisual**. If this option is not specified, the new window will use the same visual as its parent. The **-visual** option may not be modified with the **configure** widget command.

- **`-width`** — database name `width`, class `Width`

Specifies the desired width for the window in any of the forms acceptable to **Tk_GetPixels**.  If this option is negative or zero then the window will not request any size at all.  Note that this sets the total width of the frame, any **-borderwidth** or similar is not added.  Normally **-width** should not be used if a propagating geometry manager, such as **grid** or **pack**, is used within the frame since the geometry manager will override the width of the frame.

## DESCRIPTION

The **frame** command creates a new window (given by the *pathName* argument) and makes it into a frame widget. Additional options, described above, may be specified on the command line or in the option database to configure aspects of the frame such as its background color and relief.  The **frame** command returns the path name of the new window.

A frame is a simple widget.  Its primary purpose is to act as a spacer or container for complex window layouts.  The only features of a frame are its background and an optional 3-D border to make the frame appear raised or sunken.

## WIDGET COMMAND

The **frame** command creates a new Tcl command whose name is the same as the path name of the frame's window.  This command may be used to invoke various operations on the widget.  It has the following general form:

```tcl
pathName option ?arg ...?
```

*PathName* is the name of the command, which is the same as the frame widget's path name.  *Option* and the *arg*s determine the exact behavior of the command.  The following commands are possible for frame widgets:

*pathName* **cget** *option*

Returns the current value of the configuration option given by *option*. *Option* may have any of the values accepted by the **frame** command.

*pathName* **configure** ?*option*? ?*value option value ...*?

Query or modify the configuration options of the widget. If no *option* is specified, returns a list describing all of the available options for *pathName* (see **Tk_ConfigureInfo** for information on the format of this list).  If *option* is specified with no *value*, then the command returns a list describing the one named option (this list will be identical to the corresponding sublist of the value returned if no *option* is specified).  If one or more *option-value* pairs are specified, then the command modifies the given widget option(s) to have the given value(s);  in this case the command returns an empty string. *Option* may have any of the values accepted by the **frame** command.

## BINDINGS

When a new frame is created, it has no default event bindings: frames are not intended to be interactive.

## SEE ALSO

labelframe(n), toplevel(n), ttk::frame(n)

## KEYWORDS

frame, widget
