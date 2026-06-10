# tdbc::tokenize

*Tcl Database Connectivity*

## NAME

tdbc::tokenize - TDBC SQL tokenizer

## SYNOPSIS

```
package require tdbc 1.0

tdbc::tokenize string
```

## DESCRIPTION

As a convenience to database drivers, Tcl Database Connectivity (TDBC) provides a command to break SQL code apart into tokens so that bound variables can readily be identified and substituted.

The **tdbc::tokenize** command accepts as its parameter a string that is expected to contain one or more SQL statements. It returns a list of substrings; concatenating these substrings together will yield the original string. Each substring is one of the following:

A bound variable, which begins with one of the characters '**:**', '**@**', or '**$**'. The remainder of the string is the variable name and will consist of alphanumeric characters and underscores. (The leading character will be be non-numeric.)

A semicolon that separates two SQL statements.

Something else in a SQL statement. The tokenizer does not attempt to parse SQL; it merely identifies bound variables (distinguishing them from similar strings appearing inside quotes or comments) and statement delimiters.

## SEE ALSO

tdbc(n), tdbc::connection(n), tdbc::statement(n), tdbc::resultset(n)

## KEYWORDS

TDBC, SQL, database, tokenize

## COPYRIGHT

Copyright (c) 2008 by Kevin B. Kenny.
