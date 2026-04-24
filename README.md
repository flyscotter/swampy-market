# FungBucks Prediction Markets — v4 (Multi-market platform)

Upgrade from v3. Turns the single-question app into a full markets platform where anyone signed in can create their own markets.

## What changed

1. **Multiple markets.** The `market` table is now `markets` (plural), with one row per question. Each has its own pool, close date, and resolution state.
2. **User-created markets.** Any signed-in user can create a market. Creators put up a minimum Ƒ500 seed from their own balance, split between Yes and No however they want.
3. **Creator-proposes, admin-overrides resolution.** Market creator proposes the outcome (Yes / No / Cancelled). There's a 1-hour cooling period during which anyone can file a dispute. After cooling, creator confirms and payouts happen. Admin can bypass cooling or force a different outcome at any time.
4. **Cancellation refunds everything.** If a market is cancelled, all bettors get their stakes back and the creator gets their seed back. The house edge doesn't apply to refunds.
5. **Tabs: Open / Pending / Settled / My bets / My markets.** Replaces the single-market view.
6. **Disputes.** Signed-in users (non-creators) can file disputes on pending resolutions. Disputes are visible on the market page but don't auto-block anything — they're a signal to you (admin) to review before the cooling period ends.
7. **Close dates enforced at the database level.** Bets are rejected if placed after the close date, regardless of what the UI does.

## Important: existing balances are preserved, single Swampy market is wiped

When you run v4 schema:

1. Your v3 `players` table (user accounts, balances, stats) is preserved.
2. The old `market` table and all old `bets` are dropped.
3. Player stats (bets placed, total wagered, etc.) are reset to 0 since the old bets are gone.
4. Balances stay intact.

If you want to nuke everything and start completely fresh, add this line to the top of `schema.sql` before running:

```
update public.players set balance = 1000, markets_created = 0;
```

## Setup

### Step 1 — Update admin password in schema

1. Open `schema.sql`.
2. Find all occurrences of `'swampy-admin-CHANGE-ME'` (appears in `confirm_resolution` and `admin_override_resolution`).
3. Replace with your admin password. Use the same password everywhere.

### Step 2 — Run the schema

1. Supabase → SQL Editor → New query.
2. Paste entire `schema.sql`.
3. Run.
4. Verify in Table Editor: you should see `markets`, `bets`, `disputes` tables. The old `market` (singular) is gone.

### Step 3 — Update index.html

1. Open `index.html`, set `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
2. Save.

### Step 4 — Push to GitHub

```
git add .
git commit -m "v4: multi-market platform"
git push
```

Done.

## How it works — user flow

### Creating a market

1. Click **New market**.
2. Fill in:
   - Question (yes/no phrasing, 10–200 chars)
   - Description (optional but strongly recommended — define resolution criteria clearly)
   - Close date (at least 5 min future, max 90 days)
   - Initial odds via presets (25% / 40% / 50% / 60% / 75% Yes) or custom seed split
3. Click Create. Your Ƒ500+ is deducted, market goes live.

### Placing bets

1. Click any open market in the list.
2. Pick Yes or No, set stake, bet. Same UX as v3.
3. The main difference: each market has its own pool, so odds vary wildly from market to market.

### Resolving a market (as creator)

1. After close date passes, go to your market.
2. Creator controls appear: **Propose Yes** / **Propose No** / **Cancel market**.
3. Click one. Market enters "pending resolution" state. Shows everyone the proposed outcome.
4. 1-hour cooling period begins. During this time:
   - Anyone else signed in can file a dispute with a reason.
   - You as creator can't confirm yet.
5. After cooling period, a **Confirm & pay out** button appears. Click it. Winners get paid, losers lose stakes, market closes.

### Resolving a market (as admin)

If you're watching a market where creator is being sketchy, or cooling period is too slow for you:

1. Scroll to **Admin override** on any non-settled market.
2. Enter admin password.
3. Click Force Yes / Force No / Cancel.
4. This bypasses cooling period and ignores the creator's proposal.

### Filing a dispute

1. Open a market that's in pending resolution.
2. Scroll to the disputes section.
3. Type your reason (5–500 chars).
4. Click Raise dispute. It shows up publicly for everyone including admin.

## Critical things to understand

### The cancellation refund math

When a market is cancelled:

1. Every bettor gets their full stake back.
2. The creator gets their seed back, because the remaining pool after subtracting all real stakes is exactly the creator's seed.
3. No house edge is taken on refunds.

This relies on the accounting working out correctly — the database function handles it, but if you ever manually tamper with pool_yes / pool_no values, cancellation math will break.

### Creators can grief their own markets

By design. A creator can:

1. Create a market, bet on one side, then resolve it as that side.
2. Get away with it if nobody disputes within 1 hour.

Mitigations built in:

1. Disputes section makes shady resolutions visible.
2. Admin override can force any outcome at any time.
3. Creator staked their own Ƒ500 seed — griefing is expensive if the market is cancelled.

If this becomes a real problem, the next iteration would be: creators can't bet on their own markets. Say the word and I'll add that.

### The 1-hour cooling period

Baked into `confirm_resolution` as a constant. To change it, edit this line:

```
cooling_period constant interval := '1 hour';
```

Pick something longer (e.g., `'24 hours'`) if you want a real review window, shorter (e.g., `'5 minutes'`) if you don't care about disputes.

### Why creators must seed from their own balance

It ensures skin in the game. A creator who makes 50 spam markets pays Ƒ25,000 out of pocket. A troll pays for their trolling.

### Realtime is noisy now

Every bet on every market triggers a realtime update. For a small Discord community this is fine. If you ever have hundreds of concurrent users, you'd want to scope realtime subscriptions per-market. Not a problem you need to worry about now.

## What I deliberately didn't build

1. **Creators can't bet on their own markets.** Not enforced. Could be added with a check in `place_bet`.
2. **Market categories or tags.** Flat list for now.
3. **Search.** If you end up with 50+ markets, you'll want this.
4. **Volume-based sorting.** Currently sorts by creation date. Could sort by total pool, or by recent activity.
5. **Automatic market closure.** Markets stay in 'open' status past close date until the creator proposes a resolution — bets are blocked by the database but the UI still says "open". A cron job could auto-move these to a "closed, awaiting resolution" state. Not strictly necessary but nice-to-have.
6. **Notifications.** No way to tell users "the market you bet on resolved." They have to check back.
7. **Leaderboard.** Pulled it out for v4 because the UI was getting crowded. Can be added back — just a panel on the list view. Let me know.

## Troubleshooting

**"Market not found" when clicking a market.** Realtime deleted it while you were loading. Just refresh.

**"Cooling period not over" when trying to confirm.** Exactly what it says. Wait, or use admin override.

**"Cannot resolve before close date" when proposing Yes/No.** You can cancel early, but can't resolve to yes/no until close date passes. By design.

**Creator seed is "too expensive."** Lower the minimum in `create_market`. Currently 500. Change this line:

```
if total < 500 then
  raise exception 'Total seed must be at least Ƒ500...';
```

## Deployment checklist

1. Set admin password in `schema.sql` (2 places).
2. Run `schema.sql` in Supabase SQL editor.
3. Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` in `index.html`.
4. `git add . && git commit -m "v4" && git push`.
5. Wait for GitHub Pages to rebuild (30-60s).
6. Hard-refresh the live site.
7. Create a test market. Bet on it from another account. Resolve it. Confirm it all works end to end.
