# Tcl_DoubleObj

*Tcl Library Procedures*

## NAME

Tcl_NewDoubleObj, Tcl_SetDoubleObj, Tcl_GetDoubleFromObj - manipulate Tcl values as floating-point values

## SYNOPSIS

```
#include <tcl.h>

Tcl_Obj *
Tcl_NewDoubleObj(doubleValue)

Tcl_SetDoubleObj(objPtr, doubleValue)

int
Tcl_GetDoubleFromObj(interp, objPtr, doublePtr)
```

## ARGUMENTS

- **`double doubleValue`** *(in)*
A double-precision floating-point value used to initialize or set a Tcl value.

- **`Tcl_Obj *objPtr`** *(in/out)*
For **Tcl_SetDoubleObj**, this points to the value in which to store a double value. For **Tcl_GetDoubleFromObj**, this refers to the value from which to retrieve a double value.

- **`Tcl_Interp *interp`** *(in/out)*
When non-NULL, an error message is left here when double value retrieval fails.

- **`double *doublePtr`** *(out)*
Points to place to store the double value obtained from *objPtr*.

## DESCRIPTION

These procedures are used to create, modify, and read Tcl values that hold double-precision floating-point values.

**Tcl_NewDoubleObj** creates and returns a new Tcl value initialized to the double value *doubleValue*.  The returned Tcl value is unshared.

**Tcl_SetDoubleObj** sets the value of an existing Tcl value pointed to by *objPtr* to the double value *doubleValue*.  The *objPtr* argument must point to an unshared Tcl value.  Any attempt to set the value of a shared Tcl value violates Tcl's copy-on-write policy.  Any existing string representation or internal representation in the unshared Tcl value will be freed as a consequence of setting the new value.

**Tcl_GetDoubleFromObj** attempts to retrieve a double value from the Tcl value *objPtr*.  If the attempt succeeds, then **TCL_OK** is returned, and the double value is written to the storage pointed to by *doublePtr*.  If the attempt fails, then **TCL_ERROR** is returned, and if *interp* is non-NULL, an error message is left in *interp*. The **Tcl_ObjType** of *objPtr* may be changed to make subsequent calls to **Tcl_GetDoubleFromObj** more efficient.

## REFERENCE COUNT MANAGEMENT

**Tcl_NewDoubleObj** always returns a zero-reference object, much like **Tcl_NewObj**.

**Tcl_SetDoubleObj** does not modify the reference count of its *objPtr* argument, but does require that the object be unshared.

**Tcl_GetDoubleFromObj** does not modify the reference count of its *objPtr* argument; it only reads. Note however that this function may set the interpreter result; if that is the only place that is holding a reference to the object, it will be deleted.

## SEE ALSO

Tcl_NewObj, Tcl_DecrRefCount, Tcl_IncrRefCount, Tcl_GetObjResult

## KEYWORDS

double, double value, double type, internal representation, value, value type, string representation
