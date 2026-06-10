# Tk_NameOfImage

*Tk Library Procedures*

## NAME

Tk_NameOfImage - Return name of image.

## SYNOPSIS

```
#include <tk.h>

const char *
Tk_NameOfImage(imageModel)
```

## ARGUMENTS

- **`Tk_ImageModel imageModel`** *(in)*
Token for image, which was passed to image manager's *createProc* when the image was created.

## DESCRIPTION

This procedure is invoked by image managers to find out the name of an image.  Given the token for the image, it returns the string name for the image.

## KEYWORDS

image manager, image name
