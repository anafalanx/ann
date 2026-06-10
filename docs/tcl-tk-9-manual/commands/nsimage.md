# nsimage

*Tk Built-In Commands*

## NAME

nsimage - A Tk image type for macOS based on the NSImage class.

## DESCRIPTION

The nsimage is implemented as a Tk image type.  The **image** command is used to create, delete, and query all images, including images of type **nsimage**.  The options that are available are specific to the nsimage type and are described below.

The command to create an **nsimage**:

**image create nsimage** ?*name*? ?*option value ...*?

creates a new nsimage and a command with the same name and returns its name.

## OPTIONS

Valid *options* are:

**-source** *string*

The value of the **-source** option is a string describing an NSimage.  There are several ways to interpret this string, and the interpretation is determined by the value of the **-as** option. This option is required.

**-as** *type*

There are four possible values for the **-as** option which specify how the source string should be interpreted.  The allowed values and their meanings are:

  The source should be interpreted as the name of a named NSImage provided by the system. This is the default if the **-as** option is not specified.

  The source should be interpreted as a path to an image file in one of the formats understood by the NSImage class.

  The source should be interpreted as a path to an arbitrary file. The type of the file will be examined and the resulting image will be the system icon for files of that type.

  The source is interpreted as a string identifying a particular file type.  It may be a filename extension, an Apple Uniform Type Identifier or a 4-character OSType value as used in the HFS filesystem.

**-width** *pixels*

The value of the *width* option is an integer specifying the width in pixels of the nsimage.  If the width is not specified it will be computed from the height so as to preserve the aspect ration.  If neither width nor height are specified then the width and height of the underlying NSImage will be used.

**-height** *pixels*

The value of the *height* option is an integer specifying the height in pixels of the nsimage. If the height is not specified it will be computed from the height so as to preserve the aspect ration. If neither width nor height are specified then the width and height of the underlying NSImage will be used.

**-radius** *pixels*

The value of the *radius* option is an integer.  If non-zero the image will be clipped to a rounded rectangle with the same width and height as the image, but with circular arcs of the specified radius cutting off the corners of the rectangle.

**-ring** *pixels*

The value of the *ring* option is an integer.  If non-zero then it specifies the thickness of a focus ring which will be drawn around the image using the control accent color specified in the System Preferences.  The image is resized to reduce its width and height by twice the thickness of the ring.  Note that this may create a small amount of distortion.  The aspect ration of a non-square image will change slightly.

**-alpha** *float*

The value of the *alpha* option should be a floating point number between 0.0 and 1.0.  This alpha value will be applied to each pixel of the nsimage, producing a partially transparent image.  The default value is 1.0, which makes the image opaque.

**-pressed** *boolean*

The *pressed* option takes a boolean value.  If the value is true or 1 then the image will be algorithmically modified to become darker in light mode or lighter in dark mode.  The default is false.  For an image button, the primary image should use the value false while the pressed image should be the same image but with the *pressed* option set to true.

**-template** *boolean*

The *template* option takes a boolean value.  If the value is true or 1 then the image will be marked as being a template image.  This means that the system will algorithmically convert the image to a light colored image when in dark mode.  For the algorithm to work correctly the image must consist only of black pixels with alpha values.

## SEE ALSO

image(n), options(n), photo(n)

## KEYWORDS

height, image, types of images, width
