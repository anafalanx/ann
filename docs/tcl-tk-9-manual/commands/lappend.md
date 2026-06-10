# lappend

*Tcl Built-In Commands*

## NAME

lappend - Append list elements onto a variable

## SYNOPSIS

**lappend** *varName* ?*value value value ...*?

## DESCRIPTION

This command treats the variable given by *varName* as a list and appends each of the *value* arguments to that list as a separate element, with spaces between elements. If *varName* does not exist, it is created as a list with elements given by the *value* arguments. If *varName* indicate an element that does not exist of an array that has a default value set, list that is comprised of the default value with all the *value* arguments appended as elements will be stored in the array element. **Lappend** is similar to **append** except that the *value*s are appended as list elements rather than raw text. This command provides a relatively efficient way to build up large lists.  For example, “**lappend a $b**” is much more efficient than “**set a [concat $a [list $b]]**” when **$a** is long.

## EXAMPLE

Using **lappend** to build up a list of numbers.

```tcl
% set var 1
1
% lappend var 2
1 2
% lappend var 3 4 5
1 2 3 4 5
```

## SEE ALSO

list(n), lassign(n), ledit(n), lindex(n), linsert(n), llength(n), lmap(n), lpop(n), lrange(n), lremove(n), lrepeat(n), lreplace(n), lreverse(n), lsearch(n), lseq(n), lset(n), lsort(n)

## KEYWORDS

append, element, list, variable
