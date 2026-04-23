-- ============================================================================
-- Swampy vs. Elite Four Prediction Market — Supabase Schema
-- ============================================================================
-- Paste this entire file into Supabase SQL Editor and click Run.
-- It is idempotent: safe to re-run if you need to tweak something.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tables
-- ----------------------------------------------------------------------------

-- Single row representing the market itself.
create table if not exists public.market (
  id               int primary key default 1,
  question         text not null,
  pool_yes         numeric not null default 7719,
  pool_no          numeric not null default 4731,
  house_edge       numeric not null default 0.95,
  settled_outcome  text check (settled_outcome in ('yes', 'no')) default null,
  settled_at       timestamptz default null,
  created_at       timestamptz not null default now(),
  constraint single_row check (id = 1)
);

-- Per-user balance + stats.
create table if not exists public.players (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  balance          numeric not null default 1000,
  display_name     text,
  created_at       timestamptz not null default now()
);

-- Every bet placed.
create table if not exists public.bets (
  id               bigserial primary key,
  user_id          uuid not null references auth.users(id) on delete cascade,
  side             text not null check (side in ('yes', 'no')),
  stake            numeric not null check (stake > 0),
  odds             numeric not null check (odds > 0),
  resolved         text check (resolved in ('won', 'lost')) default null,
  payout           numeric default null,
  created_at       timestamptz not null default now()
);

create index if not exists bets_user_id_idx on public.bets(user_id);
create index if not exists bets_created_at_idx on public.bets(created_at desc);

-- Seed the market row if it does not exist.
insert into public.market (id, question)
values (1, 'Will Swampy take down the Elite Four by the end of the week?')
on conflict (id) do nothing;

-- ----------------------------------------------------------------------------
-- 2. Row Level Security
-- ----------------------------------------------------------------------------
-- Clients read everything, but cannot write directly. All writes go through
-- SECURITY DEFINER functions below.

alter table public.market  enable row level security;
alter table public.players enable row level security;
alter table public.bets    enable row level security;

-- Public read access on everything.
drop policy if exists "market_read_all"  on public.market;
drop policy if exists "players_read_all" on public.players;
drop policy if exists "bets_read_all"    on public.bets;

create policy "market_read_all"  on public.market  for select using (true);
create policy "players_read_all" on public.players for select using (true);
create policy "bets_read_all"    on public.bets    for select using (true);

-- No direct insert/update/delete policies — everything goes through functions.

-- ----------------------------------------------------------------------------
-- 3. Realtime
-- ----------------------------------------------------------------------------
-- Enable realtime broadcasts for the three tables so every client stays in
-- sync without polling.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'market'
  ) then
    alter publication supabase_realtime add table public.market;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'players'
  ) then
    alter publication supabase_realtime add table public.players;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'bets'
  ) then
    alter publication supabase_realtime add table public.bets;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 4. Functions
-- ----------------------------------------------------------------------------

-- Ensure a player row exists for the calling user. Called on first load.
create or replace function public.ensure_player()
returns public.players
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  insert into public.players (user_id)
  values (auth.uid())
  on conflict (user_id) do nothing;

  select * into p from public.players where user_id = auth.uid();
  return p;
end;
$$;

-- Place a bet atomically.
-- Deducts the stake, locks in the odds at the current pool ratio, inserts the
-- bet row, and updates the pool. All in one transaction.
create or replace function public.place_bet(bet_side text, bet_stake numeric)
returns public.bets
language plpgsql
security definer
set search_path = public
as $$
declare
  m         public.market;
  p         public.players;
  new_odds  numeric;
  new_bet   public.bets;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if bet_side not in ('yes', 'no') then
    raise exception 'Invalid side: %', bet_side;
  end if;

  if bet_stake is null or bet_stake <= 0 then
    raise exception 'Stake must be positive';
  end if;

  -- Lock the market and player rows for the duration of this transaction.
  select * into m from public.market where id = 1 for update;

  if m.settled_outcome is not null then
    raise exception 'Market already settled';
  end if;

  select * into p from public.players where user_id = auth.uid() for update;

  if p is null then
    -- Auto-create the player if somehow missed.
    insert into public.players (user_id) values (auth.uid())
    returning * into p;
  end if;

  if p.balance < bet_stake then
    raise exception 'Insufficient balance (have %, need %)', p.balance, bet_stake;
  end if;

  -- Calculate odds using parimutuel formula with house edge.
  if bet_side = 'yes' then
    new_odds := ((m.pool_yes + m.pool_no) / m.pool_yes) * m.house_edge;
  else
    new_odds := ((m.pool_yes + m.pool_no) / m.pool_no) * m.house_edge;
  end if;

  -- Deduct stake from player balance.
  update public.players
    set balance = balance - bet_stake
    where user_id = auth.uid();

  -- Insert the bet with locked-in odds.
  insert into public.bets (user_id, side, stake, odds)
  values (auth.uid(), bet_side, bet_stake, new_odds)
  returning * into new_bet;

  -- Update the pool.
  if bet_side = 'yes' then
    update public.market set pool_yes = pool_yes + bet_stake where id = 1;
  else
    update public.market set pool_no  = pool_no  + bet_stake where id = 1;
  end if;

  return new_bet;
end;
$$;

-- Settle the market. Password-gated (set your secret in the body below).
-- Pays out winners based on their locked-in odds; losers get nothing.
create or replace function public.settle_market(outcome text, admin_password text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- ============================================================
  -- CHANGE THIS PASSWORD BEFORE POSTING YOUR SITE ANYWHERE.
  -- ============================================================
  admin_secret constant text := ',VKLH5V+aq&Q5P/';

  m           public.market;
  b           record;
  winners     int := 0;
  losers      int := 0;
  total_paid  numeric := 0;
begin
  if admin_password is null or admin_password <> admin_secret then
    raise exception 'Invalid admin password';
  end if;

  if outcome not in ('yes', 'no') then
    raise exception 'Outcome must be yes or no';
  end if;

  select * into m from public.market where id = 1 for update;

  if m.settled_outcome is not null then
    raise exception 'Market already settled';
  end if;

  for b in select * from public.bets where resolved is null loop
    if b.side = outcome then
      update public.players
        set balance = balance + (b.stake * b.odds)
        where user_id = b.user_id;

      update public.bets
        set resolved = 'won', payout = b.stake * b.odds
        where id = b.id;

      winners := winners + 1;
      total_paid := total_paid + (b.stake * b.odds);
    else
      update public.bets
        set resolved = 'lost', payout = 0
        where id = b.id;

      losers := losers + 1;
    end if;
  end loop;

  update public.market
    set settled_outcome = outcome, settled_at = now()
    where id = 1;

  return jsonb_build_object(
    'outcome', outcome,
    'winners', winners,
    'losers', losers,
    'total_paid', total_paid
  );
end;
$$;

-- Reset the market. Password-gated. Nukes all bets and balances, resets pools.
create or replace function public.reset_market(admin_password text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_secret constant text := ',VKLH5V+aq&Q5P/';
begin
  if admin_password is null or admin_password <> admin_secret then
    raise exception 'Invalid admin password';
  end if;

  delete from public.bets;
  update public.players set balance = 1000;
  update public.market
    set pool_yes = 7719,
        pool_no = 4731,
        settled_outcome = null,
        settled_at = null
    where id = 1;
end;
$$;

-- Grant execute on functions to the authenticated role.
grant execute on function public.ensure_player()              to authenticated;
grant execute on function public.place_bet(text, numeric)     to authenticated;
grant execute on function public.settle_market(text, text)    to authenticated;
grant execute on function public.reset_market(text)           to authenticated;
