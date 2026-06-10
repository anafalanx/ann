# scope

*[incr Tcl]*

## NAME

itcl::scope - capture the namespace context for a variable

## SYNOPSIS

**itcl::scope** *name*

## DESCRIPTION

Creates a scoped value for the specified *name*, which must be a variable name.  If the *name* is an instance variable, then the scope command returns a name which will resolve in any context as an instance variable belonging to *object*. The precise format of this name is an internal detail to Itcl. Use of such a scoped value makes it possible to use instance variables in conjunction with widgets.  For example, if you have an object with a private variable `x`, and you can use `x` in conjunction with the `-textvariable` option of an entry widget.  Before itcl3.0, only common variables could be used in this manner.

If the *name* is not an instance variable, then it must be a common variable or a global variable.  In that case, the scope command returns the fully qualified name of the variable, e.g., `::foo::bar::x`.

If the *name* is not recognized as a variable, the scope command returns an error.

Ordinary variable names refer to variables in the global namespace. A scoped value captures a variable name together with its namespace context in a way that allows it to be referenced properly later. It is needed, for example, to wrap up variable names when a Tk widget is used within a namespace:

```tcl
namespace foo {
    private variable mode 1

    radiobutton .rb1 -text "Mode #1" \
        -variable [scope mode] -value 1
    pack .rb1

    radiobutton .rb2 -text "Mode #2" \
        -variable [scope mode] -value 2
    pack .rb2
}
```

Radiobuttons `.rb1` and `.rb2` interact via the variable "mode" contained in the namespace "foo".  The **scope** command guarantees this by returning the fully qualified variable name `::foo::mode`.

You should never attempt to craft your own scoped variable names, even if you believe you've flawlessly reverse-engineered the encoding. Instead, you should always use the scope command to generate the variable name dynamically.  Then, you can pass that name to a widget or to any other bit of code in your program.

## KEYWORDS

code, namespace, variable
