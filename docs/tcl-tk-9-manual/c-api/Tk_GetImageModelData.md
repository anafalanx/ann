# Tk_CreateImageType

*Tk Library Procedures*

## NAME

Tk_CreateImageType, Tk_GetImageModelData - define new kind of image

## SYNOPSIS

```
#include <tk.h>

Tk_CreateImageType(typePtr)

void *
Tk_GetImageModelData(interp, name, typePtrPtr)
```

## ARGUMENTS

- **`const Tk_ImageType *typePtr`** *(in)*
Structure that defines the new type of image. For Tk 8.4 and earlier this must be static: a pointer to this structure is retained by the image code. In Tk 8.5, this limitation was relaxed.

- **`Tcl_Interp *interp`** *(in)*
Interpreter in which image was created.

- **`const char *name`** *(in)*
Name of existing image.

- **`Tk_ImageType **typePtrPtr`** *(out)*
Points to word in which to store a pointer to type information for the given image, if it exists.

- **`char ***argvPtr`** *(in/out)*
Pointer to argument list

## DESCRIPTION

**Tk_CreateImageType** is invoked to define a new kind of image. An image type corresponds to a particular value of the *type* argument for the **image create** command.  There may exist any number of different image types, and new types may be defined dynamically by calling **Tk_CreateImageType**. For example, there might be one type for 2-color bitmaps, another for multi-color images, another for dithered images, another for video, and so on.

The code that implements a new image type is called an *image manager*. It consists of a collection of procedures plus three different kinds of data structures. The first data structure is a Tk_ImageType structure, which contains the name of the image type and pointers to five procedures provided by the image manager to deal with images of this type:

```tcl
typedef struct {
    const char *name;
    Tk_ImageCreateProc *createProc;
    Tk_ImageGetProc *getProc;
    Tk_ImageDisplayProc *displayProc;
    Tk_ImageFreeProc *freeProc;
    Tk_ImageDeleteProc *deleteProc;
} Tk_ImageType;
```

The fields of this structure will be described in later subsections of this entry.

The second major data structure manipulated by an image manager is called an *image model*;  it contains overall information about a particular image, such as the values of the configuration options specified in an **image create** command. There will usually be one of these structures for each invocation of the **image create** command.

The third data structure related to images is an *image instance*. There will usually be one of these structures for each usage of an image in a particular widget. It is possible for a single image to appear simultaneously in multiple widgets, or even multiple times in the same widget. Furthermore, different instances may be on different screens or displays. The image instance data structure describes things that may vary from instance to instance, such as colors and graphics contexts for redisplay. There is usually one instance structure for each **-image** option specified for a widget or canvas item.

The following subsections describe the fields of a Tk_ImageType in more detail.

### NAME

*typePtr->name* provides a name for the image type. Once **Tk_CreateImageType** returns, this name may be used in **image create** commands to create images of the new type. If there already existed an image type by this name then the new image type replaces the old one.

### CREATEPROC

*typePtr->createProc* provides the address of a procedure for Tk to call whenever **image create** is invoked to create an image of the new type. *typePtr->createProc* must match the following prototype:

```tcl
typedef int Tk_ImageCreateProc(
        Tcl_Interp *interp,
        const char *name,
        int objc,
        Tcl_Obj *const objv[],
        const Tk_ImageType *typePtr,
        Tk_ImageModel model,
        void **modelDataPtr);
```

The *interp* argument is the interpreter in which the **image** command was invoked, and *name* is the name for the new image, which was either specified explicitly in the **image** command or generated automatically by the **image** command. The *objc* and *objv* arguments describe all the configuration options for the new image (everything after the name argument to **image**). The *model* argument is a token that refers to Tk's information about this image;  the image manager must return this token to Tk when invoking the **Tk_ImageChanged** procedure. Typically *createProc* will parse *objc* and *objv* and create an image model data structure for the new image. *createProc* may store an arbitrary one-word value at **modelDataPtr*, which will be passed back to the image manager when other callbacks are invoked. Typically the value is a pointer to the model data structure for the image.

If *createProc* encounters an error, it should leave an error message in the interpreter result and return **TCL_ERROR**;  otherwise it should return **TCL_OK**.

*createProc* should call **Tk_ImageChanged** in order to set the size of the image and request an initial redisplay.

### GETPROC

*typePtr->getProc* is invoked by Tk whenever a widget calls **Tk_GetImage** to use a particular image. This procedure must match the following prototype:

```tcl
typedef void *Tk_ImageGetProc(
        Tk_Window tkwin,
        void *modelData);
```

The *tkwin* argument identifies the window in which the image will be used and *modelData* is the value returned by *createProc* when the image model was created. *getProc* will usually create a data structure for the new instance, including such things as the resources needed to display the image in the given window. *getProc* returns a one-word token for the instance, which is typically the address of the instance data structure. Tk will pass this value back to the image manager when invoking its *displayProc* and *freeProc* procedures.

### DISPLAYPROC

*typePtr->displayProc* is invoked by Tk whenever an image needs to be displayed (i.e., whenever a widget calls **Tk_RedrawImage**). *displayProc* must match the following prototype:

```tcl
typedef void Tk_ImageDisplayProc(
        void *instanceData,
        Display *display,
        Drawable drawable,
        int imageX,
        int imageY,
        int width,
        int height,
        int drawableX,
        int drawableY);
```

The *instanceData* will be the same as the value returned by *getProc* when the instance was created. *display* and *drawable* indicate where to display the image;  *drawable* may be a pixmap rather than the window specified to *getProc* (this is usually the case, since most widgets double-buffer their redisplay to get smoother visual effects). *imageX*, *imageY*, *width*, and *height* identify the region of the image that must be redisplayed. This region will always be within the size of the image as specified in the most recent call to **Tk_ImageChanged**. *drawableX* and *drawableY* indicate where in *drawable* the image should be displayed;  *displayProc* should display the given region of the image so that point (*imageX*, *imageY*) in the image appears at (*drawableX*, *drawableY*) in *drawable*.

### FREEPROC

*typePtr->freeProc* contains the address of a procedure that Tk will invoke when an image instance is released (i.e., when **Tk_FreeImage** is invoked). This can happen, for example, when a widget is deleted or a image item in a canvas is deleted, or when the image displayed in a widget or canvas item is changed. *freeProc* must match the following prototype:

```tcl
typedef void Tk_ImageFreeProc(
        void *instanceData,
        Display *display);
```

The *instanceData* will be the same as the value returned by *getProc* when the instance was created, and *display* is the display containing the window for the instance. *freeProc* should release any resources associated with the image instance, since the instance will never be used again.

### DELETEPROC

*typePtr->deleteProc* is a procedure that Tk invokes when an image is being deleted (i.e. when the **image delete** command is invoked). Before invoking *deleteProc* Tk will invoke *freeProc* for each of the image's instances. *deleteProc* must match the following prototype:

```tcl
typedef void Tk_ImageDeleteProc(
        void *modelData);
```

The *modelData* argument will be the same as the value stored in **modelDataPtr* by *createProc* when the image was created. *deleteProc* should release any resources associated with the image.

## TK_GETIMAGEMODELDATA

The procedure **Tk_GetImageModelData** may be invoked to retrieve information about an image.  For example, an image manager can use this procedure to locate its image model data for an image. If there exists an image named *name* in the interpreter given by *interp*, then **typePtrPtr* is filled in with type information for the image (the *typePtr* value passed to **Tk_CreateImageType** when the image type was registered) and the return value is the clientData value returned by the *createProc* when the image was created (this is typically a pointer to the image model data structure).  If no such image exists then NULL is returned and NULL is stored at **typePtrPtr*.

## SEE ALSO

Tk_ImageChanged, Tk_GetImage, Tk_FreeImage, Tk_RedrawImage, Tk_SizeOfImage

## KEYWORDS

image manager, image type, instance, model
