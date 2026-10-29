# Lookup service (Cloudflare Worker)

The badge app never talks to Swapcard directly. It asks a small Cloudflare Worker
([worker.js](worker.js)), and the Worker asks Swapcard. The real Swapcard API key lives only
on Cloudflare, so a lost or copied laptop never exposes it.

```
laptop app  --(laptop token)-->  Cloudflare Worker  --(Swapcard API key)-->  Swapcard
```

- **Laptops** can only look up the event, or one student by badge code or email, and only
  get back name, major, year and badge code.
- **The laptop token** can be changed in one place, which locks out every laptop at once.
- **Cost:** free. Cloudflare's free plan allows 100,000 requests a day; the Expo needs a few thousand.

## The account (keep this with the IT committee)

Create the Cloudflare account with the **shared IT committee email**, not a personal one,
and turn on two-factor authentication. Each year the outgoing IT chair hands the email login
to the next chair. That's the only handover needed: the Worker and its settings live in the account.

## First-time setup (about 15 minutes, all in the browser)

1. Sign in at <https://dash.cloudflare.com> with the IT committee account.
2. Go to **Workers & Pages → Create → Create Worker** (start from "Hello World").
   Name it `expo-nametag` and click **Deploy**.
3. Click **Edit code**, replace everything with the contents of [worker.js](worker.js),
   and click **Deploy**.
4. Go to the Worker's **Settings → Variables and Secrets** and add:

   | Name | Type | Value |
   |---|---|---|
   | `SWAPCARD_API_KEY` | Secret | This year's key from Swapcard Studio → API keys |
   | `SWAPCARD_EVENT_ID` | Text | This year's Swapcard event ID |
   | `LAPTOP_TOKEN` | Secret | A long random password (see below) |

   To make a random token, run this in PowerShell and copy the output:
   ```powershell
   $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b)
   ```
5. Copy the Worker's address from its overview page, e.g.
   `https://expo-nametag.<your-subdomain>.workers.dev`.

## The laptop settings file

Make a file named `ExpoNametag.env` (copy [env.example](../env.example)) and fill in:

```
PROXY_URL="https://expo-nametag.<your-subdomain>.workers.dev"
PROXY_TOKEN="<the LAPTOP_TOKEN from step 4>"
SWAPCARD_YEAR_ID="<id of the School Year field>"
SWAPCARD_MAJOR_ID="<id of the Major field>"
```

Put it next to `ExpoNametagSetup.exe`. The installer copies it into the app's folder.
Never commit it: the repo is public. (`*.env` is already in `.gitignore`.)

## Check that it works

```powershell
$h = @{ Authorization = '<LAPTOP_TOKEN>' }
Invoke-RestMethod -Method Post -Uri '<PROXY_URL>' -Headers $h -ContentType 'application/json' -Body '{"lookup":"event"}'
```

You should see the event's title and dates. A wrong token gives a 401 error.

## Every year

1. In Swapcard Studio, create a new API key for the new event.
2. In the Worker's settings, update `SWAPCARD_API_KEY` and `SWAPCARD_EVENT_ID`, and set a new `LAPTOP_TOKEN`.
3. Make a new `ExpoNametag.env` for the laptops.

**After the Expo:** delete the Swapcard key in Studio and change `LAPTOP_TOKEN`, so nothing
handed out during the event keeps working.
