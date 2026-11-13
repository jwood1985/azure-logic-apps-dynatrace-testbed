#!/usr/bin/env bash
#
# drive_load.sh — generate HTTP load against the Logic App worker processes so
# the OneAgent reports process/service/host data to Dynatrace.
#
# If a PingWorkflow HTTP-trigger callback URL is available it drives that
# (produces real workflow runs); otherwise it hits the runtime root, which is
# still served by the monitored Functions host worker.
#
# Usage:  ./drive_load.sh <app1> [app2 ...]   (default: the 4 testbed apps)
#         REQUESTS=60 ./drive_load.sh dt-la-testbed-01
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB="${AZ_SUBSCRIPTION:-7a91e8b3-ee09-4906-91a2-f357b77a61fd}"
RG="${RG:-josh-wood-resource-grp}"
REQUESTS="${REQUESTS:-60}"
APPS=("$@"); [ ${#APPS[@]} -eq 0 ] && APPS=(dt-la-testbed-01 dt-la-testbed-02 dt-la-testbed-03 dt-la-testbed-04)

get_callback(){  # echo callback URL for PingWorkflow's Request trigger, or empty
  local app="$1"
  local rid="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$app"
  az rest --method POST \
    --url "https://management.azure.com$rid/hostruntime/runtime/webhooks/workflow/api/management/workflows/PingWorkflow/triggers/When_a_HTTP_request_is_received/listCallbackUrl?api-version=2022-03-01" \
    --query value -o tsv 2>/dev/null || true
}

for app in "${APPS[@]}"; do
  echo "── driving load: $app ($REQUESTS requests)"
  cb="$(get_callback "$app")"
  if [ -n "$cb" ] && [[ "$cb" == http* ]]; then
    echo "   using workflow callback URL (real workflow runs)"
    ok=0
    for i in $(seq 1 "$REQUESTS"); do
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -X POST "$cb" \
             -H 'Content-Type: application/json' -d "{\"name\":\"load-$i\"}" || echo 000)
      [ "$code" = "200" ] || [ "$code" = "202" ] && ok=$((ok+1))
      [ $((i % 10)) -eq 0 ] && echo "   $i/$REQUESTS (last=$code)"
    done
    echo "   workflow invocations OK: $ok/$REQUESTS"
  else
    echo "   no workflow callback — hitting runtime root (still worker-monitored)"
    host="$app.azurewebsites.net"
    ok=0
    for i in $(seq 1 "$REQUESTS"); do
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://$host/" || echo 000)
      [ "$code" = "200" ] && ok=$((ok+1))
      [ $((i % 10)) -eq 0 ] && echo "   $i/$REQUESTS (last=$code)"
      sleep 0.3
    done
    echo "   root hits OK: $ok/$REQUESTS"
  fi
done
echo "==> load generation complete"
