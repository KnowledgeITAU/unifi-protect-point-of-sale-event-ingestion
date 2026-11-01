# UniFi Protect: POS Transactions on Camera Footage

Sends point-of-sale transactions to UniFi Protect so each sale shows on the camera footage.
Nothing sensitive is saved: the API key is typed in hidden each run.

## Before you start

1. Install PowerShell 7:
   ```powershell
   winget install --id Microsoft.PowerShell -e
   ```
2. Create an API key on the console: UniFi OS > Settings > Control Plane > Integrations > Create API Key.
3. Be on the same network as the console. The script uses `https://192.168.1.1`. If yours is
   different, add `-ConsoleAddress https://<your-console-ip>` to the commands below.
4. Open a terminal in this folder:
   ```powershell
   cd C:\git\unifi\unifi-protect-point-of-sale-event-ingestion\callapi
   ```

## Step 1: Send one sale

```powershell
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1
```

**What to expect:**
1. It asks for the API key. Paste it; nothing shows as you type.
2. It lists your cameras. Type the number of the camera facing the till.
3. It prints the sale, then a green line starting `[1/1] ok`, then `Created 1 ... Failed 0`.

## Step 2: Dry clean demo (six sales, live)

```powershell
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1 -BodyPath .\samples\dry-clean
```

**What to expect:** six sales sent one by one, with a countdown between each (about 48 seconds
in total). Each shows a green `ok` line, then the summary `Created 6 ... Failed 0`.

## Step 3: Catch up yesterday's sales (batch)

```powershell
pwsh -ExecutionPolicy Bypass -File .\Send-PosTransaction.ps1 -Batch -BodyPath .\samples\dry-clean-yesterday
```

**What to expect:** six lines marked `ok`, each with yesterday evening's time, then a summary
`Created 6 ... Failed 0`. Run it again and every line shows `skip already sent`.

The sample sales are timed yesterday from 18:25 to 21:45, and Protect only accepts sales from
the last 24 hours. Run this step before 6:25 pm (any day) or some lines show `REJECTED`.
To send them again, delete the `.sent-ledger.json` file in this folder.

## Step 4: See it in Protect

Protect > **Detections** > **Find Anything** > **Point of Sale**. Tick **Cash** (or Sale, Refund,
Card). Click a result to see the transaction details and the video of the sale.

## Tip: preview without sending

Add `-DryRun` to any command to see exactly what would be sent. Nothing goes to Protect.

## If something goes wrong

| You see | Fix |
|---|---|
| `pwsh` is not recognised | Install PowerShell 7, then open a new terminal. |
| `HTTP 401` | Wrong key, or made in the cloud. Create it on the console. |
| `HTTP 404 ... camera not found` | Run again and pick the camera again. |
| Timeout or connection refused | Wrong console address, or not on the console's network. |
| `REJECTED ... h old` | The sale is more than 24 hours old. |
