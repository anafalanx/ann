# lrange

*Tcl Built-In Commands*

## NAME

lrange - Return one or more adjacent elements from a list

## SYNOPSIS

**lrange** *list first last*

## DESCRIPTION

*List* must be a valid Tcl list.  This command will return a new list consisting of elements *first* through *last*, inclusive. The index values *first* and *last* are interpreted the same as index values for the command **string index**, supporting simple index arithmetic and indices relative to the end of the list. If *first* is less than zero, it is treated as if it were zero. If *last* is greater than or equal to the number of elements in the list, then it is treated as if it were **end**. If *first* is greater than *last* then an empty string is returned.

Note that “**lrange** *list first first*” does not always produce the same result as “**lindex** *list first*” (although it often does for simple fields that are not enclosed in braces); it does, however, produce exactly the same results as “**list [lindex** *list first***]**”

## EXAMPLES

Selecting the first two elements:

```tcl
% lrange {a b c d e} 0 1
a b
```

Selecting the last three elements:

```tcl
% lrange {a b c d e} end-2 end
c d e
```

Selecting everything except the first and last element:

```tcl
% lrange {a b c d e} 1 end-1
b c d
```

Selecting a single element with **lrange** is not the same as doing so with **lindex**:

```tcl
% set var {some {elements to} select}
some {elements to} select
% lindex $var 1
elements to
% lrange $var 1 1
{elements to}
```

## SEE ALSO

list(n), lappend(n), lassign(n), ledit(n), lindex(n), linsert(n), llength(n), lmap(n), lpop(n), lremove(n), lrepeat(n), lreplace(n), lreverse(n), lsearch(n), lseq(n), lset(n), lsort(n), string(n)

## KEYWORDS

element, list, range, sublist
