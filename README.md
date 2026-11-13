# Dynatrace OneAgent — Azure Logic Apps Test Bed

Automates instrumenting Azure **Logic App Standard** resources with Dynatrace,
end to end: **discover → instrument → drive load → verify in Dynatrace**. Built
and validated live against real Logic Apps.

The **Windows site-extension lane is fully working** (4 apps instrumented, agent
reporting, tags + request telemetry confirmed in Dynatrace). The repo also
documents the **Linux lane** findings (OpenTelemetry is the right method; managed
Linux Logic App Standard is not a stable host — use Hybrid/Kubernetes).

---

## Quick Start

```bash
# 0. Prereqs: az CLI (logged in), python3, curl, a Dynatrace tenant + PaaS token.
cd azure-logic-apps

# 1. Configure Dynatrace credentials (git-ignored).
cp config.env.example config.env
#   edit config.env:  DT_TENANT=<env-id>   DT_API_TOKEN=<dt0c01... PaaS token>
source config.env

# 2. (optional) Provision throwaway Windows Logic App Standard targets.
./provision_testbed.sh                 # creates N apps on a WS1 plan + storage

# 3. Discover eligible targets across all visible subscriptions.
./discover.sh                          # -> out/targets.json (Windows/Standard gating)

# 4. Preview, then instrument.
./instrument.sh --all --dry-run        # mutates nothing
./instrument.sh --all                  # set DT_* settings -> ARM site-extension -> restart -> verify
#   or one app:
./instrument.sh --name <app> --rg <rg>

# 5. Deploy a sample workflow + drive load, then confirm in Dynatrace.
./drive_load.sh <app>                  # real workflow runs (or worker root load)
./verify.sh --all                      # ARM state + live Kudu /dynatrace/api/status
./dt_query.sh 'fetch dt.entity.process_group_instance
  | filter matchesValue(tags,"[Environment]LogicAppTestbed") | fields entity.name, tags'
```

Eligibility (enforced by `discover.sh`): `kind` contains `workflowapp` **and**
`reserved == false` (Windows). Site extensions are Windows/Kudu-only; Linux and
Consumption Logic Apps are correctly skipped.

---

## Scripts

| Script | Purpose |
|---|---|
| `provision_testbed.sh` | Create N disposable Windows Logic App Standard targets (WS1 plan + storage) |
| `discover.sh` | Resource-Graph sweep → `out/targets.json` with eligibility flag |
| `instrument.sh` | Per app: DT_* app settings → ARM `siteextensions` deploy → restart → verify. `--all` / `--name` / `--dry-run` / `--drive-load` |
| `verify.sh` | Dual-signal check: ARM `provisioningState` + Kudu `/dynatrace/api/status` + `DT_TENANT` |
| `drive_load.sh` | Drive load via the workflow HTTP-trigger callback, or worker root |
| `dttags_canary.sh` | Safely test a `DT_TAGS` value on one app with health monitoring + auto-rollback |
| `dt_query.sh` | Run DQL against Dynatrace Grail (`query:execute`) using the platform token |
| `fine_probe.sh` | Characterize an app's restart health signature at 2s resolution |
| `templates/dynatrace-oneagent-siteextension.json` | The ARM template (installs the `Dynatrace` site extension) |

---

## Configuration

`config.env` (copy from `config.env.example`, **git-ignored**):

| Var | Meaning |
|---|---|
| `DT_TENANT` | Dynatrace environment ID (e.g. `abc12345`) |
| `DT_API_TOKEN` | PaaS token (`dt0c01…`) with **InstallerDownload** scope |
| `DT_SSL_MODE` | OneAgent SSL mode (`default`) |
| `DT_MONITORED_CLR` | `dotNetFramework` / `dotNetCore` / `both` |
| `AZ_SUBSCRIPTION` | Scope discovery to one subscription (optional) |

`dt_query.sh` reads a Dynatrace **platform token** (`dt0s16…`) from a local
`creds.json` (also git-ignored). Never commit tokens.

---

## Logic Apps flavors & instrumentation method

| Flavor | OS | Method |
|---|---|---|
| **Standard** (`Microsoft.Web/sites`, `workflowapp`) | **Windows** | **OneAgent site extension** ← this test bed |
| Standard | Linux | **OpenTelemetry** via `host.json` (no site extension; LD_PRELOAD causes request timeouts) |
| Standard / Hybrid | Linux container (Container Apps / Arc K8s) | OneAgent via **Dynatrace Operator / CNFS** |
| **Consumption** (`Microsoft.Logic/workflows`) | n/a | No in-process agent — platform logs/metrics only (ANDS) |

---

## Findings (validated live)

- **`DT_TAGS` does not kill the app.** Any app-setting change forces a restart;
  the transient `503`/cold-start window is what reads as "killed" but
  self-recovers. `azure.*` tag nomenclature is fine (e.g.
  `DT_TAGS=azure.logicapp_name=ABC`) — a plain restart with *no* tag change shows
  the same `503` signature. Avoid spaces in the value (az `--settings` would
  split them) and special chars (newline/`&`/quote can corrupt the settings blob).
- **Windows lane works end to end:** 4 apps instrumented (OneAgent 1.349.x),
  live CPU + request counts + the `LogicAppTestbed` tag queryable in Grail.
- **Managed Linux Logic App Standard is not a stable host:** created OK, but the
  runtime errors (`System.Linq: Sequence contains no elements`, persistent 503)
  independent of Dynatrace. The real Linux path is **Hybrid** (containers on
  Container Apps / Kubernetes) with Operator/CNFS injection.

---

## Safety

- `config.env`, `creds.json`, `out/`, and `*.zip` are git-ignored.
- `--dry-run` validates and prints the plan without changing anything.
- Each app is handled independently — one failure doesn't abort the batch.
- `dttags_canary.sh` auto-rolls-back (removes the setting + restarts) on failure.
