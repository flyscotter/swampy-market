# Swampy Prediction Market — v3 (Google OAuth + Leaderboard)

Upgraded from v2 to add:

1. Google OAuth sign-in (replaces anonymous auth)
2. User profiles with display name, avatar, and bet statistics
3. Public leaderboard ranked by balance, with opt-out toggle
4. Every bet is tagged with the user's display name for future global feeds

## Important: this is a fresh-start upgrade

The v3 schema **drops all v2 tables and deletes all existing auth users**. Your current test data will be wiped. This is by design — you asked for "wipe everything and start fresh."

If you have anonymous users with balances you care about, do NOT run the v3 schema yet.

## Setup

### Step 1 — Set up Google OAuth in Google Cloud Console

1. Go to https://console.cloud.google.com
2. Create a new project (top bar → project dropdown → **New Project**). Name it `swampy-market` or whatever you want.
3. Wait for the project to create, then make sure it's selected in the top bar.
4. Go to **APIs & Services** → **OAuth consent screen** in the left sidebar.
5. Choose **External** user type. Click **Create**.
6. Fill in:
   - **App name**: Swampy Prediction Market
   - **User support email**: your email
   - **Developer contact**: your email
7. Click **Save and Continue** through the Scopes page (leave defaults).
8. On the Test users page, click **Save and Continue** (you can skip adding testers if you publish the app later, or add specific emails if you want to keep it in testing mode).
9. On Summary, click **Back to Dashboard**.

### Step 2 — Create OAuth credentials

1. In Google Cloud Console, go to **APIs & Services** → **Credentials**.
2. Click **Create Credentials** → **OAuth client ID**.
3. Application type: **Web application**.
4. Name: `Swampy Market Web Client` (or anything).
5. Under **Authorized JavaScript origins**, add:
   - `https://flyscotter.github.io` (your GitHub Pages origin)
   - `http://localhost` and `http://127.0.0.1` if you want to test locally (optional)
6. Under **Authorized redirect URIs**, add your Supabase callback URL. It looks like:
   ```
   https://<your-project-ref>.supabase.co/auth/v1/callback
   ```
   You can find this exact URL in Supabase: **Authentication** → **Providers** → **Google** → "Callback URL (for OAuth)".
7. Click **Create**.
8. A popup shows your **Client ID** and **Client secret**. Copy both. Save them somewhere safe — you'll paste them into Supabase next.

### Step 3 — Connect Google to Supabase

1. In Supabase dashboard, go to **Authentication** → **Providers**.
2. Find **Google** in the list and click it.
3. Toggle **Enable Sign in with Google** on.
4. Paste your Google **Client ID** and **Client Secret** from Step 2.
5. Leave **Skip nonce check** unchecked (it should be unchecked by default).
6. Click **Save**.

### Step 4 — Disable anonymous sign-ins (optional cleanup)

1. Still in **Authentication** → **Providers**, find the Email provider.
2. Scroll to **Anonymous sign-ins** and toggle it off. You won't need it anymore.
3. Save.

### Step 5 — Set your admin password in the schema

1. Open `schema.sql` in a text editor.
2. Find both occurrences of `'swampy-admin-CHANGE-ME'` and replace with your admin password.
3. Save.

### Step 6 — Run the v3 schema

**This will delete everything from v2.**

1. In Supabase → SQL Editor → New query.
2. Paste the entire contents of `schema.sql`.
3. Click **Run**.
4. You should see "Success. No rows returned."
5. Verify in **Table Editor** that `market`, `players`, and `bets` tables exist and the `players` table has new columns like `display_name`, `show_on_leaderboard`, `total_wagered`, etc.

### Step 7 — Configure index.html

1. Open `index.html`.
2. Find the SUPABASE_URL and SUPABASE_ANON_KEY block near the top of the script.
3. Paste your Supabase URL and anon key (same values as v2).
4. Save.

### Step 8 — Test locally

1. Open `index.html` in a browser directly.

   **Important:** Google OAuth redirects back to an exact origin. If you open the file via `file://` it will fail. Either:
   - Add `http://localhost` to your Google Cloud authorized origins and serve the file via a tiny local server: in PowerShell, in the folder, run `python -m http.server 8000` (requires Python) and visit `http://localhost:8000`.
   - Or just test after pushing to GitHub Pages.

2. Click **Sign in with Google**. Complete the Google OAuth flow.
3. After redirect, you should see your Google name and avatar in the user bar, a balance of Ƒ1,000, and the leaderboard showing just you.
4. Place a bet. Your name should now appear on the leaderboard with the updated balance.
5. Open the Profile panel. Change your display name. Toggle the leaderboard visibility off and on. All changes should persist.
6. Sign out. Verify you see the sign-in screen with the leaderboard preview.

### Step 9 — Push to GitHub

```
git add .
git commit -m "v3: Google OAuth, profiles, leaderboard"
git push
```

After GitHub Pages rebuilds (~30 seconds), visit the site and test the full flow in production.

## How the features work

### Sign-in screen (signed-out state)

Anyone visiting the page who isn't signed in sees:

1. The market question, status, and market info card.
2. A prominent "Sign in with Google" button.
3. A leaderboard preview showing the top 10 players (public data, no auth needed).

They can see the market exists and who's winning, but cannot place bets until signed in.

### Profile panel

Click the **Profile** button in the user bar. Expands a panel showing:

1. Editable display name (1–40 characters). Click Save to persist. Changes propagate to all historical bets for this user.
2. Email (read-only, from Google).
3. Leaderboard visibility toggle.
4. Stats: bets placed, bets won/lost, total wagered, total won.

### Leaderboard

Shows top 10 players by current balance among users who haven't opted out. Updates in real time whenever anyone's balance changes (via realtime subscription). Your own row is highlighted in green with a "(you)" label.

Ranks 1, 2, 3 get gold/silver/bronze colored numbers.

### Opt-out privacy

When a user toggles "Show on leaderboard" off:

1. Their row disappears from the public leaderboard immediately.
2. They can still see their own balance and stats in their profile.
3. Other users still see their past bets in the global bet history (the bets themselves are still tagged with their display name). If this bothers you, tell me and I'll add bet-level anonymization too.

## Security notes

1. Row Level Security prevents any client from writing to the database directly. Balance updates, bet placements, and leaderboard opt-outs all go through `SECURITY DEFINER` Postgres functions.
2. The public SELECT policy on `players` allows reading only rows where `show_on_leaderboard = true` OR the row belongs to the current user. So opted-out players' balances remain private.
3. `bets` is fully public-readable. This is intentional so anyone can audit the market. If you want bets hidden from non-owners, let me know and I'll adjust.
4. The admin password still lives only in the Postgres function bodies. Guard it accordingly.

## Troubleshooting

**"redirect_uri_mismatch" when signing in with Google**

1. The redirect URI in your Google Cloud Console doesn't match what Supabase is using.
2. Copy the exact URL shown at Supabase → Authentication → Providers → Google → Callback URL.
3. Paste it into Google Cloud Console → Credentials → your OAuth client → Authorized redirect URIs.
4. Save. Wait 30 seconds. Try again.

**Signed in but see "Failed to connect: …"**

1. The `ensure_player` RPC is failing. Open browser devtools → Network tab → find the failing request → look at the response for the actual error.
2. Most common cause: you ran v2 schema previously and v3 schema's drops didn't fully clean up. Try manually dropping everything in SQL Editor:
   ```
   drop table if exists public.bets cascade;
   drop table if exists public.players cascade;
   drop table if exists public.market cascade;
   ```
   Then re-run the full `schema.sql`.

**Leaderboard is empty even though I've placed bets**

1. Check that `show_on_leaderboard` is `true` in your profile. Toggle it off and back on to force a refresh.
2. Hard-refresh the page (Ctrl+F5).

**Google sign-in works but the site doesn't show me as signed in**

1. Check the browser console for errors.
2. Confirm the URL you were redirected back to matches the page URL — sometimes Google redirects to a slightly different path (e.g., missing trailing slash) which can break the session detection.

## Customization

- **Starting balance for new users**: change `default 1000` on the `players.balance` column.
- **Leaderboard size**: change `.limit(10)` in `loadLeaderboard()` in index.html.
- **Leaderboard sort order**: currently sorts by `balance desc`. Change the `.order(...)` call if you want to sort by net winnings or total wagered.
- **Disable public leaderboard access for anonymous visitors**: change the `players_read_public` RLS policy to require `auth.uid() is not null`.
