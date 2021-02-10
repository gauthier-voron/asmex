Assembly Explorer
=================

Show the correspondance between assembly code and the source code it has been
generated from.


How To Install
--------------

This program depends on the `Curses::UI` package that you can find on CPAN.
This program also use the `objdump` external tool that is part of the
`binutils` distribution.

Both the `Curses` and `Asmex` directories should be placed under a directory
that is part of the `@INC` directory list of your Perl interpreter.


How To Use
----------

Asmex works by extracting the debug information from compiled files. To
generate debug information you typically compile source code like follows
```
gcc -g source.c
```
Similar options are available on main compilers.

To extract and display debug information with Asmex, run
```
asmex a.out
```
By default, Asmex only looks for source files under your home directory. You
can override this behavior by using the `-I` option
```
asmex -I/usr/include/stdio.h -I/opt/custom/include a.out
```
Note that the previous command does not look for files under your home
directory, you have to explicitely add it with `-I~`.
