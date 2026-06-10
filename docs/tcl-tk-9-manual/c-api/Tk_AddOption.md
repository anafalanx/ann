# Tk_AddOption

*Tk Library Procedures*

## NAME

Tk_AddOption - Add an option to the option database

## SYNOPSIS

```
#include <tk.h>

void
Tk_AddOption(tkwin, name, value, priority)

Tcl_Obj *
Tk_GetSystemDefault(tkwin, dbName, className)
```

## ARGUMENTS

- **`Tk_Window tkwin`** *(in)*
Token for window.

- **`const char *name`** *(in)*
Multi-element name of option.

- **`const char *value`** *(in)*
Value of option.

- **`const char *dbName`** *(in)*
The option database name.

- **`const char *className`** *(in)*
The name of the option class.

- **`int priority`** *(in)*
Overall priority level to use for option.

## DESCRIPTION

**Tk_AddOption** is invoked to add an option to the database associated with *tkwin*'s main window.  *Name* contains the option being specified and consists of names and/or classes separated by asterisks or dots, in the usual X format. *Value* contains the text string to associate with *name*; this value will be returned in calls to **Tk_GetOption**. *Priority* specifies the priority of the value; when options are queried using **Tk_GetOption**, the value with the highest priority is returned.  *Priority* must be between 0 and **TK_MAX_PRIO** (100). Some common priority values are:

Used for default values hard-coded into widgets.

Used for options specified in application-specific startup files.

Used for options specified in user-specific defaults files, such as **.Xdefaults**, resource databases loaded into the X server, or user-specific startup files.

Used for options specified interactively after the application starts running.

**Tk_GetSystemDefault** returns a Tcl_Obj* with the string identifying a configuration option matching the given *dbname* and *className*. Returns NULL if there are no system defaults that match this pair.

## KEYWORDS

class, name, option, add
