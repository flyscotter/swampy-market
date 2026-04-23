# Swampy vs. Elite Four — FungBucks Prediction Market

A single-file, zero-backend prediction market built for Discord link previews.

**Market:** Will Swampy take down the Elite Four by the end of the week?
**Currency:** FungBucks (Ƒ)

## What it does

- Players get Ƒ1,000 to start
- Parimutuel odds with a 5% house edge — odds shift as bets come in
- Bets lock in at the odds shown at time of bet
- Each visitor has their own independent session (stored in browser localStorage)
- Settle panel resolves the market as Yes or No and pays out winners
- Reset button clears everything

## Limitations (important)

This is a static site. There is **no shared pool** between visitors — each person bets against their own seeded pool. If you want real multiplayer betting with a synced pool, you need a backend (Firebase, Supabase, Cloudflare D1, etc.). This version is fine for a Discord bit, a demo, or a solo toy.

## Deploy to GitHub Pages

### 1. Create the repo

Go to https://github.com/new and create a new public repo named `swampy-market` (or anything else you want) under `flyscotter`.

### 2. Push the files from PowerShell

From the folder containing `index.html` and `README.md`, run:

```
cd path\to\swampy-market
git init
git add .
git commit -m "Initial prediction market"
git branch -M main
git remote add origin https://github.com/flyscotter/swampy-market.git
git push -u origin main
```

### 3. Enable GitHub Pages

1. Go to your repo on github.com
2. Click **Settings** → **Pages** in the left sidebar
3. Under **Build and deployment**, set **Source** to `Deploy from a branch`
4. Set **Branch** to `main` and folder to `/ (root)`
5. Click **Save**
6. Wait 30–60 seconds. Your site will be live at:

```
https://flyscotter.github.io/swampy-market/
```

### 4. Post it in Discord

Just paste the URL in Discord. It will show a link preview using the Open Graph tags in the HTML. Anyone who clicks opens the live market.

## Customize

- **Starting pools / odds:** edit `INITIAL_POOL_YES` and `INITIAL_POOL_NO` in the script block
- **Starting balance:** edit `INITIAL_BALANCE`
- **House edge:** edit `HOUSE_EDGE` (currently 0.95 = 5% edge). Set to 1.0 for no edge
- **Question text:** edit the `<h1>` and the Open Graph title tags
- **Color scheme:** edit the CSS variables in `:root`

## Local testing

Open `index.html` in a browser directly, or from PowerShell:

```
Start-Process index.html
```

No build step, no dependencies, no server required.
