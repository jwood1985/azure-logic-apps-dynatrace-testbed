#!/usr/bin/env bash
# fine_probe.sh — characterize an app's restart health signature at 2s resolution.
# Usage: fine_probe.sh <app> <label> [dt_tags_value]
#   If dt_tags_value is given, it is set before the restart; else a plain restart.
set -uo pipefail
APP="$1"; LABEL="$2"; VALUE="${3:-}"
RG=josh-wood-resource-grp
HOST="$APP.azurewebsites.net"
h(){ curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$HOST/" 2>/dev/null || echo 000; }

echo "=== [$LABEL] on $APP ${VALUE:+(DT_TAGS=$VALUE)} ==="
if [ -n "$VALUE" ]; then
  az webapp config appsettings set -g "$RG" -n "$APP" --settings "DT_TAGS=$VALUE" --output none 2>/dev/null
  echo "   set + (settings change triggers restart)"
else
  az webapp restart -g "$RG" -n "$APP" --output none 2>/dev/null
  echo "   plain restart issued"
fi
# sample every 2s for 70s
seq=""
for i in $(seq 1 35); do c=$(h); seq="$seq $c"; done
echo "   signature (2s each, ~70s):$seq"
# summarize
echo "$seq" | tr ' ' '\n' | grep -vE '^$' | sort | uniq -c | awk '{printf "   %s x%s\n",$2,$1}'
