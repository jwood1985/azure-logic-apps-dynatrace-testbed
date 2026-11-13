#!/usr/bin/env bash
#
# discover.sh — find Logic App (Standard) targets reachable by `az`.
#
# Emits a JSON manifest (out/targets.json) of every Microsoft.Web/sites
# resource whose kind marks it as a Logic App Standard (workflowapp), with the
# fields the instrumenter needs, plus an "eligible" flag.
#
# Eligibility for the Dynatrace OneAgent *site extension*:
#   - kind contains "workflowapp"  (Logic App Standard, not Consumption)
#   - reserved == false            (Windows -> has Kudu/SCM; Linux has no site extensions)
#
# Usage:
#   ./discover.sh                 # scan all subscriptions the login can see
#   AZ_SUBSCRIPTION=<name|id> ./discover.sh   # restrict to one subscription
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/out"
mkdir -p "$OUT"

# Load config.env if present (for AZ_SUBSCRIPTION); never fatal.
[ -f "$ROOT/config.env" ] && { set +u; . "$ROOT/config.env"; set -u; }

SUB_FILTER="${AZ_SUBSCRIPTION:-}"

echo "==> Discovering Logic App (Standard) resources via Azure Resource Graph" >&2
if [ -n "$SUB_FILTER" ]; then
  echo "    scope: subscription '$SUB_FILTER'" >&2
else
  echo "    scope: all subscriptions visible to this login" >&2
fi

# Resolve subscription name -> id if a filter was given (Graph wants IDs).
GRAPH_ARGS=()
if [ -n "$SUB_FILTER" ]; then
  SUB_ID=$(az account list --query "[?name=='$SUB_FILTER' || id=='$SUB_FILTER'].id | [0]" -o tsv 2>/dev/null || true)
  if [ -z "$SUB_ID" ]; then
    echo "!! Could not resolve subscription '$SUB_FILTER' — falling back to all." >&2
  else
    GRAPH_ARGS=(--subscriptions "$SUB_ID")
  fi
fi

QUERY="Resources
| where type =~ 'Microsoft.Web/sites' and kind contains 'workflowapp'
| extend reserved = tobool(properties.reserved)
| extend eligible = (reserved == false)
| project name,
          resourceGroup,
          subscriptionId,
          kind,
          location,
          os = iff(reserved == true, 'Linux', 'Windows'),
          state = tostring(properties.state),
          defaultHostName = tostring(properties.defaultHostName),
          eligible
| order by name asc"

# Resource Graph pages at 1000 rows; these test beds are tiny so one page is fine.
az graph query -q "$QUERY" "${GRAPH_ARGS[@]}" --query "data" -o json > "$OUT/targets.json"

COUNT=$(python3 -c "import json;print(len(json.load(open('$OUT/targets.json'))))")
ELIGIBLE=$(python3 -c "import json;print(sum(1 for r in json.load(open('$OUT/targets.json')) if r['eligible']))")

echo >&2
echo "==> Found $COUNT Logic App Standard site(s); $ELIGIBLE eligible for the site extension." >&2
echo >&2

# Human-readable table to stdout.
python3 - "$OUT/targets.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
if not rows:
    print("(none found)"); sys.exit(0)
hdr = ["NAME","RESOURCE GROUP","OS","STATE","ELIGIBLE"]
w = [max(len(h), *(len(str(r[k])) for r in rows)) for h,k in
     zip(hdr, ["name","resourceGroup","os","state","eligible"])]
def line(c): print("  ".join(str(x).ljust(w[i]) for i,x in enumerate(c)))
line(hdr); line(["-"*x for x in w])
for r in rows:
    line([r["name"], r["resourceGroup"], r["os"], r["state"],
          "yes" if r["eligible"] else "NO"])
PY

echo >&2
echo "==> Manifest written to $OUT/targets.json" >&2
