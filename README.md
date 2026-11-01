# UniFi Protect: Point-of-Sale Event Ingestion

Send point-of-sale transactions to UniFi Protect so every sale and refund is pinned to the
camera footage of the till. Find a transaction in Protect, click it, and watch the moment it
happened.

Uses the Protect Integration API endpoint added in Protect 7.3:

```
POST https://<console>/proxy/protect/integration/v1/pos/cameras/{cameraId}/transactions
```

## Quick start

All scripts and samples are in [callapi/](callapi/). Follow the steps in
[callapi/README.md](callapi/README.md): install PowerShell 7, create an API key on the console,
then run one command.

```powershell
cd callapi
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1
```

## What's in the repo

| Path | What it is |
|---|---|
| `callapi/Send-PosTransaction.ps1` | Sends transactions. Live mode for demos, `-Batch` for catching up past sales at volume. |
| `callapi/New-PosBatch.ps1` | Generates a large test batch across several tills. |
| `callapi/samples/dry-clean/` | Six dry clean shop sales, sent live with pauses. |
| `callapi/samples/dry-clean-yesterday/` | The same six sales timed yesterday evening, for the batch demo. |
| `callapi/samples/dry-clean-basic/` | Earlier version of the samples, without customer mobiles. |
| `callapi/pos-transaction.http` | The same calls for the VS Code REST Client extension. |

## Requirements

- UniFi Protect 7.3 or later
- An API key created on the console (cloud keys do not work)
- A machine on the same network as the console
- PowerShell 7

## Good to know

- **Local network only.** The API is reached on the console's LAN address, not through unifi.ui.com.
- **Sales and refunds only.** Line items carry a name and quantity, not prices. No custom fields.
- **24-hour window.** Transactions must be sent within 24 hours of the sale. Protect places each
  one at its sale time, so sending later in the day still tags the right moment.
- **Rate.** Up to 10 calls a second per console. Batch mode sends 8 a second.
- **Search** in Protect is by filters (sale or refund, payment type, location), not by customer.
- **Footage matters.** A transaction only shows video if the camera was recording, and only for as
  long as recordings are kept. Size storage for your dispute window.

## Privacy

No console address, API key or camera ID is stored in this repo. The key is typed in hidden at
run time. Customer mobiles in the samples are fictional numbers reserved for examples.
