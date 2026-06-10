# tdbc::mapSqlState

*Tcl Database Connectivity*

## NAME

tdbc::mapSqlState - Map SQLSTATE to error class

## SYNOPSIS

```
package require tdbc 1.0

tdbc::mapSqlState sqlstate
```

## DESCRIPTION

The **tdbc::mapSqlState** command accepts a string that is expected to be a five-character 'SQL state' as returned from a SQL database when an error occurs. It examines the first two characters of the string, and returns an error class as a human- and machine-readable name (for example, **FEATURE_NOT_SUPPORTED**, **DATA_EXCEPTION** or **INVALID_CURSOR_STATE**).

The TDBC specification requires database drivers to return a description of an error in the error code when an error occurs. The description is a string that has at least four elements: "**TDBC** *errorClass* *sqlstate* *driverName* *details...*". The **tdbc::mapSqlState** command gives a convenient way for a TDBC driver to generate the *errorClass* element given the SQL state returned from a database.

## SEE ALSO

tdbc(n), tdbc::tokenize, tdbc::connection(n), tdbc::statement(n), tdbc::resultset(n)

## KEYWORDS

TDBC, SQL, database, state

## COPYRIGHT

Copyright (c) 2009 by Kevin B. Kenny.
