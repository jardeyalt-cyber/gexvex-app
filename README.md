# GexVex

Live GEX/VEX (gamma and vanna exposure) heatmaps on your phone.

GexVex is two repos that work together:

| Repo | What it does |
| --- | --- |
| **gexvex-bot** | A Python bot (`bot.py`) that runs on GitHub Actions during market hours. Every 30 seconds it pulls exposure data and option chains from the Tradytics API for SPY, QQQ, SMH, VIX, TSLA, AAPL and NVDA, then writes the results to a Google Sheet, a secret GitHub Gist, and (optionally) Discord. |
| **gexvex-app** (this repo) | A single-page web app (`index.html`) you install on your phone. It reads the Gist every 30 seconds and shows four views: the 0DTE map, the Scanners tab (all-expiry magnets, node growth vs the magnet, and the 7DTE magnet scanner), the weekly OPEX GEX/VEX matrix for SPY, and the Flow tab (unusual options flow presets: big opening orders, per-ticker rankings, repeated OI accumulation, IV inflation). |

```
Tradytics API ──► gexvex-bot (GitHub Actions) ──┬──► Google Sheet
                                                ├──► Discord webhook (alerts)
                                                └──► secret Gist: gexvex_live.json ──► gexvex-app (phone)
```

There is no server to run. The bot lives on GitHub Actions and the app is a static page.

---

## Setup

Do these in order. You will end up with six values to paste into the bot repo as secrets:

| Secret | Required | Where it comes from |
| --- | --- | --- |
| `TRADYTICS_API_KEY` | yes | [Step 1](#1-tradytics-api-key) |
| `SPREADSHEET_ID` | yes | [Step 2](#2-google-sheet) |
| `GOOGLE_CREDS_JSON` | yes | [Step 2](#2-google-sheet) |
| `GIST_ID` | for the app | [Step 3](#3-github-gist) |
| `GIST_TOKEN` | for the app | [Step 3](#3-github-gist) |
| `DISCORD_WEBHOOK_URL` | no | [Step 4](#4-discord-optional) |

### 1. Tradytics API key

1. Sign in to your Tradytics account and open its API section.
2. Create or copy your API key. Your plan needs API access.
3. Save it as `TRADYTICS_API_KEY`.

The bot calls `https://tradytics.com/api/public/v1/options/exposure` and `.../options/chain` with this key.

### 2. Google Sheet

The bot writes to the sheet with a Google Cloud **service account** (a robot account with its own email address).

1. **Create the service account.**
   1. Go to the [Google Cloud console](https://console.cloud.google.com/) and create a project (or pick an existing one).
   2. Under **APIs & Services > Library**, enable the **Google Sheets API**.
   3. Under **IAM & Admin > Service Accounts**, create a service account. It does not need any roles.
   4. Open it, go to **Keys > Add key > Create new key > JSON**. A `.json` file downloads.
   5. Save the **entire contents** of that file as `GOOGLE_CREDS_JSON`.
2. **Create the sheet.**
   1. Create a new Google Sheet.
   2. Add these tabs, spelled exactly like this. The bot stops with an error if any is missing:
      - `0DTE Heatmap`
      - `Weekly Opex Heatmap`
      - `Weekly Opex VEX`
      - `7DTE Magnet Scanner` (optional: the bot creates this one if it is missing)
   3. Click **Share** and add the service account's email (the `client_email` value in the JSON file, ending in `iam.gserviceaccount.com`) as an **Editor**.
3. Copy the sheet ID from its URL and save it as `SPREADSHEET_ID`:
   `https://docs.google.com/spreadsheets/d/`**`THIS_PART`**`/edit`

### 3. GitHub Gist

The Gist is how live data gets from the bot to the app.

1. Go to <https://gist.github.com>, create a **secret** gist with one file named exactly `gexvex_live.json`, and give it the content `{}`.
2. Copy the Gist ID from its URL and save it as `GIST_ID`:
   `https://gist.github.com/your-name/`**`THIS_PART`**
3. Create a token the bot can use to update the Gist:
   - **Classic token** (simplest): **Settings > Developer settings > Personal access tokens > Tokens (classic) > Generate new token**, tick only the **`gist`** scope.
   - **Fine-grained token**: under **Account permissions**, set **Gists** to **Read and write**.
4. Save the token as `GIST_TOKEN`.

A secret gist is unlisted, not private: anyone with the ID can read it. Only share the ID with people you want to see the data.

### 4. Discord (optional)

The bot posts an alert when a ticker's king node flips.

1. In your Discord server, open the channel's **Edit Channel > Integrations > Webhooks > New Webhook**.
2. Click **Copy Webhook URL** and save it as `DISCORD_WEBHOOK_URL`.

Leave this secret out and the bot simply skips Discord.

### 5. Add the secrets to gexvex-bot

In the **gexvex-bot** repo, go to **Settings > Secrets and variables > Actions > New repository secret** and add each value from the table above.

### 6. Test the bot

1. In gexvex-bot, open **Actions > GEX/VEX Bot (30s Private Runner) > Run workflow**.
2. Leave the duration at `5` minutes and run it. A manual run ignores market hours, so you can test at any time.
3. When it finishes, check that the sheet tabs filled in and that `gexvex_live.json` in your Gist now holds data.

### 7. Host and install the app

1. **Host it.** The app is static files, so GitHub Pages works: in this repo, go to **Settings > Pages**, choose **Deploy from a branch**, pick `main` and `/ (root)`, and save. After a minute it is live at `https://<your-user>.github.io/gexvex-app/`.
2. **Connect it.** Open that URL on your phone and paste your Gist ID when asked. It is saved on the phone. You can also open `https://<your-user>.github.io/gexvex-app/?gist=<GIST_ID>` to set it in one tap.
3. **Install it.**
   - **iPhone (Safari):** tap **Share > Add to Home Screen**.
   - **Android (Chrome):** tap **Install app** in the menu, or accept the install prompt.

The app opens full screen from the home screen icon. It also opens without a connection (showing the last error until data comes back), because a small service worker (`sw.js`) keeps the page and icons on the phone. Live data is never cached: it always comes from the Gist.

---

## When the bot runs

The workflow is scheduled on weekdays, in two sessions:

| Session | Starts | Runs for |
| --- | --- | --- |
| Morning | 9:15 AM ET | up to 210 minutes |
| Afternoon | 12:40 PM ET | until 4:06 PM ET |

Each start time is listed twice in the cron (once for EST, once for EDT). The bot exits right away on the copy that does not match the current daylight-saving period. It only fetches data from 9:30 AM to 4:05 PM ET, and saves an end-of-day VEX baseline just after 4:00 PM.

The bot keeps VEX history in a small SQLite file (`vex_history.db`) that is carried between runs with the Actions cache. If the cache is cleared, the 10-minute, 1-hour and 1-day change columns start empty and fill back in over the next day.

The bot does not know about market holidays. On a holiday it runs and shows whatever Tradytics returns.

## Troubleshooting

| What you see | Likely cause |
| --- | --- |
| App shows `HTTP 403` or `HTTP 429` | GitHub limits unauthenticated reads to 60 per hour per network, and the app reads every 30 seconds (120 per hour). Expect this partway through a session, especially on shared Wi-Fi. |
| App shows `HTTP 404` | Wrong Gist ID. Clear it by opening the app with `?gist=<correct id>`. |
| App shows `gexvex_live.json missing in Gist` | The Gist file is named something else. Rename it to exactly `gexvex_live.json`. |
| App time stamp stops moving | The bot is not running, or it is outside market hours. Check the latest run under **Actions** in gexvex-bot. |
| Bot fails with `WorksheetNotFound` | A sheet tab is missing or misspelled. See [step 2](#2-google-sheet). |
| Bot fails with `PermissionError` / 403 from Google | The sheet is not shared with the service account email. |
| Bot log shows `Gist update HTTP 404` or `401` | `GIST_ID` is wrong, or `GIST_TOKEN` lacks the `gist` scope or has expired. |
| Phone still shows an old version after an update | Close and reopen the app. If that is not enough, bump `CACHE_VERSION` in `sw.js` when you deploy. |

## Files in this repo

| File | Purpose |
| --- | --- |
| `index.html` | The whole app: layout, styles and script. |
| `manifest.json` | App name, colors and icons used when installing. |
| `sw.js` | Service worker that keeps the app shell available offline. |
| `icons/` | Home screen, maskable (Android) and Apple touch icons. |
