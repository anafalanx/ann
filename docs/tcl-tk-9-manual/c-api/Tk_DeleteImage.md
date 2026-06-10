# Tk_DeleteImage

*Tk Library Procedures*

## NAME

Tk_DeleteImage - Destroy an image.

## SYNOPSIS

```
#include <tk.h>

Tk_DeleteImage(interp, name)
```

## ARGUMENTS

- **`Tcl_Interp *interp`** *(in)*
Interpreter for which the image was created.

- **`const char *name`** *(in)*
Name of the image.

## DESCRIPTION

**Tk_DeleteImage** deletes the image given by *interp* and *name*, if there is one.  All instances of that image will redisplay as empty regions.  If the given image does not exist then the procedure has no effect.

## KEYWORDS

delete image, image manager
