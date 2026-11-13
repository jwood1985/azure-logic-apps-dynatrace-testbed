#!/usr/bin/env bash
#
# verify.sh — report the Dynatrace site-extension state for a Logic App.
#
# Checks two independent signals (per the azure-appservice-connection skill):
#   1. ARM: the siteextensions/Dynatrace resource provisioningState.
#   2. Kudu: GET {scm}/dynatrace/api/status  (the extension's own health).
#
# Usage:
#   ./verify.sh --name dt-logicapp-test --rg josh-wood-resource-grp [--subscription X]
#   ./verify.sh --all                 # every eligible target in out/targets.json
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/out"
[ -f "$ROOT/config.env" ] && { set +u; . "$ROOT/config.env"; set -u; }

MODE="" NAME="" RG="" SUB="${AZ_SUBSCRIPTION:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE=all ;;
    --name) MODE=one; NAME="${2:-}"; shift ;;
    --rg) RG="${2:-}"; shift ;;
    --subscription) SUB="${2:-}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac; shift
done
[ -n "$MODE" ] || { echo "specify --all or --name <logicapp>" >&2; exit 2; }

check_one(){
  local name="$1" rg="$2" sub="$3"
  local sub_args=(); [ -n "$sub" ] && sub_args=(--subscription "$sub")
  local sub_id; sub_id=$(az account show "${sub_args[@]}" --query id -o tsv 2>/dev/null)

  echo "── $name (rg=$rg)"

  # 1. ARM provisioningState.
  local url="/subscriptions/${sub_id}/resourceGroups/${rg}/providers/Microsoft.Web/sites/${name}/siteextensions/Dynatrace?api-version=2023-01-01"
  local arm; arm=$(az rest --method GET --url "$url" 2>/dev/null || true)
  if [ -z "$arm" ]; then
    echo "   ARM:  extension NOT present"
  else
    local ps; ps=$(printf '%s' "$arm" | grep -oP '"provisioningState"\s*:\s*"\K[^"]+' | head -1)
    local ver; ver=$(printf '%s' "$arm" | grep -oP '"version"\s*:\s*"\K[^"]+' | head -1)
    echo "   ARM:  provisioningState=${ps:-?} version=${ver:-?}"
  fi

  # 2. Kudu status (requires SCM reachable; 403 => network-blocked, not absent).
  local host; host=$(az webapp show "${sub_args[@]}" -g "$rg" -n "$name" --query defaultHostName -o tsv 2>/dev/null)
  local scm="https://${host/.azurewebsites.net/.scm.azurewebsites.net}"
  local tok; tok=$(az account get-access-token "${sub_args[@]}" --resource "https://management.azure.com" --query accessToken -o tsv 2>/dev/null | tr -d '\r')
  local code; code=$(curl -s -o "$OUT/$name.kudu-status.json" -w '%{http_code}' --max-time 25 \
        -H "Authorization: Bearer $tok" "$scm/dynatrace/api/status" 2>/dev/null || echo 000)
  case "$code" in
    200) echo "   Kudu: status 200 -> $(tr '\n' ' ' <"$OUT/$name.kudu-status.json" | head -c 200)" ;;
    403) echo "   Kudu: 403 (SCM network-blocked; rely on ARM state above)" ;;
    404) echo "   Kudu: 404 (extension endpoint not up yet — may still be installing)" ;;
    *)   echo "   Kudu: HTTP $code" ;;
  esac
  # App settings sanity.
  local dt; dt=$(az webapp config appsettings list "${sub_args[@]}" -g "$rg" -n "$name" \
        --query "[?name=='DT_TENANT'].value | [0]" -o tsv 2>/dev/null || true)
  echo "   App:  DT_TENANT=${dt:-<unset>}"
}

if [ "$MODE" = all ]; then
  [ -f "$OUT/targets.json" ] || { echo "run ./discover.sh first" >&2; exit 1; }
  while IFS='|' read -r n r s; do check_one "$n" "$r" "$s"; done < <(python3 - "$OUT/targets.json" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
    if r.get("eligible"): print("%s|%s|%s"%(r["name"],r["resourceGroup"],r["subscriptionId"]))
PY
)
else
  if [ -z "$RG" ] && [ -f "$OUT/targets.json" ]; then
    RESOLVED=$(python3 - "$OUT/targets.json" "$NAME" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
    if r["name"]==sys.argv[2]: print("%s|%s"%(r["resourceGroup"],r["subscriptionId"]));break
PY
)
    RG="${RESOLVED%%|*}"; [ -z "$SUB" ] && SUB="${RESOLVED##*|}"
  fi
  check_one "$NAME" "$RG" "$SUB"
fi
