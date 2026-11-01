# UniFi Protect: Point-of-Sale Event Ingestion (demo call)

Send a POS transaction to UniFi Protect so it is recorded as a camera event and overlaid on
the footage from the register camera.

Safe to record and publish: **no console address, API key, or camera ID is stored in any file
here.** Everything is prompted at run time, typed in masked, and held in memory only.

## The endpoint

```
POST https://<console>/proxy/protect/integration/v1/pos/cameras/{cameraId}/transactions
X-API-KEY: <your key>
Content-Type: application/json
```

| Field | Required | Notes |
|---|---|---|
| `type` | yes | `sale` or `refund` |
| `externalId` | yes | Your transaction id, 1-255 chars, unique per camera. Best-effort de-dupe. |
| `amount` | yes | Total, `>= 0` (refunds are positive with `type: refund`) |
| `currency` | no | ISO 4217, uppercase, e.g. `AUD` |
| `lineItems` | no | Up to 200 of `{ "title": string, "quantity": integer >= 1 }` |
| `location` | no | `{ "id": string, "name": string }`, e.g. the register |
| `paymentTypes` | no | Up to 20 strings, e.g. `["card"]` |
| `timestamp` | no | Epoch **milliseconds**. Within the last 24 h, at most 5 min ahead. |

Responses:

| Status | Meaning |
|---|---|
| `200` | `{ "created": true, "eventId": "..." }`. `created: false` means duplicate `externalId`. |
| `409` | Same `externalId` is still being processed. Retry shortly. |
| other | Error body with `error` and `name`. |

A `200` means the event was recorded, not that video exists. The overlay only appears if the
camera was recording at that time.

## Prerequisites

1. UniFi Protect 7.3 or later.
2. An API key created **on the console**: UniFi OS > Settings > Control Plane > Integrations >
   Create API Key. Keys from unifi.ui.com (cloud) do not work for this API.
3. The machine running the call can reach the console on the LAN (or via VPN / Teleport).
4. PowerShell 7+ (`pwsh`) for the script.

## Files

| File | Use |
|---|---|
| `Send-PosTransaction.ps1` | Interactive demo. Uses the local console by default, prompts for the key, lists cameras, sends the JSON body. |
| `pos-transaction.http` | Same two calls for the VS Code REST Client extension. Values are prompted. |
| `pos-transaction.sample.json` | Default request body for the script. Edit it to change items, amount, location. |
| `samples/dry-clean/*.json` | Dry clean shop use case: two customers by mobile, six paced transactions. |
| `New-PosBatch.ps1` | Generates a high-volume batch (many tills, real sale times) for load testing. |
| `samples/dry-clean-yesterday/` | Six sales timed yesterday evening, for the batch demo. |
| `.gitignore` | Blocks secrets, the batch ledger and generated batches from being committed. |

## Option 1: PowerShell script (recommended for the video)

```powershell
cd C:\git\unifi\unifi-protect-point-of-sale-event-ingestion\callapi

# Preview the request without sending
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1 -DryRun

# Send it
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1
```

Defaults:

- **Console:** `https://192.168.1.1` (local). Override with `-ConsoleAddress https://10.0.0.1`,
  or `-PromptConsole` to type it in masked (useful on camera if your address is not the default).
- **Request body:** `pos-transaction.sample.json` next to the script. Use `-BodyPath` for another
  file. If the file is not found, the script asks you to paste the JSON (finish with an empty line).
- **timestamp:** always set to the actual send time (epoch ms), right before the POST. Any
  `timestamp` in the JSON is ignored, so you can leave it out of the file.
- **externalId:** replaced with a fresh `DEMO-yyyyMMdd-HHmmss` id each run so re-sends are not
  duplicates. Add `-KeepExternalId` to send the one from the JSON.

What it does:

1. Loads and validates the JSON body.
2. Prompts (masked) for the API key.
3. `GET /v1/cameras` and lists cameras by name. IDs show as `********abcd`.
4. You pick the camera by number.
5. Prints the final request, then `POST`s it (skipped with `-DryRun`) and prints `created` and
   the masked `eventId`.

Other examples:

```powershell
# Different body file
pwsh -File .\Send-PosTransaction.ps1 -BodyPath .\my-refund.json

# Override fields from the JSON for this run only
pwsh -File .\Send-PosTransaction.ps1 -Type refund -Amount 11
pwsh -File .\Send-PosTransaction.ps1 -Amount 129.95 -LocationId register-2 -LocationName "Back Counter"

# Ask for the console address instead of using the default
pwsh -File .\Send-PosTransaction.ps1 -PromptConsole
```

All parameters: `-ConsoleAddress`, `-PromptConsole`, `-BodyPath` (file or folder), `-KeepExternalId`, `-DelaySeconds`, `-Type`,
`-Amount`, `-Currency`, `-LocationId`, `-LocationName`, `-DryRun`, `-ShowIds` (prints IDs in full,
keep off on camera), `-SkipCertificateCheck` (default `$true` for the self-signed cert).

## Use case: dry clean shop

`samples/dry-clean/` holds six counter transactions for two customers, identified by mobile
number. Each lands on the counter camera's timeline, so you can jump from a transaction to the
video of it.

Two script-only keys drive the demo (stripped before sending, the API rejects unknown fields):

- `customerMobile`: becomes the transaction's unique `externalId` as
  `<mobile>-<yyyyMMdd-HHmmssfff>`, so the same customer can have many transactions.
- `delayBeforeSeconds`: pause before that transaction is posted, so the run looks like a real
  counter instead of six events in the same second.

| File | Customer | Delay | Type | AUD | Story |
|---|---|---|---|---|---|
| `01-customer-a-dropoff-suit.json` | A | 0 s | sale | 61.50 | Shirts, suit and ties dropped off, card |
| `02-customer-b-alterations-cash.json` | B | 8 s | sale | 55.00 | Hems and a zip, paid cash |
| `03-customer-a-express-overcoat.json` | A | 8 s | sale | 48.00 | Overcoat with same-day express, EFTPOS |
| `04-customer-b-household-items.json` | B | 10 s | sale | 120.00 | Doona and curtain panels |
| `05-customer-b-pickup-wedding-dress.json` | B | 10 s | sale | 280.00 | Wedding dress collected, split card and cash |
| `06-customer-a-refund-damaged-blouse.json` | A | 12 s | refund | 18.00 | Damaged blouse claim, refunded |

Sample mobiles are fictional (ACMA numbers reserved for drama and examples). They are also masked on screen (`0491***156`) unless you pass `-ShowIds`.

```powershell
# Preview all six (shows the planned delays, sends nothing)
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1 -BodyPath .\samples\dry-clean -DryRun

# Send all six with the per-file delays (about 48 s total)
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1 -BodyPath .\samples\dry-clean

# Same, but a fixed 20 s between each (overrides the file delays)
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1 -BodyPath .\samples\dry-clean -DelaySeconds 20
```

`samples/dry-clean-basic/` is the earlier version without customer mobiles.

## Batch mode: yesterday's sales and high volume

Protect places each transaction at its `timestamp`, not at the time it arrives. So you can
send sales hours later and the tag still lands on the right moment of the recorded video, as
long as the sale is less than 24 hours old and the camera was recording then.

`-Batch` switches the script from live demo to high-volume ingestion:

| Behaviour | Live (default) | Batch (`-Batch`) |
|---|---|---|
| Timestamp sent | actual send time | real sale time from the JSON (`saleTime` or `timestamp`) |
| externalId | new each run | stable: JSON `externalId`, else `<mobile>-<sale time>` |
| Pacing | per-file `delayBeforeSeconds` | `-MaxPerSecond` (default 8, cap 10) |
| Retries | yes | yes, plus a ledger so re-runs skip what was sent |
| Output | full JSON per transaction | one line per transaction |
| Multi-till | one camera | `cameraName` per transaction routes to each till's camera |

`saleTime` accepts ISO 8601 (`2026-10-31T18:10:00+11:00`) or `yesterday 18:10` / `today 09:30`
(local time). A JSON file can hold one transaction or an array of many.

### Demo: catch up yesterday evening

`samples/dry-clean-yesterday/yesterday-evening.json` holds the same six dry clean sales, timed
yesterday from 18:25 to 21:45.

```powershell
# Check the window and plan, sends nothing
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1 -Batch -BodyPath .\samples\dry-clean-yesterday -DryRun

# Send. Run it again to see every one skipped as "already sent".
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1 -Batch -BodyPath .\samples\dry-clean-yesterday
```

Run it before 18:25 on the day you record. After that the earliest sale is over 24 hours old and is rejected
locally (the script shows which and why). Then open Protect and scrub the counter camera to
yesterday evening.

### High-volume test: many tills

```powershell
# 1,000 sales across 6 tills over the last 10 hours (nothing sent)
pwsh -File .\New-PosBatch.ps1 -Count 1000 -Tills 6 -HoursBack 10

# Optional: route each till to its own camera (exact Protect camera names, one per till)
pwsh -File .\New-PosBatch.ps1 -Count 1000 -Tills 2 -CameraNames 'Counter Left','Counter Right'

# Preview, then send at 8 per second (about 2 minutes for 1,000)
pwsh -File .\Send-PosTransaction.ps1 -Batch -BodyPath .\samples\high-volume\generated-batch.json -DryRun
pwsh -File .\Send-PosTransaction.ps1 -Batch -BodyPath .\samples\high-volume\generated-batch.json
```

Generated files and the ledger (`.sent-ledger.json`) are git-ignored. Delete the ledger to allow
a full re-send.

### Limits used by the script

| Limit | Value | Source | What the script does |
|---|---|---|---|
| Request rate | 10 per second per console | stated limit | Paces at `-MaxPerSecond` (default 8, refuses above 10) |
| Sale age | under 24 h | API | Rejects locally above `-MaxAgeMinutes` (default 1435 = 24 h minus 5 min margin) |
| Future skew | 5 min ahead max | API | Rejects locally |
| Line items | 200 per transaction, quantity integer >= 1 | API | Rejects locally |
| Payment types | 20 per transaction | API | Rejects locally |
| externalId | 1-255 characters | API | Rejects locally |
| Amount | >= 0 | API | Rejects locally |
| Server de-dupe | short, in-memory, lost on restart | API | Ledger of `camera|externalId` already sent; re-runs skip them |
| Transient errors | 429, 409, 5xx, network | API | Retries `-MaxRetries` times (default 5), backoff 1, 2, 4, 8, 16 s or `Retry-After` |
| Batch size | one transaction per call | API | Sends sequentially; no bulk endpoint |
| Payload shape | only `type`, `externalId`, `amount`, `currency`, `lineItems{title,quantity}`, `location{id,name}`, `paymentTypes`, `timestamp` | API | Every payload is checked against the full schema on load and again just before sending; unknown fields, wrong types or lengths are rejected with the reason |

Capacity at 8 per second: 480 a minute, about 28,800 an hour, per console. A busy till does
one sale every 30-60 seconds, so even 50 tills at peak need only 1-2 per second. Each store has
its own console, so the limit applies per store.

For production: sync POS clocks to NTP (a 2-minute clock drift is a 2-minute misplaced tag),
send near real time through a local queue, and run an hourly or evening catch-up well inside
the 24-hour window.

## Finding a transaction in Protect

Protect > **Detections** > **Find Anything**. The left panel has a **Point of Sale** group, built
from the data you sent:

- **Transaction:** Sale, Refund
- **Payment Type:** the values you sent (e.g. Card, Cash, Eftpos)
- **Location:** the `location.name` values (e.g. Front Counter)

Tick a filter and the matching events show as thumbnails with the amount on each. Click one to
see the transaction ID (with a copy button), time, payment type, amount, items, and the video
from just before the sale. Keep **Overlay Labels > Integrations** ticked to see the POS overlay.

The **Find anything** text box is an AI search over the video. It does not match transaction
IDs or customer mobiles: searching a mobile returns no results. Find by filters plus time, then
read the ID on the event.

### Storage and retention

A transaction is only useful while its footage exists. Protect records on a rolling basis: when
storage fills, the oldest recordings are overwritten, and those transactions no longer have video
behind them. Before relying on this for disputes:

- Check the counter camera's estimated retention in Protect (Settings > Recordings).
- Size storage for your longest dispute window. Card chargebacks can arrive months after the sale.
- Record the counter camera continuously, or at least on detections, so every sale has video.
- Keep your POS system as the record of truth; Protect holds the video evidence.

## API limitations (Protect 7.3.70)

From the console's own OpenAPI spec for this endpoint and the wider Integration API.

| Area | Limitation |
|---|---|
| Access | LAN only. Key must be created on the console. Cloud keys and unifi.ui.com URLs do not work. |
| Scale | One key per console. No central multi-site API; each store needs its own sender on its LAN. |
| Transaction types | Only `sale` and `refund`. No void, no-sale (drawer open), discount, or layaway types. |
| Amount | `>= 0`, single total. No tax, subtotal, discount or tender split amounts. |
| Line items | `title` and integer `quantity >= 1` only. No price, SKU, or negative quantity. Max 200. |
| Custom data | `additionalProperties: false`. No customer, mobile, operator/cashier, or order fields. Anything extra must be packed into `externalId` (max 255 chars). |
| Payment types | Free-text strings, max 20. |
| Time window | `timestamp` must be within the last 24 h and at most 5 min ahead. No backfilling older history. |
| Idempotency | `externalId` de-dupe is in-memory and short-lived; resets on restart. Your sender must dedupe and queue. |
| Batch | One transaction per call. No bulk endpoint. |
| Camera mapping | One camera per transaction. You map register to camera yourself. Needs write access to that camera. |
| Footage | `200` means the event was recorded, not that video exists. Camera must be recording (detections or adaptive mode, or continuous). |
| Read back | No GET or search endpoint for POS transactions in the Integration API. Review happens in Protect > Detections > Find Anything (filters: Sale/Refund, Payment Type, Location). |
| Search | Filters only. The AI text search does not match transaction IDs or mobiles. |
| Retention | Transactions are only as useful as the footage. Overwritten recordings mean no video for older sales. |
| Rate limits | 10 requests per second per console. Batch mode paces at 8 and retries on `429`. |

## Option 2: VS Code REST Client

Install `humao.rest-client`, open `pos-transaction.http`, click **Send Request** above each
call. Run request 1 to get the camera id, then request 2. Each value is prompted.

## Option 3: curl

Set the values in the shell session only (they are not saved):

```powershell
$env:UNIFI_URL = Read-Host 'Console address'
$env:UNIFI_KEY = Read-Host 'API key' -MaskInput
$env:CAMERA_ID = Read-Host 'Camera id'

# List cameras
curl.exe -k -H "X-API-KEY: $env:UNIFI_KEY" "$env:UNIFI_URL/proxy/protect/integration/v1/cameras"

# Send a transaction
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$body = @"
{"type":"sale","externalId":"DEMO-$ts","amount":47.00,"currency":"AUD",
 "lineItems":[{"title":"Flat White","quantity":2}],
 "location":{"id":"register-1","name":"Front Counter"},
 "paymentTypes":["card"],"timestamp":$ts}
"@
$body | curl.exe -k -X POST "$env:UNIFI_URL/proxy/protect/integration/v1/pos/cameras/$env:CAMERA_ID/transactions" `
  -H "X-API-KEY: $env:UNIFI_KEY" -H "Content-Type: application/json" --data-binary '@-'

# Clean up
Remove-Item Env:UNIFI_URL, Env:UNIFI_KEY, Env:CAMERA_ID
```

Bash equivalent: `read -s UNIFI_KEY` then the same `curl -k` calls.

## Recording checklist

- [ ] Use a **demo API key** and delete it in the console right after recording.
- [ ] Do not show the browser address bar on unifi.ui.com: the URL contains your console ID.
- [ ] Keep `-ShowIds` off.
- [ ] Do not scroll terminal history that contains earlier unmasked commands.
- [ ] Clear `$env:` variables if you used the curl option.
- [ ] Run `git status` before pushing: nothing outside this folder's tracked files should appear.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `401` | Key wrong or created in the cloud. Create it on the console. |
| `403` | Key lacks write access to that camera. |
| `404` | Wrong console address, or Protect older than 7.3. |
| `400` | Check `timestamp` (epoch ms, last 24 h), `currency` uppercase, `amount >= 0`, `quantity >= 1`. |
| `409` | Wait a second and retry; same `externalId` in flight. |
| `302` to login | You used a unifi.ui.com URL. This API is LAN only. |
| TLS error | Keep `-SkipCertificateCheck $true` or use `curl -k`. |
| `200` but no overlay | Camera was not recording at that time (check recording mode). |
