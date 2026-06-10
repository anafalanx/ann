# list

*Tcl Built-In Commands*

## NAME

list - Create a list

## SYNOPSIS

**list** ?*arg arg ...*?

## DESCRIPTION

This command returns a list comprised of all the *arg*s, or an empty string if no *arg*s are specified. Braces and backslashes get added as necessary, so that the **lindex** command may be used on the result to re-extract the original arguments, and also so that **eval** may be used to execute the resulting list, with *arg1* comprising the command's name and the other *arg*s comprising its arguments.  **List** produces slightly different results than **concat**:  **concat** removes one level of grouping before forming the list, while **list** works directly from the original arguments.

## EXAMPLE

The command

```tcl
list a b "c d e  " "  f {g h}"
```

will return

```tcl
a b {c d e  } {  f {g h}}
```

while **concat** with the same arguments will return

```tcl
a b c d e f {g h}
```

## SEE ALSO

lappend(n), lassign(n), ledit(n), lindex(n), linsert(n), llength(n), lmap(n), lpop(n), lrange(n), lremove(n), lrepeat(n), lreplace(n), lreverse(n), lsearch(n), lseq(n), lset(n), lsort(n)

## KEYWORDS

element, list, quoting
