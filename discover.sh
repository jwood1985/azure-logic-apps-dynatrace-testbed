#!/usr/bin/env bash
#
# discover.sh — find Logic App (Standard) targets reachable by `az`, with filters.
#
# Emits a JSON manifest (out/targets.json) of every Logic App Standard
# (workflowapp) in scope, with an "eligible" flag (Windows → site extension).
#
# Filters (env vars; blank = no filter):
#   SUBSCRIPTION_FILTER   comma list of subscription name|id (or AZ_SUBSCRIPTION for one)
#   RG_FILTER             comma list of resource groups
#   APP_NAME_FILTER       glob on the app name, e.g. 'prod-*'
#
# Usage:
#   ./discover.sh
#   SUBSCRIPTION_FILTER="Sub A,Sub B" RG_FILTER=rg1,rg2 APP_NAME_FILTER='prod-*' ./discover.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/out"
mkdir -p "$OUT"

[ -f "$ROOT/config.env" ] && { set +u; . "$ROOT/config.env"; set -u; }

SUB_FILTER="${SUBSCRIPTION_FILTER:-${AZ_SUBSCRIPTION:-}}"
RG_FILTER="${RG_FILTER:-}"
APP_NAME_FILTER="${APP_NAME_FILTER:-}"

echo "==> Discovering Logic App (Standard) resources via Azure Resource Graph" >&2
echo "    subscriptions: ${SUB_FILTER:-<all visible>}" >&2
echo "    resourceGroup: ${RG_FILTER:-<all>}" >&2
echo "    name glob:     ${APP_NAME_FILTER:-<all>}" >&2

# Resolve subscription name(s) -> id(s); Graph wants IDs.
GRAPH_ARGS=()
if [ -n "$SUB_FILTER" ]; then
  ids=()
  IFS=',' read -ra _subs <<< "$SUB_FILTER"
  for s in "${_subs[@]}"; do
    s="$(printf '%s' "$s" | sed 's/^ *//;s/ *$//')"
    [ -z "$s" ] && continue
    id=$(az account list --query "[?name=='$s' || id=='$s'].id | [0]" -o tsv 2>/dev/null || true)
    if [ -n "$id" ]; then ids+=("$id"); else echo "!! could not resolve subscription '$s' — skipping it" >&2; fi
  done
  [ ${#ids[@]} -gt 0 ] && GRAPH_ARGS=(--subscriptions "${ids[@]}")
fi

# `az graph` needs the resource-graph extension; install it non-interactively
# so fresh customer machines don't hang on a prompt.
if ! az extension show --name resource-graph >/dev/null 2>&1; then
  echo "==> installing az 'resource-graph' extension (one-time)" >&2
  az extension add --name resource-graph --only-show-errors 2>/dev/null \
    || az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors 2>/dev/null \
    || true
fi

QUERY="Resources
| where type =~ 'Microsoft.Web/sites' and kind contains 'workflowapp'
| extend reserved = tobool(properties.reserved)
| extend eligible = (reserved == false)
| project name, resourceGroup, subscriptionId, kind, location,
          os = iff(reserved == true, 'Linux', 'Windows'),
          state = tostring(properties.state),
          defaultHostName = tostring(properties.defaultHostName),
          eligible
| order by name asc"

az graph query -q "$QUERY" "${GRAPH_ARGS[@]}" --query "data" -o json > "$OUT/targets.raw.json"

# Post-filter by RG list + name glob, write the final manifest.
python3 - "$OUT/targets.raw.json" "$OUT/targets.json" "$RG_FILTER" "$APP_NAME_FILTER" <<'PY'
import json, sys, fnmatch
raw = json.load(open(sys.argv[1]))
rgs = [x.strip() for x in sys.argv[3].split(',') if x.strip()]
glob = sys.argv[4].strip()
def keep(r):
    if rgs and r["resourceGroup"] not in rgs: return False
    if glob and not fnmatch.fnmatch(r["name"], glob): return False
    return True
rows = [r for r in raw if keep(r)]
json.dump(rows, open(sys.argv[2], "w"))
PY
rm -f "$OUT/targets.raw.json"

COUNT=$(python3 -c "import json;print(len(json.load(open('$OUT/targets.json'))))")
ELIGIBLE=$(python3 -c "import json;print(sum(1 for r in json.load(open('$OUT/targets.json')) if r['eligible']))")
echo >&2
echo "==> $COUNT Logic App Standard site(s) after filters; $ELIGIBLE eligible for the site extension." >&2
echo >&2

python3 - "$OUT/targets.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
if not rows:
    print("(none matched)"); sys.exit(0)
hdr = ["NAME","RESOURCE GROUP","OS","STATE","ELIGIBLE"]
keys = ["name","resourceGroup","os","state","eligible"]
w = [max(len(h), *(len(str(r[k])) for r in rows)) for h,k in zip(hdr,keys)]
def line(c): print("  ".join(str(x).ljust(w[i]) for i,x in enumerate(c)))
line(hdr); line(["-"*x for x in w])
for r in rows:
    line([r["name"], r["resourceGroup"], r["os"], r["state"], "yes" if r["eligible"] else "NO"])
PY

echo >&2
echo "==> Manifest written to $OUT/targets.json" >&2
