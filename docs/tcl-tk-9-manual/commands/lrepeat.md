# lrepeat

*Tcl Built-In Commands*

## NAME

lrepeat - Build a list by repeating elements

## SYNOPSIS

**lrepeat** *count* ?*element ...*?

## DESCRIPTION

The **lrepeat** command creates a list of size *count * number of* elements by repeating *count* times the sequence of elements *element ...*.  *count* must be a non-negative integer, *element* can be any Tcl value.

Note that **lrepeat 1 element ...** is identical to **list element ...**.

## EXAMPLES

```tcl
lrepeat 3 a
      → a a a
lrepeat 3 [lrepeat 3 0]
      → {0 0 0} {0 0 0} {0 0 0}
lrepeat 3 a b c
      → a b c a b c a b c
lrepeat 3 [lrepeat 2 a] b c
      → {a a} b c {a a} b c {a a} b c
```

## SEE ALSO

list(n), lappend(n), lassign(n), ledit(n), lindex(n), linsert(n), llength(n), lmap(n), lpop(n), lrange(n), lremove(n), lreplace(n), lreverse(n), lsearch(n), lseq(n), lset(n), lsort(n)

## KEYWORDS

element, index, list
