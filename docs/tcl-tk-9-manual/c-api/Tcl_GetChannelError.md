# Tcl_SetChannelError

*Tcl Library Procedures*

## NAME

Tcl_SetChannelError, Tcl_SetChannelErrorInterp, Tcl_GetChannelError, Tcl_GetChannelErrorInterp - functions to create/intercept Tcl errors by channel drivers.

## SYNOPSIS

```
#include <tcl.h>

Tcl_SetChannelError(chan, msg)

Tcl_SetChannelErrorInterp(interp, msg)

Tcl_GetChannelError(chan, msgPtr)

Tcl_GetChannelErrorInterp(interp, msgPtr)
```

## ARGUMENTS

- **`Tcl_Channel chan`** *(in)*
Refers to the Tcl channel whose bypass area is accessed.

- **`Tcl_Interp* interp`** *(in)*
Refers to the Tcl interpreter whose bypass area is accessed.

- **`Tcl_Obj* msg`** *(in)*
Error message put into a bypass area. A list of return options and values, followed by a string message. Both message and the option/value information are optional. This *must* be a well-formed list.

- **`Tcl_Obj** msgPtr`** *(out)*
Reference to a place where the message stored in the accessed bypass area can be stored in.

## DESCRIPTION

The standard definition of a Tcl channel driver does not permit the direct return of arbitrary error messages, except for the setting and retrieval of channel options. All other functions are restricted to POSIX error codes.

The functions described here overcome this limitation. Channel drivers are allowed to use **Tcl_SetChannelError** and **Tcl_SetChannelErrorInterp** to place arbitrary error messages in *bypass areas* defined for channels and interpreters. And the generic I/O layer uses **Tcl_GetChannelError** and **Tcl_GetChannelErrorInterp** to look for messages in the bypass areas and arrange for their return as errors. The POSIX error codes set by a driver are used now if and only if no messages are present.

**Tcl_SetChannelError** stores error information in the bypass area of the specified channel. The number of references to the **msg** value goes up by one. Previously stored information will be discarded, by releasing the reference held by the channel. The channel reference must not be NULL.

**Tcl_SetChannelErrorInterp** stores error information in the bypass area of the specified interpreter. The number of references to the **msg** value goes up by one. Previously stored information will be discarded, by releasing the reference held by the interpreter. The interpreter reference must not be NULL.

**Tcl_GetChannelError** places either the error message held in the bypass area of the specified channel into *msgPtr*, or NULL; and resets the bypass, that is, after an invocation all following invocations will return NULL, until an intervening invocation of **Tcl_SetChannelError** with a non-NULL message. The *msgPtr* must not be NULL. The reference count of the message is not touched.  The reference previously held by the channel is now held by the caller of the function and it is its responsibility to release that reference when it is done with the value.

**Tcl_GetChannelErrorInterp** places either the error message held in the bypass area of the specified interpreter into *msgPtr*, or NULL; and resets the bypass, that is, after an invocation all following invocations will return NULL, until an intervening invocation of **Tcl_SetChannelErrorInterp** with a non-NULL message. The *msgPtr* must not be NULL. The reference count of the message is not touched.  The reference previously held by the interpreter is now held by the caller of the function and it is its responsibility to release that reference when it is done with the value.

Which functions of a channel driver are allowed to use which bypass function is listed below, as is which functions of the public channel API may leave a messages in the bypass areas.

- May use **Tcl_SetChannelError**, and only this function.

- May use **Tcl_SetChannelError**, and only this function.

- May use **Tcl_SetChannelError**, and only this function.

- Has already the ability to pass arbitrary error messages. Must *not* use any of the new functions.

- Has already the ability to pass arbitrary error messages. Must *not* use any of the new functions.

- Must *not* use any of the new functions. Is internally called and has no ability to return any type of error whatsoever.

- May use **Tcl_SetChannelError**, and only this function.

- Must *not* use any of the new functions. It is only a low-level function, and not used by Tcl commands.

- Must *not* use any of the new functions. Is internally called and has no ability to return any type of error whatsoever.

Given the information above the following public functions of the Tcl C API are affected by these changes; when these functions are called, the channel may now contain a stored arbitrary error message requiring processing by the caller.

```
Tcl_Flush	Tcl_GetsObj	Tcl_Gets
Tcl_ReadChars	Tcl_ReadRaw	Tcl_Read
Tcl_Seek	Tcl_StackChannel	Tcl_Tell
Tcl_WriteChars	Tcl_WriteObj	Tcl_WriteRaw
Tcl_Write
```

All other API functions are unchanged. In particular, the functions below leave all their error information in the interpreter result.

```
Tcl_Close	Tcl_UnstackChannel	Tcl_UnregisterChannel
```

## REFERENCE COUNT MANAGEMENT

The *msg* argument to **Tcl_SetChannelError** and **Tcl_SetChannelErrorInterp**, if not NULL, may have any reference count; these functions will copy.

**Tcl_GetChannelError** and **Tcl_GetChannelErrorInterp** write a value reference into their *msgPtr*, but do not manipulate its reference count. The reference count will be at least 1 (unless the reference is NULL).

## SEE ALSO

Tcl_Close(3), Tcl_OpenFileChannel(3), Tcl_SetErrno(3)

## KEYWORDS

channel driver, error messages, channel type
