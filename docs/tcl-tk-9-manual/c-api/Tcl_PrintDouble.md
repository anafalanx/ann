# Tcl_PrintDouble

*Tcl Library Procedures*

## NAME

Tcl_PrintDouble - Convert floating value to string

## SYNOPSIS

```
#include <tcl.h>

Tcl_PrintDouble(interp, value, dst)
```

## ARGUMENTS

- **`Tcl_Interp *interp`** *(in)*
This argument is ignored.

- **`double value`** *(in)*
Floating-point value to be converted.

- **`char *dst`** *(out)*
Where to store the string representing *value*.  Must have at least **TCL_DOUBLE_SPACE** characters of storage.

## DESCRIPTION

**Tcl_PrintDouble** generates a string that represents the value of *value* and stores it in memory at the location given by *dst*.  It uses **%g** format to generate the string, with one special twist: the string is guaranteed to contain either a “.” or an “e” so that it does not look like an integer.  Where **%g** would generate an integer with no decimal point, **Tcl_PrintDouble** adds “.0”.

The result will have the fewest digits needed to represent the number in such a way that **Tcl_NewDoubleObj** will generate the same number when presented with the given string. IEEE semantics of rounding to even apply to the conversion.

## KEYWORDS

conversion, double-precision, floating-point, string
