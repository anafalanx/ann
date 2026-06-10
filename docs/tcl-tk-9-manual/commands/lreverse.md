# lreverse

*Tcl Built-In Commands*

## NAME

lreverse - Reverse the order of a list

## SYNOPSIS

**lreverse** *list*

## DESCRIPTION

The **lreverse** command returns a list that has the same elements as its input list, *list*, except with the elements in the reverse order.

## EXAMPLES

```tcl
lreverse {a a b c}
      → c b a a
lreverse {a b {c d} e f}
      → f e {c d} b a
```

## SEE ALSO

list(n), lappend(n), lassign(n), ledit(n), lindex(n), linsert(n), llength(n), lmap(n), lpop(n), lrange(n), lremove(n), lrepeat(n), lreplace(n), lsearch(n), lseq(n), lset(n), lsort(n)

## KEYWORDS

element, list, reverse
