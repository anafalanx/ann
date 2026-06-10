# Tcl_RecordAndEvalObj

*Tcl Library Procedures*

## NAME

Tcl_RecordAndEvalObj - save command on history list before evaluating

## SYNOPSIS

```
#include <tcl.h>

int
Tcl_RecordAndEvalObj(interp, cmdPtr, flags)
```

## ARGUMENTS

- **`Tcl_Interp *interp`** *(in)*
Tcl interpreter in which to evaluate command.

- **`Tcl_Obj *cmdPtr`** *(in)*
Points to a Tcl value containing a command (or sequence of commands) to execute.

- **`int flags`** *(in)*
An OR'ed combination of flag bits.  **TCL_NO_EVAL** means record the command but do not evaluate it.  **TCL_EVAL_GLOBAL** means evaluate the command at global level instead of the current stack level.

## DESCRIPTION

**Tcl_RecordAndEvalObj** is invoked to record a command as an event on the history list and then execute it using **Tcl_EvalObjEx**. It returns a completion code such as **TCL_OK** just like **Tcl_EvalObjEx**, as well as a result value containing additional information (a result value or error message) that can be retrieved using **Tcl_GetObjResult**. If you do not want the command recorded on the history list then you should invoke **Tcl_EvalObjEx** instead of **Tcl_RecordAndEvalObj**. Normally **Tcl_RecordAndEvalObj** is only called with top-level commands typed by the user, since the purpose of history is to allow the user to re-issue recently invoked commands. If the *flags* argument contains the **TCL_NO_EVAL** bit then the command is recorded without being evaluated.

## REFERENCE COUNT MANAGEMENT

The reference count of the *cmdPtr* argument to **Tcl_RecordAndEvalObj** must be at least 1. This function will modify the interpreter result; do not use an existing result as *cmdPtr* directly without incrementing its reference count.

## SEE ALSO

Tcl_EvalObjEx, Tcl_GetObjResult

## KEYWORDS

command, event, execute, history, interpreter, value, record
