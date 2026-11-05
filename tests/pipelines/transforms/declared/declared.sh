#!/bin/sh
# parrotflow: {returns: json}
if [ "$PARROTFLOW_PROTOCOL" = json ]; then
  cat >/dev/null
  printf '{"vars": {"protocol": "json"}}\n'
else
  printf '%s (text)' "$(cat)"
fi
