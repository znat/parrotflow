#!/bin/sh
# Closes stdout and keeps running. EOF on the pipe arrives long before the
# process does, and waiting for exit without a deadline after that hung the
# pipeline on every transcript from then on — greptile found it, this keeps it
# found.
cat > /dev/null
printf 'this must not be used'
exec 1>&-
sleep 30
