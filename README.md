# Swampy vs. Elite Four — Multiplayer Prediction Market

A real-time, shared-pool prediction market backed by Supabase. Everyone who visits bets against the same pool, odds shift live, and the market can be settled by an admin with a password.

## Architecture

1. Static HTML hosted on GitHub Pages.
2. Supabase handles the database, anonymous authentication, and realtime updates.
3. All writes go through Postgres functions guarded by Row Level Security — clients cannot tamper with balances or pools directly.
4. Admin actions (settle, reset) require a password embedded in the SQL function.

## Setup

### Step 1 — Create a Supabase project

1. Go to https://supabase.com and sign up (free, use GitHub to sign in).
2. Click **New Project**.
3. Name it `swampy-market` (or anything).
4. Set a strong database password — you won't need it for this app, but save it somewhere.
5. Choose a region close to you.
6. Click **Create new project**. Wait ~2 minutes for provisioning.

### Step 2 — Enable anonymous sign-ins

1. In the Supabase dashboard, go to **Authentication** → **Providers** → **Email**.
2. Scroll to **Anonymous sign-ins** and enable it.
3. Save.

### Step 3 — Set the admin password

1. Open `schema.sql` in a text editor.
2. Find both occurrences of `'swampy-admin-CHANGE-ME'` (two places — one in `settle_market`, one in `reset_market`).
3. Replace both with your chosen admin password. Use the same password in both.
4. Save the file.

### Step 4 — Run the schema

1. In the Supabase dashboard, click **SQL Editor** in the left sidebar.
2. Click **New query**.
3. Paste the entire contents of `schema.sql`.
4. Click **Run**. You should see `Success. No rows returned.`
5. Verify by going to **Table Editor** — you should see `market`, `players`, and `bets` tables.

### Step 5 — Get your project URL and anon key

1. In Supabase, go to **Settings** (gear icon) → **API**.
2. Copy the **Project URL** (looks like `https://abcdefghij.supabase.co`).
3. Copy the **anon public** key (a long JWT starting with `eyJ…`).

### Step 6 — Configure index.html

1. Open `index.html` in a text editor.
2. Find this block near the top of the script:

```
var SUPABASE_URL      = 'YOUR_SUPABASE_URL_HERE';
var SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY_HERE';
```

3. Replace both values with the ones you copied. Keep the quotes.
4. Save the file.

### Step 7 — Test locally

1. Double-click `index.html` to open it in a browser.
2. You should see the market load, your balance show Ƒ1,000, and the pool at Ƒ12,450.
3. Place a small bet. It should persist if you refresh.
4. Open the same page in a second browser or incognito window — you're now a different user, but you both see the same pool. Place a bet in one window and watch the odds update live in the other.
5. Test the admin panel: enter your admin password and click Reset. Then try a wrong password — you should see an error toast.

### Step 8 — Push to GitHub

From PowerShell, in the project folder:

```
git init
git add .
git commit -m "Multiplayer prediction market with Supabase"
git branch -M main
git remote add origin https://github.com/flyscotter/swampy-market.git
git push -u origin main
```

If you already pushed the v1 single-player version, you have two options:

1. **Overwrite it** — force-push with `git push -u origin main --force` (destroys history).
2. **Replace files** — copy the new `index.html` and add `schema.sql` over the old files, then `git add .`, commit, and push normally.

Either works. The overwrite is cleaner if you never intend to revisit v1.

### Step 9 — Enable GitHub Pages

Same as before:

1. Repo → **Settings** → **Pages**.
2. Source: **Deploy from a branch**, branch: **main**, folder: **/ (root)**.
3. Wait 30–60 seconds. Visit `https://flyscotter.github.io/swampy-market/`.

## Security notes

1. **The anon key is public and that is fine.** It is designed to be exposed in client code. Row Level Security policies prevent abuse.
2. **The admin password lives only in the Postgres function**, not in the client HTML. The client sends the password to the server when you click Settle. Someone inspecting your HTML cannot see the password.
3. **However**, if someone watches network traffic while you settle the market, they could capture the password. For a Discord joke market this is fine. For anything higher-stakes, use Supabase Auth roles and tie admin actions to a specific user ID instead.
4. **Realtime is read-only**. Clients subscribe to changes; they cannot inject fake updates.

## How to actually settle the market

1. Open the site.
2. Scroll to the admin panel at the bottom.
3. Type your admin password in the field.
4. Click **Settle as Yes** or **Settle as No**.
5. Confirm the dialog. Winners are paid out into their balances automatically.
6. The market becomes read-only. Everyone sees "Settled: YES" (or NO) at the top.

## Resetting the market

1. Same panel.
2. Enter admin password.
3. Click **Reset**. All balances go back to Ƒ1,000, all bets are deleted, the pool goes back to 7,719 / 4,731.

## Customization

- **Starting pools and balance:** in `schema.sql`, edit the `default` values on the `market` and `players` tables, and the hardcoded values in `reset_market()`.
- **House edge:** change `house_edge` default in the `market` table. 1.0 means no edge.
- **Question text:** change the seed `insert into public.market` line in `schema.sql`, and the `<h1>` in `index.html`.
- **Admin password:** already covered in Step 3.

## Limitations

1. Supabase free tier pauses inactive projects after 7 days. Log into the dashboard at least weekly to keep it alive.
2. No user display names — everyone is anonymous. If you want Discord usernames, that requires OAuth integration (a meaningful step up in complexity).
3. No leaderboard yet. Easy to add; ask if you want it.
4. Bets are irreversible once placed — no cancel/edit. By design.

## Troubleshooting

**"Failed to connect: …" on page load**

1. Check your SUPABASE_URL and SUPABASE_ANON_KEY are correct in `index.html`.
2. Check Anonymous sign-ins are enabled in Supabase → Authentication → Providers.

**"Not authenticated" errors when placing bets**

1. Check that the `ensure_player` function ran on load (open browser devtools → Network tab, look for a `rpc/ensure_player` call).
2. If it's failing, try running the SQL from `schema.sql` again — sometimes the grants don't apply on first run.

**Pool doesn't update in real time**

1. Confirm in Supabase → Database → Replication that realtime is enabled on `market`, `players`, and `bets`. The SQL should handle this, but verify.
2. Hard-refresh the page.

**Admin password always rejected**

1. Confirm you replaced `'swampy-admin-CHANGE-ME'` in **both** functions (`settle_market` and `reset_market`) with the same password.
2. If you changed the password after creating the functions, you need to re-run that portion of the SQL to update them.
