# Tk_GetScrollInfo

*Tk Library Procedures*

## NAME

Tk_GetScrollInfoObj, Tk_GetScrollInfo - parse arguments for scrolling commands

## SYNOPSIS

```
#include <tk.h>

int
Tk_GetScrollInfoObj(interp, objc, objv, fractionPtr, stepsPtr)

int
Tk_GetScrollInfo(interp, argc, argv, fractionPtr, stepsPtr)
```

## ARGUMENTS

- **`Tcl_Interp *interp`** *(in)*
Interpreter to use for error reporting.

- **`Tcl_Size objc`** *(in)*
Number of Tcl_Obj's in *objv* array.

- **`Tcl_Obj *const * objv`** *(in)*
Argument objects.  These represent the entire widget command, of which the first word is typically the widget name and the second word is typically **xview** or **yview**.

- **`int argc`** *(in)*
Number of strings in *argv* array.

- **`const char ** argv`** *(in)*
Argument strings.  These represent the entire widget command, of which the first word is typically the widget name and the second word is typically **xview** or **yview**.

- **`double *fractionPtr`** *(out)*
Filled in with fraction from **moveto** option, if any.

- **`int *stepsPtr`** *(out)*
Filled in with line or page count from **scroll** option, if any. The value may be negative.

## DESCRIPTION

**Tk_GetScrollInfoObj** parses the arguments expected by widget scrolling commands such as **xview** and **yview**. It receives the entire list of words that make up a widget command and parses the words starting with *objv*[2]. The words starting with *objv*[2] must have one of the following forms:

```tcl
moveto fraction
scroll number pages
scroll number units
```

Any of the **moveto**, **scroll**, **pages**, and **units** keywords may be abbreviated. If *objv* has the **moveto** form, **TK_SCROLL_MOVETO** is returned as result and **fractionPtr* is filled in with the *fraction* argument to the command, which must be a proper real value. If *objv* has the **scroll** form, **TK_SCROLL_PAGES** or **TK_SCROLL_UNITS** is returned and **stepsPtr* is filled in with the *number* value, which must be a  integer or a float, but if it is a float then it is converted to an integer, rounded away from 0. If an error occurs in parsing the arguments, **TK_SCROLL_ERROR** is returned and an error message is left in interpreter *interp*'s result.

**Tk_GetScrollInfo** is identical in function to **Tk_GetScrollInfoObj**.  However, **Tk_GetScrollInfo** accepts string arguments, making it more appropriate for use with legacy widgets.

## KEYWORDS

parse, scrollbar, scrolling command, xview, yview
