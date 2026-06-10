# Tk_ConfigureWindow

*Tk Library Procedures*

## NAME

Tk_GetOtherWindow, Tk_MakeContainer, Tk_MakeWindow, Tk_UseWindow - window utility functions

## SYNOPSIS

```
#include <tk.h>

Tk_Window
Tk_GetOtherWindow(tkwin)

Tk_MakeContainer(tkwin)

Tk_MakeWindow(tkwin, parent)

int
Tk_UseWindow(interp, tkwin, string)
```

## ARGUMENTS

- **`Tcl_Interp *`** *(interp)*
Interpreter associated with the application.

- **`Tk_Window tkwin`** *(in)*
Token for window.

- **`Window parent`** *(in)*
Parent window.

- **`const char *string`** *(in)*
String identifying an X window to use for *tkwin*; must be an integer value.

## DESCRIPTION

If both the container and embedded window are in the same process, **Tk_GetOtherWindow** will return either one, given the other. If winPtr is a container, the return value is the token for the embedded window, and vice versa. If the "other" window isn't in this process, NULL is returned.

**Tk_MakeContainer** is called to indicate that a particular window will be a container for an embedded application. This changes certain aspects of the window's behavior, such as whether it will receive events anymore.

**Tk_MakeWindow** creates an actual window system window object based on the current attributes of the specified TkWindow. It returns the handle to the new window, or None on failure.

**Tk_UseWindow** causes a Tk window to use a given X window as its parent window, rather than the root window for the screen. It is invoked by an embedded application to specify the window in which it is embedded.

The return value is normally TCL_OK. If an error occurs (such as string not being a valid window spec), then the return value is TCL_ERROR and an error message is left in the interp's result if interp is non-NULL.

## KEYWORDS

parent, window
