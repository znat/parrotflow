#!/bin/sh
# In a directory with a space in its name, reached by a relative path that has
# one too. Both used to be split by the shell into a program and an argument.
tr '[:lower:]' '[:upper:]'
