#!/bin/sh
# Three seconds, which the default two would cut off.
input=$(cat)
sleep 3
printf '%s' "$input" | tr '[:lower:]' '[:upper:]'
