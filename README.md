# FungBucks Prediction Markets — v4.3 (Tab restructure)

Small iteration on v4.2. Moved the Recent Bets feed and Leaderboard out from below the market list into their own dedicated tabs.

## What changed

1. Two new tabs on the list view: **Feed** and **Leaderboard**. They sit next to Open / Pending / Settled / My bets / My markets.
2. When Feed or Leaderboard is selected, the market list and "+ New market" button hide. When any of the market tabs is selected, Feed and Leaderboard hide.
3. No schema changes. Purely a UI restructure.

## Deploy

1. Copy `index.html` and `README.md` into `C:\Users\scotch\swampy-market`, overwriting the v4.2 versions.
2. Confirm SUPABASE_URL and SUPABASE_ANON_KEY are still filled in.
3. Push:

```
cd C:\Users\scotch\swampy-market
git add .
git commit -m "v4.3: feed and leaderboard as tabs"
git push
```

4. Hard-refresh the live site.

## Honest note on tab count

You now have 7 tabs on the list view: Open, Pending, Settled, My bets, My markets, Feed, Leaderboard. On narrow mobile screens the tab row is horizontally scrollable — so it technically works, but it's getting close to cluttered. If you add more tabs later, consider consolidating (e.g., merging "My bets" and "My markets" into a single "Mine" tab).

Iteration on v4.1. Adds three anti-bankruptcy mechanisms:

1. **Weekly UBI claim** — Ƒ200 every 7 days, on-demand button.
2. **Emergency reset** — when balance drops below Ƒ50, top up to Ƒ500. Limited to once per 7 days.
3. **Admin grant function** — you can top up (or deduct from) any user's balance via the admin panel on any market detail page.

## What changed

1. New migration SQL: `migration-v4.2.sql`. Safe to run on top of v4.1 — adds columns and functions, does NOT drop data.
2. Wallet panel added to the list view. Shows claim status for both mechanisms and disables buttons appropriately.
3. Admin grant UI added to the admin panel on market detail pages.

## Setup

### Step 1 — Update admin password in migration SQL

1. Open `migration-v4.2.sql`.
2. Find `'swampy-admin-CHANGE-ME'` (appears once in `admin_grant` function).
3. Replace with your admin password — **use the same password you set in v4 `schema.sql`**.
4. Save.

### Step 2 — Run the migration

1. Supabase dashboard → SQL Editor → New query.
2. Paste the entire contents of `migration-v4.2.sql`.
3. Click **Run**. Should see "Success. No rows returned."
4. Verify: Table Editor → `players` table should now have columns `last_ubi_claim`, `last_reset_claim`, `total_ubi_claimed`, `admin_grants_received`.

### Step 3 — Deploy the new HTML

1. Replace your local `index.html` and `README.md` with the v4.2 versions.
2. Open `index.html`, set `SUPABASE_URL` and `SUPABASE_ANON_KEY` (same values as before).
3. Push:

```
git add .
git commit -m "v4.2: UBI + emergency reset + admin grants"
git push
```

## How each mechanism works

### Weekly UBI

1. User sees the Wallet panel at the top of the list view once signed in.
2. Left card shows "Weekly stipend Ƒ200" with a Claim button.
3. Status text shows "Ready to claim" if eligible, or "Next claim in Xh/Xd" otherwise.
4. Clicking Claim adds Ƒ200 to balance and starts a 7-day timer.

### Emergency reset

1. Right card of the Wallet panel. Button is **disabled by default** unless both conditions are met: balance below Ƒ50, AND more than 7 days since last emergency reset.
2. When claimed, balance is set to exactly Ƒ500 (not Ƒ500 added — set to Ƒ500). The top-up amount depends on how broke you were.
3. Button text always shows "→ Ƒ500" so users know the target.

### Admin grant

1. On any market's detail page, scroll to the admin panel.
2. Under "Admin grant" section: enter admin password, target user's UUID, and an amount.
3. Amount can be negative to deduct from a user's balance.
4. To find a user's UUID: Supabase dashboard → Authentication → Users → click on their email → the UUID is at the top. Or Table Editor → players → user_id column.
5. Clicking the button shows a confirmation dialog with the amount and target.

## Customization

All three mechanisms have knobs at the top of their respective functions in `migration-v4.2.sql`.

### UBI
```
ubi_amount  constant numeric  := 200;
ubi_period  constant interval := '7 days';
```

### Emergency reset
```
reset_threshold  constant numeric  := 50;
reset_to         constant numeric  := 500;
reset_period     constant interval := '7 days';
```

The UI thresholds are hardcoded in index.html (`RESET_THRESHOLD = 50`). If you change SQL values, also update index.html to match.

## Economic impact — rough math for a 10-user community

1. **UBI**: If all 10 users claim weekly, ~Ƒ2,000 injected per week. Over a month, ~Ƒ8,000.
2. **Emergency reset**: Rarely triggered. Each claim adds at most Ƒ450.
3. **House edge**: The 5% edge on each settled market removes FungBucks proportional to volume. If community wagers Ƒ5,000/week, that's ~Ƒ250/week removed.

Net: UBI likely outpaces the house edge, leading to slow inflation. If balances get silly (everyone has Ƒ50,000), drop UBI amount or raise house edge.

## Troubleshooting

**"Next UBI available in X hours" when you just claimed** — working as intended. To reset for testing: Supabase → Table Editor → players → find your row → clear `last_ubi_claim` column.

**"Emergency reset only available when balance is below Ƒ50"** — you're not broke enough. Bet something, then claim.

**"Target player not found" when granting** — double-check the UUID. No trailing whitespace.

**Wallet panel doesn't show up** — hard-refresh. If still missing, the migration SQL didn't fully run. Re-run it.

## Honest flags

1. **UBI claim is manual, not automatic.** Supabase free tier doesn't support scheduled tasks for this. Users have to click Claim. This is actually good — it makes supply additions transparent.
2. **No cap on total UBI claimed.** If a user has claimed every week for 6 months, they've collected Ƒ5,200 from UBI alone. Fine for small community, worth knowing.
3. **Admin grants bypass all safeguards.** Negative grants can take balances below zero (weird state). Don't do that.
4. **Emergency reset is once per 7 days, not once ever.** I changed my mind on this during design — with weekly UBI, a weekly reset makes more sense since they reinforce each other. If you want once-ever, tell me and I'll change it.
