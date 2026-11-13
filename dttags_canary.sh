#!/usr/bin/env bash
#
# dttags_canary.sh — safely test adding DT_TAGS to ONE Logic App with automatic
# health monitoring and rollback. Addresses the "DT_TAGS killed the app" failure.
#
# Flow: snapshot -> set DT_TAGS -> restart -> poll health ~3min ->
#       if unhealthy, REMOVE DT_TAGS + restart (auto-rollback) and report.
#
# Usage:  ./dttags_canary.sh <app> "<dt_tags_value>"
#
set -uo pipefail
APP="${1:?app name}"; VALUE="${2:?DT_TAGS value}"
RG="${RG:-josh-wood-resource-grp}"
SUB="${AZ_SUBSCRIPTION:-7a91e8b3-ee09-4906-91a2-f357b77a61fd}"
HOST="$APP.azurewebsites.net"
az account set --subscription "$SUB" 2>/dev/null

health(){ curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://$HOST/" 2>/dev/null || echo 000; }
rollback(){
  echo "!! ROLLBACK: removing DT_TAGS from $APP"
  az webapp config appsettings delete -g "$RG" -n "$APP" --setting-names DT_TAGS --output none 2>/dev/null
  az webapp restart -g "$RG" -n "$APP" --output none 2>/dev/null
  echo "   DT_TAGS removed, restarted. Waiting for recovery..."
  for i in $(seq 1 12); do c=$(health); echo "   recovery check $i: $c"; [ "$c" = "200" ] && { echo "   recovered."; return 0; }; sleep 10; done
  echo "   !! still not healthy after rollback — investigate manually"; return 1
}

echo "=== baseline health of $APP ==="
base=$(health); echo "   baseline: $base"
[ "$base" = "200" ] || echo "   (warning: not 200 before change)"

echo "=== setting DT_TAGS='$VALUE' on $APP ==="
# Pass as a single shell arg so az keeps it as ONE setting (splits on first '=').
az webapp config appsettings set -g "$RG" -n "$APP" --settings "DT_TAGS=$VALUE" --output none 2>&1
echo "=== restarting $APP ==="
az webapp restart -g "$RG" -n "$APP" --output none 2>/dev/null

echo "=== monitoring health for ~3 min (auto-rollback on sustained failure) ==="
fails=0
for i in $(seq 1 18); do
  c=$(health)
  echo "   t=$((i*10))s health=$c"
  if [ "$c" = "200" ]; then fails=0; else fails=$((fails+1)); fi
  if [ "$fails" -ge 4 ]; then
    echo "!! $APP unhealthy ($fails consecutive non-200) — DT_TAGS likely broke it"
    rollback
    echo "RESULT: DT_TAGS='$VALUE' KILLED $APP — rolled back"
    exit 1
  fi
  sleep 10
done
echo "RESULT: DT_TAGS='$VALUE' applied to $APP and it stayed HEALTHY"
