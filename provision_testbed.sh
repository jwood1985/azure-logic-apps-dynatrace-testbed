#!/usr/bin/env bash
#
# provision_testbed.sh — stand up N fresh Logic App (Standard, Windows) resources
#                        to use as instrumentation test targets.
#
# Reuses an existing Workflow Standard (WS1) plan and creates one dedicated
# storage account shared by all the new apps (fine for a disposable test bed).
#
# Usage:
#   ./provision_testbed.sh                 # 4 apps, defaults below
#   COUNT=4 ./provision_testbed.sh
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/out"; mkdir -p "$OUT"

SUB="${AZ_SUBSCRIPTION:-7a91e8b3-ee09-4906-91a2-f357b77a61fd}"   # Sales-Engineering/NORAM
RG="${RG:-josh-wood-resource-grp}"
LOCATION="${LOCATION:-centralus}"
PLAN="${PLAN:-ASP-joshwoodresourcegrp-8e85}"   # existing WS1 (Workflow Standard) plan
COUNT="${COUNT:-4}"
PREFIX="${PREFIX:-dt-la-testbed}"
FUNCTIONS_VERSION="4"

az account set --subscription "$SUB"
echo "==> Provisioning $COUNT Logic App Standard apps into $RG ($LOCATION), plan=$PLAN"

# 1. Dedicated storage account (name: 3-24 lowercase alnum, globally unique).
SA="${SA:-dtlatestbed$RANDOM}"
SA="$(printf '%s' "$SA" | tr -cd 'a-z0-9' | cut -c1-24)"
echo "==> [storage] creating $SA"
if ! az storage account create -g "$RG" -n "$SA" -l "$LOCATION" \
      --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
      --allow-blob-public-access false --output none 2>"$OUT/provision.sa.err"; then
  echo "   !! storage create failed: $(tr '\n' ' ' <"$OUT/provision.sa.err" | head -c 300)"; exit 1
fi
echo "   storage ready: $SA"

# 2. Create the Logic Apps (sequentially — each returns quickly, control-plane only).
: > "$OUT/provisioned.txt"
for i in $(seq 1 "$COUNT"); do
  APP="$(printf '%s-%02d' "$PREFIX" "$i")"
  echo "==> [$i/$COUNT] creating logic app $APP"
  if az logicapp create -g "$RG" -n "$APP" \
        --storage-account "$SA" \
        --plan "$PLAN" \
        --functions-version "$FUNCTIONS_VERSION" \
        --output none 2>"$OUT/provision.$APP.err"; then
    echo "   created: $APP"
    echo "$APP" >> "$OUT/provisioned.txt"
  else
    echo "   !! failed: $(tr '\n' ' ' <"$OUT/provision.$APP.err" | head -c 300)"
  fi
done

echo
echo "==> Provisioned $(wc -l < "$OUT/provisioned.txt") app(s):"
cat "$OUT/provisioned.txt" | sed 's/^/   - /'
echo "==> Done. Run ./discover.sh to pick them up."
