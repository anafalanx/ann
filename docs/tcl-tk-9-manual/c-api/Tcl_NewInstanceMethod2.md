# Tcl_Method

*TclOO Library Functions*

## NAME

Tcl_ClassSetConstructor, Tcl_ClassSetDestructor, Tcl_MethodDeclarerClass, Tcl_MethodDeclarerObject, Tcl_MethodIsPublic, Tcl_MethodIsPrivate, Tcl_MethodIsType, Tcl_MethodIsType2, Tcl_MethodName, Tcl_NewInstanceMethod, Tcl_NewInstanceMethod2, Tcl_NewMethod, Tcl_NewMethod2, Tcl_ObjectContextInvokeNext, Tcl_ObjectContextIsFiltering, Tcl_ObjectContextMethod, Tcl_ObjectContextObject, Tcl_ObjectContextSkippedArgs - manipulate methods and method-call contexts

## SYNOPSIS

```
#include <tclOO.h>

Tcl_Method
Tcl_NewMethod(interp, class, nameObj, flags, methodTypePtr,
              clientData)

Tcl_Method
Tcl_NewMethod2(interp, class, nameObj, flags, methodType2Ptr,
              clientData)

Tcl_Method
Tcl_NewInstanceMethod(interp, object, nameObj, flags, methodTypePtr,
                      clientData)

Tcl_Method
Tcl_NewInstanceMethod2(interp, object, nameObj, flags, methodType2Ptr,
                      clientData)

Tcl_ClassSetConstructor(interp, class, method)

Tcl_ClassSetDestructor(interp, class, method)

Tcl_Class
Tcl_MethodDeclarerClass(method)

Tcl_Object
Tcl_MethodDeclarerObject(method)

Tcl_Obj *
Tcl_MethodName(method)

int
Tcl_MethodIsPublic(method)

int
Tcl_MethodIsPrivate(method)

int
Tcl_MethodIsType(method, methodTypePtr, clientDataPtr)

int
Tcl_MethodIsType2(method, methodType2Ptr, clientDataPtr)

int
Tcl_ObjectContextInvokeNext(interp, context, objc, objv, skip)

int
Tcl_ObjectContextIsFiltering(context)

Tcl_Method
Tcl_ObjectContextMethod(context)

Tcl_Object
Tcl_ObjectContextObject(context)

Tcl_Size
Tcl_ObjectContextSkippedArgs(context)
```

## ARGUMENTS

- **`Tcl_Interp *interp`** *(in/out)*
The interpreter holding the object or class to create or update a method in.

- **`Tcl_Object object`** *(in)*
The object to create the method in.

- **`Tcl_Class class`** *(in)*
The class to create the method in.

- **`Tcl_Obj *nameObj`** *(in)*
The name of the method to create. Should not be NULL unless creating constructors or destructors.

- **`int flags`** *(in)*
A flag saying (currently) what the visibility of the method is. The supported public values of this flag are **TCL_OO_METHOD_PUBLIC** (which is fixed at 1 for backward compatibility) for an exported method, **TCL_OO_METHOD_UNEXPORTED** (which is fixed at 0 for backward compatibility) for a non-exported method, and **TCL_OO_METHOD_PRIVATE** for a private method.

- **`Tcl_MethodType *methodTypePtr`** *(in)*
A description of the type of the method to create, or the type of method to compare against.

- **`Tcl_MethodType2 *methodType2Ptr`** *(in)*
A description of the type of the method to create, or the type of method to compare against.

- **`void *clientData`** *(in)*
A piece of data that is passed to the implementation of the method without interpretation.

- **`void **clientDataPtr`** *(out)*
A pointer to a variable in which to write the *clientData* value supplied when the method was created. If NULL, the *clientData* value will not be retrieved.

- **`Tcl_Method method`** *(in)*
A reference to a method to query.

- **`Tcl_ObjectContext context`** *(in)*
A reference to a method-call context. Note that client code *must not* retain a reference to a context.

- **`Tcl_Size objc`** *(in)*
The number of arguments to pass to the method implementation.

- **`Tcl_Obj *const *objv`** *(in)*
An array of arguments to pass to the method implementation.

- **`Tcl_Size skip`** *(in)*
The number of arguments passed to the method implementation that do not represent "real" arguments.

## DESCRIPTION

A method is an operation carried out on an object that is associated with the object. Every method must be attached to either an object or a class; methods attached to a class are associated with all instances (direct and indirect) of that class.

Given a method, the entity that declared it can be found using **Tcl_MethodDeclarerClass** which returns the class that the method is attached to (or NULL if the method is not attached to any class) and **Tcl_MethodDeclarerObject** which returns the object that the method is attached to (or NULL if the method is not attached to an object). The name of the method can be retrieved with **Tcl_MethodName**, whether the method is exported is retrieved with **Tcl_MethodIsPublic**, and whether the method is private is retrieved with **Tcl_MethodIsPrivate**. The type of the method can also be introspected upon to a limited degree; the function **Tcl_MethodIsType** returns whether a method is of a particular type, assigning the per-method *clientData* to the variable pointed to by *clientDataPtr* if (that is non-NULL) if the type is matched. **Tcl_MethodIsType2** does the same for TCL_OO_METHOD_VERSION_2.

### METHOD CREATION

Methods are created by **Tcl_NewMethod** and **Tcl_NewInstanceMethod**, or by **Tcl_NewMethod2** and **Tcl_NewInstanceMethod2** which create a method attached to a class or an object respectively. In both cases, the *nameObj* argument gives the name of the method to create, the *flags* argument states whether the method should be exported initially or be marked as a private method, the *methodTypePtr* or *methodType2Ptr* (for TCL_OO_METHOD_VERSION_2) argument describes the implementation of the method (see the **METHOD TYPES** section below) and the *clientData* argument gives some implementation-specific data that is passed on to the implementation of the method when it is called.

When the *nameObj* argument to **Tcl_NewMethod** or **Tcl_NewMethod2** is NULL, an unnamed method is created, which is used for constructors and destructors. Constructors should be installed into their class using the **Tcl_ClassSetConstructor** function, and destructors (which must not require any arguments) should be installed into their class using the **Tcl_ClassSetDestructor** function. Unnamed methods should not be used for any other purpose, and named methods should not be used as either constructors or destructors. Also note that a NULL *methodTypePtr* or *methodType2Ptr* is used to provide internal signaling, and should not be used in client code.

### METHOD CALL CONTEXTS

When a method is called, a method-call context reference is passed in as one of the arguments to the implementation function. This context can be inspected to provide information about the caller, but should not be retained beyond the moment when the method call terminates.

The method that is being called can be retrieved from the context by using **Tcl_ObjectContextMethod**, and the object that caused the method to be invoked can be retrieved with **Tcl_ObjectContextObject**. The number of arguments that are to be skipped (e.g. the object name and method name in a normal method call) is read with **Tcl_ObjectContextSkippedArgs**, and the context can also report whether it is working as a filter for another method through **Tcl_ObjectContextIsFiltering**.

During the execution of a method, the method implementation may choose to invoke the stages of the method call chain that come after the current method implementation. This (the core of the **next** command) is done using **Tcl_ObjectContextInvokeNext**. Note that this function does not manipulate the call-frame stack, unlike the **next** command; if the method implementation has pushed one or more extra frames on the stack as part of its implementation, it is also responsible for temporarily popping those frames from the stack while the **Tcl_ObjectContextInvokeNext** function is executing. Note also that the method-call context is *never* deleted during the execution of this function.

## METHOD TYPES

The types of methods are described by a pointer to a Tcl_MethodType or Tcl_MethodType2 (for TCL_OO_METHOD_VERSION_2) structure, which are defined as:

```tcl
typedef struct {
    int version;
    const char *name;
    Tcl_MethodCallProc *callProc;
    Tcl_MethodDeleteProc *deleteProc;
    Tcl_CloneProc *cloneProc;
} Tcl_MethodType;

typedef struct {
    int version;
    const char *name;
    Tcl_MethodCallProc2 *callProc;
    Tcl_MethodDeleteProc *deleteProc;
    Tcl_CloneProc *cloneProc;
} Tcl_MethodType2;
```

The *version* field should always be declared equal to TCL_OO_METHOD_VERSION_CURRENT, TCL_OO_METHOD_VERSION_1 or TCL_OO_METHOD_VERSION_2. The *name* field provides a human-readable name for the type, and is the value that is exposed via the **info class methodtype** and **info object methodtype** Tcl commands.

The *callProc* field gives a function that is called when the method is invoked; it must never be NULL.

The *deleteProc* field gives a function that is used to delete a particular method, and is called when the method is replaced or removed; if the field is NULL, it is assumed that the method's *clientData* needs no special action to delete.

The *cloneProc* field is either a function that is used to copy a method's *clientData* (as part of **Tcl_CopyObjectInstance**) or NULL to indicate that the *clientData* can just be copied directly.

### TCL_METHODCALLPROC FUNCTION SIGNATURE

Functions matching this signature are called when the method is invoked.

```tcl
typedef int Tcl_MethodCallProc(
        void *clientData,
        Tcl_Interp *interp,
        Tcl_ObjectContext objectContext,
        int objc,
        Tcl_Obj *const *objv);

typedef int Tcl_MethodCallProc2(
        void *clientData,
        Tcl_Interp *interp,
        Tcl_ObjectContext objectContext,
        Tcl_Size objc,
        Tcl_Obj *const *objv);
```

The *clientData* argument to a Tcl_MethodCallProc is the value that was given when the method was created, the *interp* is a place in which to execute scripts and access variables as well as being where to put the result of the method, and the *objc* and *objv* fields give the parameter objects to the method. The calling context of the method can be discovered through the *objectContext* argument, and the return value from a Tcl_MethodCallProc is any Tcl return code (e.g. TCL_OK, TCL_ERROR).

### TCL_METHODDELETEPROC FUNCTION SIGNATURE

Functions matching this signature are used when a method is deleted, whether through a new method being created or because the object or class is deleted.

```tcl
typedef void Tcl_MethodDeleteProc(
        void *clientData);
```

The *clientData* argument to a Tcl_MethodDeleteProc will be the same as the value passed to the *clientData* argument to **Tcl_NewMethod** or **Tcl_NewInstanceMethod** when the method was created.

### TCL_CLONEPROC FUNCTION SIGNATURE

Functions matching this signature are used to copy a method when the object or class is copied using **Tcl_CopyObjectInstance** (or **oo::copy**).

```tcl
typedef int Tcl_CloneProc(
        Tcl_Interp *interp,
        void *oldClientData,
        void **newClientDataPtr);
```

The *interp* argument gives a place to write an error message when the attempt to clone the object is to fail, in which case the clone procedure must also return TCL_ERROR; it should return TCL_OK otherwise. The *oldClientData* field to a Tcl_CloneProc gives the value from the method being copied from, and the *newClientDataPtr* field will point to a variable in which to write the value for the method being copied to.

## REFERENCE COUNT MANAGEMENT

The *nameObj* argument to **Tcl_NewMethod** and **Tcl_NewInstanceMethod** (when non-NULL) will have its reference count incremented if there is no existing method with that name in that class/object.

The result of **Tcl_MethodName** is a value with a reference count of at least one. It should not be modified without first duplicating it (with **Tcl_DuplicateObj**).

The values in the first *objc* values of the *objv* argument to **Tcl_ObjectContextInvokeNext** are assumed to have a reference count of at least 1; the containing array is assumed to endure until the next method implementation (see **next**) returns. Be aware that methods may **yield**; if any post-call actions are desired (e.g., decrementing the reference count of values passed in here), they must be scheduled with **Tcl_NRAddCallback**.

The *callProc* of the **Tcl_MethodType** structure takes values of at least reference count 1 in its *objv* argument. It may add its own references, but must not decrement the reference count below that level; the caller of the method will decrement the reference count once the method returns properly (and the reference will be held if the method **yield**s).

## SEE ALSO

Class(3), NRE(3), oo::class(n), oo::define(n), oo::object(n)

## KEYWORDS

constructor, method, object
