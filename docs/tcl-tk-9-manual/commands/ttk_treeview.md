# ttk::treeview

*Tk Themed Widget*

## NAME

ttk::treeview - hierarchical multicolumn data display widget

## SYNOPSIS

**ttk::treeview** *pathname* ?*options*?

## DESCRIPTION

The **ttk::treeview** widget displays a hierarchical collection of items. Each item has a textual label, an optional image, and an optional list of data values. The data values are displayed in successive columns after the tree label.

The order in which data values are displayed may be controlled by setting the **-displaycolumns** widget option. The tree widget can also display column headings. Columns may be accessed by number or by symbolic names listed in the **-columns** widget option; see **COLUMN IDENTIFIERS**.

Each item is identified by a unique name. The widget will generate item IDs if they are not supplied by the caller. There is a distinguished root item, named **{}**. The root item itself is not displayed; its children appear at the top level of the hierarchy.

Each item also has a list of *tags*, which can be used to associate event bindings with individual items and control the appearance of the item.

Treeview widgets support horizontal and vertical scrolling with the standard **-**[**xy**]**scrollcommand** options and [**xy**]**view** widget commands.

**Standard options** — see the referenced options manual:

- `-class`
- `-cursor`
- `-takefocus`
- `-style`
- `-xscrollcommand`
- `-yscrollcommand`
- `-padding`

## WIDGET-SPECIFIC OPTIONS

- **`-columns`** — database name `columns`, class `Columns`

A list of column identifiers, specifying the number of columns and their names.

- **`-displaycolumns`** — database name `displayColumns`, class `DisplayColumns`

A list of column identifiers (either symbolic names or integer indices) specifying which data columns are displayed and the order in which they appear, or the string **#all**. If set to **#all** (the default), all columns are shown in the order given.

- **`-height`** — database name `height`, class `Height`

Specifies the number of rows which should be visible. Note that the requested width is determined from the sum of the column widths.

- **`-selectmode`** — database name `selectMode`, class `SelectMode`

Controls how the built-in class bindings manage the selection. One of **extended**, **browse**, or **none**.

  If set to **extended** (the default), multiple items may be selected. If **browse**, only a single item will be selected at a time. If **none**, the selection will not be changed.

  Note that application code and tag bindings can set the selection however they wish, regardless of the value of **-selectmode**.

- **`-selecttype`** — database name `selectType`, class `SelectType`

Controls how the built-in class bindings manage the selection. One of **item** or **cell**.

- **`-show`** — database name `show`, class `Show`

A list containing zero or more of the following values, specifying which elements of the tree to display.

  Display tree labels in column #0.

  Display the heading row.

  The default is **tree headings**.

  **NOTE:** Column #0 always refers to the tree column, even if **-show tree** is not specified.

- **`-striped`** — database name `striped`, class `Striped`

Boolean specifying zebra striped item coloring. Note that striped items uses the **-stripedbackground** option if set by the theme or a tag. If not supported by the current theme, it will not show.

- **`-titlecolumns`** — database name `titleColumns`, class `TitleColumns`

Number of display columns at the left that should not be scrolled. The tree column counts, even if **-show tree** is not specified. Thus for value N of this option, column #N is the first one that is scrollable. Default is 0.

- **`-titleitems`** — database name `titleItems`, class `TitleItems`

Number of items at the top that should not be vertically scrolled. Default is 0.

## WIDGET COMMAND

In addition to the standard **cget**, **configure**, **instate**, **state**, **style**, **xview** and **yview** commands (see **ttk::widget**), treeview widgets support the following additional commands:

*pathname* **bbox** *item* ?*column*?

Returns the bounding box (relative to the treeview widget's window) of the specified *item* in the form *x y width height*. If the *item* is not visible (i.e., if it is a descendant of a closed item or is vertically scrolled offscreen), returns the empty list. If *column* is specified and is not hidden (by the **-displaycolumns** option), returns the bounding box of that cell within *item* (even if the cell is horizontally scrolled offscreen).

*pathname* **cellselection** ?*selop arg ...*?

Manages cell selection. Cell selection is independent from item selection handled by the **selection** command. A cell is given by a list of two elements, item and column. For the rectangle versions of commands, the cells must be in displayed columns. Any change to **-columns** clears the cell selection. A *cellList* argument may be a single cell or a list of cells. If *selop* is not specified, returns the list of selected cells. Otherwise, *selop* is one of the following:

  *pathname* **cellselection set** *cellList*

  *cellList* becomes the new cell selection.

  *pathname* **cellselection set** *firstCell lastCell*

  The rectangle defined becomes the new cell selection.

  *pathname* **cellselection add** *cellList*

  Add *cellList* to the cell selection.

  *pathname* **cellselection add** *firstCell lastCell*

  The rectangle defined is added to the cell selection.

  *pathname* **cellselection remove** *cellList*

  Remove *cellList* from the cell selection.

  *pathname* **cellselection remove** *firstCell lastCell*

  The rectangle defined is removed from the cell selection.

  *pathname* **cellselection toggle** *cellList*

  Toggle the cell selection state of each cell in *cellList*. If the element is partially visible, the result gives the full area of the element, including any parts that are not visible.

  *pathname* **cellselection toggle** *firstCell lastCell*

  Toggle the cell selection state of each cell in the rectangle defined.

*pathname* **children** *item* ?*newchildren*?

If *newchildren* is not specified, returns the list of children belonging to *item*.

  If *newchildren* is specified, replaces *item*'s child list with *newchildren*. Items in the old child list not present in the new child list are detached from the tree. None of the items in *newchildren* may be an ancestor of *item*.

*pathname* **column** *column* ?*-option* ?*value -option value...*?

Query or modify the options for the specified *column*. If no *-option* is specified, returns a dictionary of option/value pairs. If a single *-option* is specified, returns the value of that option. Otherwise, the options are updated with the specified values. The following options may be set on each column:

  **-id** *name*

  The column name.  This is a read-only option. For example, [*$pathname* **column #***n* **-id**] returns the data column associated with display column *n*. The tree column has **-id #0**.

  **-anchor** *anchor*

  Specifies how the text in this column should be aligned with respect to the cell. *Anchor* is one of **n**, **ne**, **e**, **se**, **s**, **sw**, **w**, **nw**, or **center**.

  **-minwidth** *minwidth*

  The minimum width of the column in pixels. The treeview widget will not make the column any smaller than **-minwidth** when the widget is resized or the user drags a heading column separator.  Default is 20 pixels.

  **-separator** *boolean*

  Specifies whether or not a column separator should be drawn to the right of the column.  Default is false.

  **-stretch** *boolean*

  Specifies whether or not the column width should be adjusted when the widget is resized or the user drags a heading column separator. *Boolean* may have any of the forms accepted by **Tcl_GetBoolean**. By default columns are stretchable.

  **-width** *width*

  The width of the column in pixels.  Default is 200 pixels. The specified column width may be changed by Tk in order to honor **-stretch** and/or **-minwidth**, or when the widget is resized or the user drags a heading column separator.

  Use *pathname fBcolumn #0* to configure the tree column.

*pathname* **delete** *itemList*

Deletes each of the items in *itemList* and all of their descendants. The root item may not be deleted. See also: **detach**.

*pathname* **detach** *itemList*

Unlinks all of the specified items in *itemList* from the tree. The items and all of their descendants are still present and may be reinserted at another point in the tree with the **move** operation, but will not be displayed until that is done. The root item may not be detached. See also: **delete**.

*pathname* **detached** ?*item*?

If *item* is provided, returns a boolean value indicating whether it is the name of a detached item (see **detach**). Otherwise, returns a list of all the detached items (in an arbitrary order). The root item is never detached.

*pathname* **exists** *item*

Returns 1 if the specified *item* is present in the tree, 0 otherwise.

*pathname* **focus** ?*item*?

If *item* is specified, sets the focus item to *item*. Otherwise, returns the current focus item, or **{}** if there is none.

*pathname* **heading** *column* ?*-option* ?*value -option value...*?

Query or modify the heading options for the specified *column*. Valid options are:

  **-text** *text*

  The text to display in the column heading.

  **-image** *imageName*

  Specifies an image to display to the right of the column heading.

  **-anchor** *anchor*

  Specifies how the heading text should be aligned. One of the standard Tk anchor values.

  **-command** *script*

  A script to evaluate when the heading label is pressed.

  Use *pathname heading #0* to configure the tree column heading.

*pathname* **identify** *component x y*

Returns a description of the specified *component* under the point given by *x* and *y*, or the empty string if no such *component* is present at that position. The values *x* and *y* may have any of the forms acceptable to **Tk_GetPixels**. The following subcommands are supported:

  *pathname* **identify region** *x y*

    Returns one of:

    Tree heading area; use [**pathname identify column** *x y*] to determine the heading number.

    - Space between two column headings; [**pathname identify column** *x y*] will return the display column identifier of the heading to left of the separator.

    The tree area.

    A data cell.

  *pathname* **identify item** *x y*

  Returns the item ID of the item at position *y*.

  *pathname* **identify column** *x y*

  Returns the display column identifier of the cell at position *x*. The tree column has ID **#0**.

  *pathname* **identify cell** *x y*

  Returns the cell identifier of the cell at position *x y*. A cell identifier is a list of item ID and column ID.

  *pathname* **identify element** *x y*

  The element at position *x,y*.

  *pathname* **identify row** *x y*

  Obsolescent synonym for *pathname* **identify item**.

  See **COLUMN IDENTIFIERS** for a discussion of display columns and data columns.

*pathname* **index** *item*

Returns the integer index of *item* within its parent's list of children.

*pathname* **insert** *parent index* ?**-id** *id*? *options...*

Creates a new item. *parent* is the item ID of the parent item, or the empty string **{}** to create a new top-level item. *index* is an integer, or the value **end**, specifying where in the list of *parent*'s children to insert the new item. If *index* is negative or zero, the new node is inserted at the beginning; if *index* is greater than or equal to the current number of children, it is inserted at the end. If **-id** is specified, it is used as the item identifier; *id* must not already exist in the tree. Otherwise, a new unique identifier is generated.

  *pathname* **insert** returns the item identifier of the newly created item. See **ITEM OPTIONS** for the list of available options.

*pathname* **item** *item* ?*-option* ?*value -option value...*?

Query or modify the options for the specified *item*. If no *-option* is specified, returns a dictionary of option/value pairs. If a single *-option* is specified, returns the value of that option. Otherwise, the item's options are updated with the specified values. See **ITEM OPTIONS** for the list of available options.

*pathname* **move** *item parent index*

Moves *item* to position *index* in *parent*'s list of children. It is illegal to move an item under one of its descendants.

  If *index* is negative or zero, *item* is moved to the beginning; if greater than or equal to the number of children, it is moved to the end.

*pathname* **next** *item*

Returns the identifier of *item*'s next sibling, or **{}** if *item* is the last child of its parent.

*pathname* **parent** *item*

Returns the ID of the parent of *item*, or **{}** if *item* is at the top level of the hierarchy.

*pathname* **prev** *item*

Returns the identifier of *item*'s previous sibling, or **{}** if *item* is the first child of its parent.

*pathname* **see** *item*

Ensure that *item* is visible: sets all of *item*'s ancestors to **-open true**, and scrolls the widget if necessary so that *item* is within the visible portion of the tree.

*pathname* **selection** ?*selop itemList*?

Manages item selection. Item selection is independent from cell selection handled by the **cellselection** command. If *selop* is not specified, returns the list of selected items. Otherwise, *selop* is one of the following:

  *pathname* **selection set** *itemList*

  *itemList* becomes the new selection.

  *pathname* **selection add** *itemList*

  Add *itemList* to the selection.

  *pathname* **selection remove** *itemList*

  Remove *itemList* from the selection.

  *pathname* **selection toggle** *itemList*

  Toggle the selection state of each item in *itemList*.

*pathname* **set** *item* ?*column*? ?*value*?

With one argument, returns a dictionary of column/value pairs for the specified *item*. With two arguments, returns the current value of the specified *column*. With three arguments, sets the value of column *column* in item *item* to the specified *value*. See also **COLUMN IDENTIFIERS**.

*pathName* **tag** *args...*

Manages tags. Tags can be set on items as well as on cells. The set of tags is shared between items and cells. However item tagging is independent from cell tagging (for instance adding a tag on an item does not also add this tag on the cells in that item). Cell tags take precedence over item tags when drawing. The following subcommands are supported:

  *pathName* **tag add** *tag items*

  Adds the specified *tag* to each of the listed *items*. If *tag* is already present for a particular item, then the **-tags** for that item are unchanged.

  *pathName* **tag bind** *tagName* ?*sequence*? ?*script*?

  Add a Tk binding script for the event sequence *sequence* to the tag *tagName*.  When an X event is delivered to an item, binding scripts for each of the item's **-tags** are evaluated in order as per *bindtags(n)*. If the event can be associated with a cell (i.e. mouse events) any bindings for the cell's **-tags** are evaluated as well.

    **<Key>**, **<KeyRelease>**, and virtual events are sent to the focus item. **<Button>**, **<ButtonRelease>**, and **<Motion>** events are sent to the item under the mouse pointer. No other event types are supported.

    The binding *script* undergoes **%**-substitutions before evaluation; see **bind**(n) for details.

  *pathName* **tag cell** *subcommand...*

  Manages tags on individual cells. A *cellList* argument may be a single cell or a list of cells.

    *pathName* **tag cell add** *tag cellList*

    Adds the specified *tag* to each of the listed *cellList*. If *tag* is already present for a particular cell, then the tag list for that cell is unchanged.

    *pathName* **tag cell has** *tagName* ?*cell*?

    If *cell* is specified, returns 1 or 0 depending on whether the specified cell has the named tag. Otherwise, returns a list of all cells which have the specified tag.

    *pathName* **tag cell remove** *tag* ?*cellList*?

    Removes the specified *tag* from each of the listed *cellList*. If *cellList* is omitted, removes *tag* from each cell in the tree.

  *pathName* **tag configure** *tagName* ?*option*? ?*value option value...*?

  Query or modify the options for the specified *tagName*. If one or more *option/value* pairs are specified, sets the value of those options for the specified tag. If a single *option* is specified, returns the value of that option (or the empty string if the option has not been specified for *tagName*). With no additional arguments, returns a dictionary of the option settings for *tagName*. See **TAG OPTIONS** for the list of available options.

  *pathName* **tag delete** *tagName*

  Deletes all tag information for the *tagName* argument. The command removes the tag from all items and cells in the widget and also deletes any other information associated with the tag, such as bindings and display information. The command returns an empty string.

  *pathName* **tag has** *tagName* ?*item*?

  If *item* is specified, returns 1 or 0 depending on whether the specified item has the named tag. Otherwise, returns a list of all items which have the specified tag.

  *pathName* **tag names**

  Returns a list of all tags used by the widget.

  *pathName* **tag remove** *tag* ?*items*?

  Removes the specified *tag* from each of the listed *items*. If *items* is omitted, removes *tag* from each item in the tree. If *tag* is not present for a particular item, then the **-tags** for that item are unchanged.

## ITEM OPTIONS

The following item options may be specified for items in the **insert** and **item** widget commands.

The textual label to display for the item in the tree column.

The height for the item, in integer multiples of **-rowheight**. Default is 1.

A Tk image, displayed next to the label in the tree column, placed according to **-imageanchor**.

- Specifies how the **-image** is displayed relative to the text. Default is **w**. One of the standard Tk anchor values.

The list of values associated with the item.

  Each item should have the same number of values as the **-columns** widget option. If there are fewer values than columns, the remaining values are assumed empty. If there are more values than columns, the extra values are ignored.

A boolean value indicating whether this item should be displayed (**-hidden false**) or hidden (**-hidden true**). If a parent is hidden, all its decendants are hidden too.

- A boolean value indicating whether the item's children should be displayed (**-open true**) or hidden (**-open false**).

A list of tags associated with this item.

## TAG OPTIONS

The following options may be specified on tags:

- Specifies the text foreground color.

- Specifies the cell or item background color.

- Specifies the font to use when drawing text.

Specifies the cell or item image.

- Specifies the cell or item image anchor.

Specifies the cell padding. A data cell will have a default padding of {4 0}

- Specifies the cell or item background color for alternate lines, if **-striped** is true.

Tags on cells have precedence over tags on items. Then, tag priority is decided by the creation order: tags created first receive higher priority. An item's options, like **-image** and **-imageanchor**, have priority over tags.

## IMAGES

The -image option on an item, and on an item tag, controls the image next to the label in the tree column. Other cells can have images through the cell tag -image option.

## COLUMN IDENTIFIERS

Column identifiers take any of the following forms:

- A symbolic name from the list of **-columns**.

- An integer *n*, specifying the *n*th data column.

- A string of the form **#***n*, where *n* is an integer, specifying the *n*th display column.

Column identifiers support the same simple interpretation as for the command **string index**, with simple integer index arithmetic and indexing relative to **end**.

**NOTE:** Item **-values** may be displayed in a different order than the order in which they are stored.

**NOTE:** Column #0 always refers to the tree column, even if **-show tree** is not specified.

A *data column number* is an index into an item's **-values** list; a *display column number* is the column number in the tree where the values are displayed. Tree labels are displayed in column #0. If **-displaycolumns** is not set, then data column *n* is displayed in display column **#***n+1*. Again, **column #0 always refers to the tree column**.

## VIRTUAL EVENTS

The treeview widget generates the following virtual events.

Generated whenever the selection or cellselection changes. It might also be generated when selection is affected but not actually changed. Further, multiple selection changes could happen before events can be processed leading to multiple events with the same visible selection.

Generated just before setting the focus item to **-open true**.

- Generated just after setting the focus item to **-open false**.

The **focus** and **selection** widget commands can be used to determine the affected item or items.

## STYLING OPTIONS

The class name for a **ttk::treeview** is **Treeview**. The treeview header class name is **Heading**. The treeview item class name is **Item**. The treeview cell class name is **Cell**.

Dynamic states: **disabled**, **selected**.

**Treeview** styling options configurable with **ttk::style** are:

**-background** *color*

**-fieldbackground** *color*

**-font** *font*

**-foreground** *color*

**-indent** *amount*

  Specifies how far items are indented from their parents. Defaults to 20 pixels. The value may have any of the forms acceptable to **Tk_GetPixels**.

**-columnseparatorwidth** *amount*

  Specifies the width of column separators. Defaults to 1 pixel. The value may have any of the forms acceptable to **Tk_GetPixels**.

**-rowheight** *amount*

  This is the standard height for an item. Defaults to 20 pixels. The value may have any of the forms acceptable to **Tk_GetPixels**. If **-rowheight** is not set by the style, it is set by measuring an item and a cell layout with the style's settings. This thus picks up the font and any focus ring or padding from the theme's layout. The **-rowheight** may need to be set to make sure that a row is large enough to contain any images.

  Example of how to set **-rowheight**, adapting to a font in a similar way to how the default value is set:

```tcl
ttk::style configure Treeview \
     -rowheight [expr {[font metrics font -linespace] + 2}]
```

**-stripedbackground** *color*

**Heading** styling options configurable with **ttk::style** are:

**-background** *color*

**-font** *font*

**-relief** *relief*

**Item** styling options configurable with **ttk::style** are:

**-foreground** *color*

**-indicatormargins** *padding*

**-indicatorsize** *amount*

**-padding** *padding*

**Cell** styling options configurable with **ttk::style** are:

**-padding** *padding*

Some options are only available for specific themes.

See the **ttk::style** manual page for information on how to configure ttk styles.

## SEE ALSO

ttk::widget(n), listbox(n), image(n), bind(n)
