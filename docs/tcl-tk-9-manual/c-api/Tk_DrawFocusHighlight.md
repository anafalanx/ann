# Tk_DrawFocusHighlight

*Tk Library Procedures*

## NAME

Tk_DrawFocusHighlight - draw the traversal highlight ring for a widget

## SYNOPSIS

```
#include <tk.h>

Tk_DrawFocusHighlight(tkwin, gc, width, drawable)
```

## ARGUMENTS

- **`Tk_Window tkwin`** *(in)*
Window for which the highlight is being drawn.  Used to retrieve the window's dimensions, among other things.

- **`GC gc`** *(in)*
Graphics context to use for drawing the highlight.

- **`int width`** *(in)*
Width of the highlight ring, in pixels.

- **`Drawable drawable`** *(in)*
Drawable in which to draw the highlight;  usually an offscreen pixmap for double buffering.

## DESCRIPTION

**Tk_DrawFocusHighlight** is a utility procedure that draws the traversal highlight ring for a widget. It is typically invoked by widgets during redisplay.

## KEYWORDS

focus, traversal highlight
