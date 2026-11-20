#!/usr/bin/env bash
#
# instrument.sh — deploy the Dynatrace OneAgent site extension onto Logic App
#                 Standard (Windows) targets, with persistent state + resume.
#
# Per app: validate (Standard+Windows) → set DT_* app settings → ARM-deploy the
# `Dynatrace` site extension → restart → verify (ARM + Kudu).
#
# STATE / RESUME
#   Progress is appended to out/state.tsv (survives crashes). On re-run, apps
#   already "succeeded" are SKIPPED automatically — so re-running the same command
#   after a failure resumes where it left off (no needless restarts).
#     --force          re-instrument every target, ignoring prior state
#     --retry-failed   only re-attempt targets whose last state was a failure
#   A run lock (flock on out/.instrument.lock) prevents concurrent runs.
#
# SELECTION
#   --all                      every eligible target in out/targets.json
#   --name <app> [--rg <rg>]   one app
#   --subscription <name|id>   subscription for --name (else from manifest/AZ_SUBSCRIPTION)
#   Filters for --all (env): APP_NAME_FILTER (glob), RG_FILTER (comma list)
#
# OTHER
#   --dry-run       validate + print plan, change nothing
#   --drive-load    after instrument, ping the app to generate monitored load
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/out"; mkdir -p "$OUT"
TEMPLATE="$ROOT/templates/dynatrace-oneagent-siteextension.json"
EXT_NAME="Dynatrace"
STATE="$OUT/state.tsv"            # persistent, append-only (last line per app wins)

[ -f "$ROOT/config.env" ] && { set +u; . "$ROOT/config.env"; set -u; }

# ---- args -------------------------------------------------------------------
MODE="" ; NAME="" ; RG="" ; SUB="${AZ_SUBSCRIPTION:-}" ; DRY=0 ; DRIVE=0 ; FORCE=0 ; RETRY_FAILED=0
APP_NAME_FILTER="${APP_NAME_FILTER:-}" ; RG_FILTER="${RG_FILTER:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --all)          MODE="all" ;;
    --name)         MODE="one"; NAME="${2:-}"; shift ;;
    --rg)           RG="${2:-}"; shift ;;
    --subscription) SUB="${2:-}"; shift ;;
    --dry-run)      DRY=1 ;;
    --drive-load)   DRIVE=1 ;;
    --force)        FORCE=1 ;;
    --retry-failed) RETRY_FAILED=1 ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

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

# ---- run lock (prevent concurrent runs) -------------------------------------
LOCK="$OUT/.instrument.lock"
exec 9>"$LOCK" || true
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || fail "another instrument.sh run holds the lock ($LOCK). Wait for it or remove the file if stale."
fi

# ---- persistent state (append-only; last line per app wins) -----------------
touch "$STATE"
state_status(){ awk -F'\t' -v n="$1" '$1==n{s=$4} END{print s}' "$STATE" 2>/dev/null; }
state_set(){ # name rg sub status detail
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$(date -u +%FT%TZ)" >> "$STATE"; }

# ---- build the work list ----------------------------------------------------
declare -a TARGETS=()
if [ "$MODE" = "all" ]; then
  [ -f "$OUT/targets.json" ] || fail "no manifest — run ./discover.sh first"
  while IFS= read -r line; do TARGETS+=("$line"); done < <(python3 - "$OUT/targets.json" "$APP_NAME_FILTER" "$RG_FILTER" <<'PY'
import json,sys,fnmatch
rows=json.load(open(sys.argv[1]))
glob=sys.argv[2].strip(); rgs=[x.strip() for x in sys.argv[3].split(',') if x.strip()]
for r in rows:
    if not r.get("eligible"): continue
    if glob and not fnmatch.fnmatch(r["name"], glob): continue
    if rgs and r["resourceGroup"] not in rgs: continue
    print("%s|%s|%s" % (r["name"], r["resourceGroup"], r["subscriptionId"]))
PY
)
  [ ${#TARGETS[@]} -gt 0 ] || fail "no eligible targets after filters (manifest/APP_NAME_FILTER/RG_FILTER)"
else
  [ -n "$NAME" ] || fail "--name requires a value"
  if [ -z "$RG" ] && [ -f "$OUT/targets.json" ]; then
    RESOLVED=$(python3 - "$OUT/targets.json" "$NAME" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
    if r["name"]==sys.argv[2]: print("%s|%s"%(r["resourceGroup"],r["subscriptionId"]));break
PY
)
    RG="${RESOLVED%%|*}"; [ -z "$SUB" ] && SUB="${RESOLVED##*|}"
  fi
  [ -n "$RG" ] || fail "could not resolve resource group for '$NAME' — pass --rg"
  TARGETS+=("$NAME|$RG|${SUB}")
fi

echo "==> ${#TARGETS[@]} candidate target(s); dry-run=$DRY force=$FORCE retry-failed=$RETRY_FAILED drive-load=$DRIVE"
echo "    state file: $STATE"
echo

# ---- per-target instrumentation ---------------------------------------------
instrument_one(){
  local name="$1" rg="$2" sub="$3"
  local sub_args=(); [ -n "$sub" ] && sub_args=(--subscription "$sub")
  local status="unknown" detail=""

  echo "────────────────────────────────────────────────────────────"
  echo ">> $name  (rg=$rg sub=${sub:-current})"

  local kind reserved state
  kind=$(az resource show "${sub_args[@]}" -g "$rg" -n "$name" \
          --resource-type Microsoft.Web/sites --query kind -o tsv 2>/dev/null || true)
  if [ -z "$kind" ]; then
    echo "   !! site not found via ARM — skipping"; state_set "$name" "$rg" "$sub" "not_found" ""; return; fi
  reserved=$(az webapp show "${sub_args[@]}" -g "$rg" -n "$name" --query reserved -o tsv 2>/dev/null || true)
  state=$(az webapp show "${sub_args[@]}" -g "$rg" -n "$name" --query state -o tsv 2>/dev/null || true)
  echo "   kind=$kind os=$([ "$reserved" = "true" ] && echo Linux || echo Windows) state=$state"

  case "$kind" in *workflowapp*) : ;; *) echo "   !! not a Logic App Standard — skipping"; state_set "$name" "$rg" "$sub" "skip_not_standard" "$kind"; return ;; esac
  if [ "$reserved" = "true" ]; then
    echo "   !! Linux Logic App — no Kudu/site extensions. skipping"; state_set "$name" "$rg" "$sub" "skip_linux" ""; return; fi

  if [ "$DRY" -eq 1 ]; then
    echo "   [dry-run] would set DT_* app settings, ARM-deploy '$EXT_NAME', restart, verify"
    state_set "$name" "$rg" "$sub" "dry_run" ""; return; fi

  echo "   [1/4] setting DT_* app settings"
  if ! az webapp config appsettings set "${sub_args[@]}" -g "$rg" -n "$name" --settings \
        DT_TENANT="$DT_TENANT" DT_API_TOKEN="$DT_API_TOKEN" \
        DT_SSL_MODE="$DT_SSL_MODE" DT_MONITORED_CLR="$DT_MONITORED_CLR" \
        --output none 2>"$OUT/$name.appsettings.err"; then
    echo "   !! app settings failed: $(tr '\n' ' ' <"$OUT/$name.appsettings.err")"
    state_set "$name" "$rg" "$sub" "appsettings_failed" ""; return; fi

  echo "   [2/4] deploying site extension via ARM template"
  if ! az deployment group create "${sub_args[@]}" \
        --resource-group "$rg" --name "dynatrace-oneagent-siteextension-$name" \
        --template-file "$TEMPLATE" --parameters logicAppName="$name" \
        --output json >"$OUT/$name.deployment.json" 2>"$OUT/$name.deployment.err"; then
    echo "   !! deployment failed: $(tr '\n' ' ' <"$OUT/$name.deployment.err" | head -c 400)"
    state_set "$name" "$rg" "$sub" "deployment_failed" ""; return; fi
  local prov
  prov=$(python3 -c "import json;print(json.load(open('$OUT/$name.deployment.json'))['properties']['provisioningState'])" 2>/dev/null || echo "?")
  echo "        deployment provisioningState=$prov"

  echo "   [3/4] restarting app"
  az webapp restart "${sub_args[@]}" -g "$rg" -n "$name" --output none 2>/dev/null || echo "        (restart non-zero — continuing)"

  echo "   [4/4] verifying site extension"
  local sub_id; sub_id=$(az account show "${sub_args[@]}" --query id -o tsv 2>/dev/null)
  local ext_url="/subscriptions/${sub_id}/resourceGroups/${rg}/providers/Microsoft.Web/sites/${name}/siteextensions/${EXT_NAME}?api-version=2023-01-01"
  local ext_json ext_state
  ext_json=$(az rest --method GET --url "$ext_url" 2>/dev/null || true)
  ext_state=$(printf '%s' "$ext_json" | grep -oP '"provisioningState"\s*:\s*"\K[^"]+' | head -1 || true)
  [ -z "$ext_state" ] && ext_state="$prov"

  if [ "$ext_state" = "Succeeded" ] || [ "$prov" = "Succeeded" ]; then
    echo "   ✓ $name instrumented (extension state=$ext_state)"; status="succeeded"; detail="$ext_state"
  else
    echo "   ? $name: extension state=$ext_state (see $OUT/$name.deployment.json)"; status="verify_uncertain"; detail="$ext_state"
  fi

  if [ "$DRIVE" -eq 1 ]; then
    local host; host=$(az webapp show "${sub_args[@]}" -g "$rg" -n "$name" --query defaultHostName -o tsv 2>/dev/null || true)
    if [ -n "$host" ]; then
      echo "   [load] pinging https://$host (10x)"
      for i in $(seq 1 10); do curl -s -o /dev/null -w "        hit %{http_code}\n" --max-time 20 "https://$host/" || true; sleep 1; done
    fi
  fi
  state_set "$name" "$rg" "$sub" "$status" "$detail"
}

# ---- main loop with resume/skip ---------------------------------------------
declare -a RAN=()
for t in "${TARGETS[@]}"; do
  IFS='|' read -r n r s <<<"$t"
  st="$(state_status "$n")"
  if [ "$FORCE" -eq 0 ] && [ "$st" = "succeeded" ]; then
    echo ">> $n — already succeeded (skip; use --force to redo)"; continue
  fi
  if [ "$RETRY_FAILED" -eq 1 ]; then
    case "$st" in
      ""|succeeded|skip_*|dry_run) echo ">> $n — retry-failed: last='${st:-none}', skipping"; continue ;;
    esac
  fi
  instrument_one "$n" "$r" "$s"
  RAN+=("$n")
done

# ---- summary (from persistent state, for this run's candidates) -------------
echo
echo "════════════════════════════ SUMMARY ════════════════════════════"
python3 - "$STATE" "$(printf '%s\n' "${TARGETS[@]}")" <<'PY'
import sys
state={}
for ln in open(sys.argv[1]):
    p=ln.rstrip("\n").split("\t")
    if len(p)>=4: state[p[0]]=(p[3], p[4] if len(p)>4 else "")
cands=[l.split("|")[0] for l in sys.argv[2].splitlines() if l.strip()]
w=max((len(c) for c in cands), default=4)
ok=0
for c in cands:
    stt,det=state.get(c,("(not run)",""))
    if stt=="succeeded": ok+=1
    print(f"  {c.ljust(w)}  {stt}" + (f"  ({det})" if det else ""))
print(f"\n  {ok}/{len(cands)} succeeded (cumulative, from state)")
PY
echo "  state: $STATE   (persists across runs; re-run to resume, --force to redo)"
