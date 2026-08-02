#!/bin/sh
# In a directory with a space in its name, reached by a relative path that has
# one too — and with an argument after it, which is the case that decides where
# the path ends. Both used to be split by the shell into a program and an
# argument of its own.
case "$1" in
  --upper) tr '[:lower:]' '[:upper:]' ;;
  *)       cat ;;
esac
