#!/usr/bin/env bash
#
# instrument.sh — deploy the Dynatrace OneAgent site extension onto a Logic App
#                 (Standard, Windows) and verify it took.
#
# Mirrors the manual runbook:
#   I.   Validate the target is Standard + Windows (has Kudu).
#   II.  Set the DT_* app settings.
#   III. (template lives in templates/dynatrace-oneagent-siteextension.json)
#   IV.  az deployment group create -> installs Microsoft.Web/sites/siteextensions.
#   V.   Restart, then verify (ARM provisioningState + Kudu status) and optionally drive load.
#
# Usage:
#   source config.env                      # DT_TENANT / DT_API_TOKEN / ...
#   ./instrument.sh --all                  # every eligible target in out/targets.json
#   ./instrument.sh --name dt-logicapp-test --rg josh-wood-resource-grp
#   ./instrument.sh --all --dry-run        # show what would happen, change nothing
#   ./instrument.sh --name X --rg Y --drive-load   # also ping the app after restart
#
set -uo pipefail   # NOT -e: we handle errors per-step so one bad app doesn't abort the batch

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/out"; mkdir -p "$OUT"
TEMPLATE="$ROOT/templates/dynatrace-oneagent-siteextension.json"
EXT_NAME="Dynatrace"
RESULTS="$OUT/results.jsonl"

[ -f "$ROOT/config.env" ] && { set +u; . "$ROOT/config.env"; set -u; }

# ---- args -------------------------------------------------------------------
MODE="" ; NAME="" ; RG="" ; SUB="${AZ_SUBSCRIPTION:-}" ; DRY=0 ; DRIVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all)        MODE="all" ;;
    --name)       MODE="one"; NAME="${2:-}"; shift ;;
    --rg)         RG="${2:-}"; shift ;;
    --subscription) SUB="${2:-}"; shift ;;
    --dry-run)    DRY=1 ;;
    --drive-load) DRIVE=1 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---- preflight --------------------------------------------------------------
fail(){ echo "ERROR: $*" >&2; exit 1; }
[ -n "$MODE" ] || fail "specify --all or --name <logicapp>"
[ -f "$TEMPLATE" ] || fail "missing template: $TEMPLATE"

if [ "$DRY" -eq 0 ]; then
  : "${DT_TENANT:?set DT_TENANT (source config.env)}"
  : "${DT_API_TOKEN:?set DT_API_TOKEN (source config.env)}"
fi
DT_SSL_MODE="${DT_SSL_MODE:-default}"
DT_MONITORED_CLR="${DT_MONITORED_CLR:-both}"

command -v az >/dev/null || fail "az CLI not found"
az account show >/dev/null 2>&1 || fail "not logged in: run 'az login'"

# ---- build the work list ----------------------------------------------------
# Each item: "name|resourceGroup|subscriptionId"
declare -a TARGETS=()
if [ "$MODE" = "all" ]; then
  [ -f "$OUT/targets.json" ] || fail "no manifest — run ./discover.sh first"
  while IFS= read -r line; do TARGETS+=("$line"); done < <(python3 - "$OUT/targets.json" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
    if r.get("eligible"):
        print("%s|%s|%s" % (r["name"], r["resourceGroup"], r["subscriptionId"]))
PY
)
  [ ${#TARGETS[@]} -gt 0 ] || fail "no eligible targets in manifest"
else
  [ -n "$NAME" ] || fail "--name requires a value"
  if [ -z "$RG" ]; then
    # Resolve RG (and subscription) from the manifest if available.
    if [ -f "$OUT/targets.json" ]; then
      RESOLVED=$(python3 - "$OUT/targets.json" "$NAME" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
    if r["name"]==sys.argv[2]:
        print("%s|%s"%(r["resourceGroup"],r["subscriptionId"])); break
PY
)
      RG="${RESOLVED%%|*}"; [ -z "$SUB" ] && SUB="${RESOLVED##*|}"
    fi
  fi
  [ -n "$RG" ] || fail "could not resolve resource group for '$NAME' — pass --rg"
  TARGETS+=("$NAME|$RG|${SUB}")
fi

echo "==> ${#TARGETS[@]} target(s); dry-run=$DRY drive-load=$DRIVE"
echo

# ---- per-target instrumentation ---------------------------------------------
instrument_one(){
  local name="$1" rg="$2" sub="$3"
  local sub_args=(); [ -n "$sub" ] && sub_args=(--subscription "$sub")
  local status="unknown" detail=""

  echo "────────────────────────────────────────────────────────────"
  echo ">> $name  (rg=$rg sub=${sub:-current})"

  # I. Validate: Logic App Standard + Windows.
  local kind reserved state
  kind=$(az resource show "${sub_args[@]}" -g "$rg" -n "$name" \
          --resource-type Microsoft.Web/sites --query kind -o tsv 2>/dev/null || true)
  if [ -z "$kind" ]; then
    echo "   !! site not found via ARM — skipping"; _record "$name" "$rg" "not_found" ""; return
  fi
  reserved=$(az webapp show "${sub_args[@]}" -g "$rg" -n "$name" --query reserved -o tsv 2>/dev/null || true)
  state=$(az webapp show "${sub_args[@]}" -g "$rg" -n "$name" --query state -o tsv 2>/dev/null || true)
  echo "   kind=$kind os=$([ "$reserved" = "true" ] && echo Linux || echo Windows) state=$state"

  case "$kind" in *workflowapp*) : ;; *) echo "   !! not a Logic App Standard — skipping"; _record "$name" "$rg" "skip_not_standard" "$kind"; return ;; esac
  if [ "$reserved" = "true" ]; then
    echo "   !! Linux Logic App — no Kudu/site extensions. skipping"; _record "$name" "$rg" "skip_linux" ""; return
  fi

  if [ "$DRY" -eq 1 ]; then
    echo "   [dry-run] would set app settings DT_TENANT/DT_API_TOKEN/DT_SSL_MODE/DT_MONITORED_CLR"
    echo "   [dry-run] would deploy site extension '$EXT_NAME' via ARM template"
    echo "   [dry-run] would restart and verify"
    _record "$name" "$rg" "dry_run" ""; return
  fi

  # II. App settings (OneAgent reads these at startup).
  echo "   [1/4] setting DT_* app settings"
  if ! az webapp config appsettings set "${sub_args[@]}" -g "$rg" -n "$name" --settings \
        DT_TENANT="$DT_TENANT" \
        DT_API_TOKEN="$DT_API_TOKEN" \
        DT_SSL_MODE="$DT_SSL_MODE" \
        DT_MONITORED_CLR="$DT_MONITORED_CLR" \
        --output none 2>"$OUT/$name.appsettings.err"; then
    echo "   !! app settings failed: $(tr '\n' ' ' <"$OUT/$name.appsettings.err")"
    _record "$name" "$rg" "appsettings_failed" ""; return
  fi

  # IV. Deploy the site extension via ARM template.
  echo "   [2/4] deploying site extension via ARM template"
  local depname="dynatrace-oneagent-siteextension-$name"
  if ! az deployment group create "${sub_args[@]}" \
        --resource-group "$rg" \
        --name "$depname" \
        --template-file "$TEMPLATE" \
        --parameters logicAppName="$name" \
        --output json >"$OUT/$name.deployment.json" 2>"$OUT/$name.deployment.err"; then
    echo "   !! deployment failed: $(tr '\n' ' ' <"$OUT/$name.deployment.err" | head -c 400)"
    _record "$name" "$rg" "deployment_failed" ""; return
  fi
  local prov
  prov=$(python3 -c "import json;print(json.load(open('$OUT/$name.deployment.json'))['properties']['provisioningState'])" 2>/dev/null || echo "?")
  echo "        deployment provisioningState=$prov"

  # V. Restart so the OneAgent code module injects into the worker.
  echo "   [3/4] restarting app"
  az webapp restart "${sub_args[@]}" -g "$rg" -n "$name" --output none 2>/dev/null || \
    echo "        (restart returned non-zero — continuing)"

  # Verify the extension resource via ARM.
  echo "   [4/4] verifying site extension"
  local sub_id; sub_id=$(az account show "${sub_args[@]}" --query id -o tsv 2>/dev/null)
  local ext_url="/subscriptions/${sub_id}/resourceGroups/${rg}/providers/Microsoft.Web/sites/${name}/siteextensions/${EXT_NAME}?api-version=2023-01-01"
  local ext_json; ext_json=$(az rest --method GET --url "$ext_url" 2>/dev/null || true)
  local ext_state
  ext_state=$(printf '%s' "$ext_json" | grep -oP '"provisioningState"\s*:\s*"\K[^"]+' | head -1 || true)
  [ -z "$ext_state" ] && ext_state="$prov"

  if [ "$ext_state" = "Succeeded" ] || [ "$prov" = "Succeeded" ]; then
    echo "   ✓ $name instrumented (extension state=$ext_state)"
    status="succeeded"; detail="$ext_state"
  else
    echo "   ? $name: extension state=$ext_state (check $OUT/$name.deployment.json)"
    status="verify_uncertain"; detail="$ext_state"
  fi

  # Optional: drive a little load so the agent reports data.
  if [ "$DRIVE" -eq 1 ]; then
    local host; host=$(az webapp show "${sub_args[@]}" -g "$rg" -n "$name" --query defaultHostName -o tsv 2>/dev/null || true)
    if [ -n "$host" ]; then
      echo "   [load] pinging https://$host (10x)"
      for i in $(seq 1 10); do
        curl -s -o /dev/null -w "        hit %{http_code} (%{time_total}s)\n" --max-time 20 "https://$host/" || true
        sleep 1
      done
    fi
  fi

  _record "$name" "$rg" "$status" "$detail"
}

# JSON-line result log for the summary.
: > "$RESULTS"
_record(){ printf '{"name":"%s","rg":"%s","status":"%s","detail":"%s"}\n' "$1" "$2" "$3" "$4" >>"$RESULTS"; }

for t in "${TARGETS[@]}"; do
  IFS='|' read -r n r s <<<"$t"
  instrument_one "$n" "$r" "$s"
done

# ---- summary ----------------------------------------------------------------
echo
echo "════════════════════════════ SUMMARY ════════════════════════════"
python3 - "$RESULTS" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
if not rows: print("(nothing ran)"); sys.exit(0)
w=max(len(r["name"]) for r in rows)
for r in rows: print(f"  {r['name'].ljust(w)}  {r['status']}" + (f"  ({r['detail']})" if r['detail'] else ""))
ok=sum(1 for r in rows if r['status']=='succeeded')
print(f"\n  {ok}/{len(rows)} succeeded")
PY
echo "  results: $RESULTS"
