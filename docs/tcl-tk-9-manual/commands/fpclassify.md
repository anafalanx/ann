# fpclassify

*Tcl Float Classifier*

## NAME

fpclassify - Floating point number classification of Tcl values

## SYNOPSIS

package require **tcl 9.0**

**fpclassify** *value*

## DESCRIPTION

The **fpclassify** command takes a floating point number, *value*, and returns one of the following strings that describe it:

- *value* is a floating point zero.

- *value* is the result of a gradual underflow.

- *value* is an ordinary floating-point number (not zero, subnormal, infinite, nor NaN).

*value* is a floating-point infinity.

*value* is Not-a-Number.

The **fpclassify** command throws an error if value is not a floating-point value and cannot be converted to one.

## EXAMPLE

This shows how to check whether the result of a computation is numerically safe or not. (Note however that it does not guard against numerical errors; just against representational problems.)

```tcl
set value [command-that-computes-a-value]
switch [fpclassify $value] {
    normal - zero {
        puts "Result is $value"
    }
    infinite {
        puts "Result is infinite"
    }
    subnormal {
        puts "Result is $value - WARNING! precision lost"
    }
    nan {
        puts "Computation completely failed"
    }
}
```

## SEE ALSO

expr(n), mathfunc(n)

## KEYWORDS

floating point

## STANDARDS

This command depends on the **fpclassify**() C macro conforming to “ISO C99” (i.e., to ISO/IEC 9899:1999).

## COPYRIGHT

```
Copyright © 2018 Kevin B. Kenny <kennykb@acm.org>. All rights reserved
```
