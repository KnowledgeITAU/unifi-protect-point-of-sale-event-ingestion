# Objective 1: Point-of-sale event ingestion

Push POS transactions into UniFi Protect so they attach to camera footage and you can jump
from a transaction to the video of it.

Scope of this POC: **verify connectivity, discover real device IDs, then send synthetic POS
events.** No real POS system is wired in. The payload builders in `Send-PosEvent.ps1` are the
reusable piece when you do connect one.

## Run order

```powershell
cd pos-ingestion/scripts

# once
../../shared/scripts/Initialize-UnifiSecret.ps1 -ConfigPath ../config/unifi.config.json

./Test-UnifiConnection.ps1                                   # does the key work at all
./Get-UnifiCameras.ps1                                       # list cameras
./Get-UnifiCameras.ps1 -SetAsPosCamera -CameraId <id>        # save the chosen one to config
./Find-PosEndpoint.ps1                                       # discover the POS path (read-only)
./Send-PosEvent.ps1 -Scenario sale -WhatIf                   # inspect the payload
./Send-PosEvent.ps1 -Scenario sale                           # send it
```

## About the endpoint path

The Protect API reference you linked is served behind console auth, and the POS ingestion
paths are **not publicly documented**. Rather than hard-code a guess, `Find-PosEndpoint.ps1`
resolves it against your live console:

1. Tries to pull an OpenAPI/Swagger spec from the console. If one is served, the POS paths
   and their exact request schema come straight out of it. This is the authoritative answer.
2. If no spec is served, GET-probes a list of candidate paths. The status code is the tell:

   | Status | Meaning |
   |---|---|
   | `404` | path does not exist |
   | `405` | path **exists** but rejects GET, i.e. it is the POST ingestion path |
   | `200` | exists and readable |
   | `401` / `403` | exists, but this key lacks scope |

Every probe is a GET, so nothing is written and no event is sent.

If neither finds it, open **UniFi console → Protect → API reference → Point-of-sale event
ingestion**, copy the path, and pass it in:

```powershell
./Send-PosEvent.ps1 -Transport pos -EndpointPath '/the/real/path' -Scenario sale
```

## Two transports

`Send-PosEvent.ps1 -Transport <pos|alarm>`

- **`pos`** — the native POS ingestion endpoint. Richer: full line items, totals,
  payment method, operator. Needs `-EndpointPath` until the path is confirmed. The payload
  follows Protect's `PosTransactionType` model; if your console's spec names fields
  differently, adjust `New-PosPayload`.
- **`alarm`** *(default)* — the documented Alarm Manager webhook,
  `POST /alarm-manager/webhook/{id}`, returns `204`. Works on any Protect build with Alarm
  Manager and is the mechanism existing third-party POS integrations use. Surfaces the
  transaction as an alarm trigger with the detail attached as context, rather than as a
  structured POS record.

For `alarm` you must first create a matching trigger in **Protect → Alarm Manager** whose
webhook ID equals `pos.alarmTriggerId` in the config (`pos-register-1` by default).

## Scenarios

From [samples/sample-transactions.json](samples/sample-transactions.json). All synthetic,
amounts in AUD.

| Scenario | Type | What it exercises |
|---|---|---|
| `sale` | SALE | normal card sale, multiple line items |
| `cash-sale` | SALE | cash tender |
| `void` | VOID | voided transaction |
| `refund` | REFUND | negative amounts and quantities |
| `no-sale` | NO_SALE | drawer opened with no sale, the classic shrinkage flag |
| `large-discount` | SALE | heavy discount line, another shrinkage flag |

`-Scenario all` replays the whole file in order, with `-DelaySeconds` between each so the
events spread across the timeline instead of landing on one frame.

## Config

[config/unifi.config.json](config/unifi.config.json)

| Field | Purpose |
|---|---|
| `activeProfile` | `lan` or `cloud` |
| `pos.cameraId` | camera events attach to; filled by `Get-UnifiCameras.ps1 -SetAsPosCamera` |
| `pos.alarmTriggerId` | must match the Alarm Manager trigger ID in Protect |
| `pos.registerName` | label shown on the event |
| `pos.currency` | currency code for formatting |

No secrets live here. See the [root README](../README.md#how-secrets-are-handled).

## Wiring up a real POS later

The shape to follow is already in `Send-PosEvent.ps1`:

1. Replace the `samples/sample-transactions.json` read with your POS source (webhook
   receiver, DB poll, or file/folder watcher).
2. Map its fields in `New-PosPayload`. That function is the only POS-specific code.
3. Add retry with backoff. Protect's endpoint has no idempotency key, so a naive retry can
   double-post; dedupe on your side using `transactionId`.
