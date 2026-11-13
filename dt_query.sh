#!/usr/bin/env bash
#
# dt_query.sh — run a DQL query against Dynatrace Grail and print JSON results.
#
# Uses the platform token (dt0s16...) from creds.json against the Grail
# query:execute API, handling the async execute -> poll handshake.
#
# Usage:  ./dt_query.sh 'fetch logs | limit 5'
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q="${1:?usage: dt_query.sh '<DQL>'}"

TENANT=$(python3 -c "import json;print(json.load(open('$ROOT/creds.json'))['credentials']['dtTenantId'])")
TOKEN=$(python3 -c "import json;print(json.load(open('$ROOT/creds.json'))['credentials']['dtPlatformToken'])")
APPS="https://${TENANT}.apps.dynatrace.com"

body=$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1], "requestTimeoutMilliseconds": 30000, "fetchTimeoutSeconds": 30}))' "$Q")

resp=$(curl -s --max-time 40 -X POST "$APPS/platform/storage/query/v1/query:execute" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$body")

# If we got a requestToken, poll until the result is ready.
token=$(printf '%s' "$resp" | python3 -c 'import sys,json;
try:
    d=json.load(sys.stdin); print(d.get("requestToken",""))
except Exception: print("")' 2>/dev/null)

if [ -n "$token" ]; then
  for _ in $(seq 1 20); do
    poll=$(curl -s --max-time 40 -G "$APPS/platform/storage/query/v1/query:poll" \
      -H "Authorization: Bearer $TOKEN" --data-urlencode "request-token=$token")
    state=$(printf '%s' "$poll" | python3 -c 'import sys,json;
try: print(json.load(sys.stdin).get("state",""))
except Exception: print("")' 2>/dev/null)
    if [ "$state" = "SUCCEEDED" ]; then resp="$poll"; break; fi
    if [ "$state" = "FAILED" ] || [ "$state" = "CANCELLED" ]; then resp="$poll"; break; fi
    sleep 3
  done
fi

printf '%s' "$resp" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    recs=d.get("result",{}).get("records", d.get("records"))
    if recs is None:
        print(json.dumps(d, indent=2)[:2000])
    else:
        print(json.dumps(recs, indent=2))
except Exception as e:
    print("raw:", sys.stdin.read()[:2000])'
