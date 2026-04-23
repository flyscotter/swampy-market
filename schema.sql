-- ============================================================================
-- Swampy Prediction Market — v3 Schema (Google OAuth + leaderboard)
-- ============================================================================
-- This is a FRESH START schema. It drops all v2 tables and rebuilds.
-- If you have anonymous user data you want to keep, DO NOT RUN THIS.
-- Paste this entire file into Supabase SQL Editor and click Run.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Nuke v2 tables (fresh start)
-- ----------------------------------------------------------------------------
drop function if exists public.settle_market(text, text);
drop function if exists public.reset_market(text);
drop function if exists public.place_bet(text, numeric);
drop function if exists public.ensure_player();
drop function if exists public.get_leaderboard(int);

drop table if exists public.bets cascade;
drop table if exists public.players cascade;
drop table if exists public.market cascade;

-- Also clear Supabase Auth users so everyone starts fresh.
-- This deletes all existing user accounts (anonymous and otherwise).
delete from auth.users;

-- ----------------------------------------------------------------------------
-- 1. Tables
-- ----------------------------------------------------------------------------

create table public.market (
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

create table public.players (
  user_id              uuid primary key references auth.users(id) on delete cascade,
  balance              numeric not null default 1000,
  display_name         text not null,
  avatar_url           text,
  email                text,
  show_on_leaderboard  boolean not null default true,
  total_wagered        numeric not null default 0,
  total_won            numeric not null default 0,
  bets_placed          int not null default 0,
  bets_won             int not null default 0,
  bets_lost            int not null default 0,
  created_at           timestamptz not null default now()
);

create index players_leaderboard_idx on public.players(show_on_leaderboard, balance desc);

create table public.bets (
  id               bigserial primary key,
  user_id          uuid not null references auth.users(id) on delete cascade,
  display_name     text not null,
  side             text not null check (side in ('yes', 'no')),
  stake            numeric not null check (stake > 0),
  odds             numeric not null check (odds > 0),
  resolved         text check (resolved in ('won', 'lost')) default null,
  payout           numeric default null,
  created_at       timestamptz not null default now()
);

create index bets_user_id_idx on public.bets(user_id);
create index bets_created_at_idx on public.bets(created_at desc);

insert into public.market (id, question)
values (1, 'Will Swampy take down the Elite Four by the end of the week?');

-- ----------------------------------------------------------------------------
-- 2. Row Level Security
-- ----------------------------------------------------------------------------

alter table public.market  enable row level security;
alter table public.players enable row level security;
alter table public.bets    enable row level security;

-- Market is fully readable.
create policy "market_read_all" on public.market for select using (true);

-- Players: everyone can see display_name, avatar, balance, stats, but only
-- for players who haven't opted out of the leaderboard — EXCEPT you can
-- always see your own row.
create policy "players_read_public" on public.players for select
  using (show_on_leaderboard = true or user_id = auth.uid());

-- Bets: readable by everyone (for global feed / leaderboard drill-down).
create policy "bets_read_all" on public.bets for select using (true);

-- No direct insert/update/delete. All writes go through functions.

-- ----------------------------------------------------------------------------
-- 3. Realtime
-- ----------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'market') then
    alter publication supabase_realtime add table public.market;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'players') then
    alter publication supabase_realtime add table public.players;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'bets') then
    alter publication supabase_realtime add table public.bets;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 4. Functions
-- ----------------------------------------------------------------------------

-- Create or fetch player row. Pulls display_name from Google OAuth metadata.
create or replace function public.ensure_player()
returns public.players
language plpgsql
security definer
set search_path = public
as $$
declare
  p          public.players;
  user_data  auth.users;
  name_val   text;
  email_val  text;
  avatar_val text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select * into user_data from auth.users where id = auth.uid();

  -- Pull Google identity fields from raw_user_meta_data.
  name_val   := coalesce(
    user_data.raw_user_meta_data->>'full_name',
    user_data.raw_user_meta_data->>'name',
    split_part(user_data.email, '@', 1),
    'Player'
  );
  email_val  := user_data.email;
  avatar_val := user_data.raw_user_meta_data->>'avatar_url';

  insert into public.players (user_id, display_name, email, avatar_url)
  values (auth.uid(), name_val, email_val, avatar_val)
  on conflict (user_id) do update
    set display_name = coalesce(public.players.display_name, excluded.display_name),
        email        = excluded.email,
        avatar_url   = excluded.avatar_url;

  select * into p from public.players where user_id = auth.uid();
  return p;
end;
$$;

-- Toggle leaderboard visibility for the current user.
create or replace function public.set_leaderboard_visibility(visible boolean)
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

  update public.players
    set show_on_leaderboard = visible
    where user_id = auth.uid()
    returning * into p;

  return p;
end;
$$;

-- Update display name for the current user.
create or replace function public.set_display_name(new_name text)
returns public.players
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players;
  trimmed text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  trimmed := trim(new_name);

  if trimmed is null or length(trimmed) < 1 or length(trimmed) > 40 then
    raise exception 'Display name must be 1-40 characters';
  end if;

  update public.players
    set display_name = trimmed
    where user_id = auth.uid()
    returning * into p;

  -- Also update their display name on existing bets so the feed/leaderboard
  -- reflects their current name.
  update public.bets set display_name = trimmed where user_id = auth.uid();

  return p;
end;
$$;

-- Place a bet atomically.
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

  select * into m from public.market where id = 1 for update;

  if m.settled_outcome is not null then
    raise exception 'Market already settled';
  end if;

  select * into p from public.players where user_id = auth.uid() for update;

  if p is null then
    raise exception 'Player not initialized — reload the page';
  end if;

  if p.balance < bet_stake then
    raise exception 'Insufficient balance (have %, need %)', p.balance, bet_stake;
  end if;

  if bet_side = 'yes' then
    new_odds := ((m.pool_yes + m.pool_no) / m.pool_yes) * m.house_edge;
  else
    new_odds := ((m.pool_yes + m.pool_no) / m.pool_no) * m.house_edge;
  end if;

  update public.players
    set balance = balance - bet_stake,
        total_wagered = total_wagered + bet_stake,
        bets_placed = bets_placed + 1
    where user_id = auth.uid();

  insert into public.bets (user_id, display_name, side, stake, odds)
  values (auth.uid(), p.display_name, bet_side, bet_stake, new_odds)
  returning * into new_bet;

  if bet_side = 'yes' then
    update public.market set pool_yes = pool_yes + bet_stake where id = 1;
  else
    update public.market set pool_no  = pool_no  + bet_stake where id = 1;
  end if;

  return new_bet;
end;
$$;

-- Settle the market (admin only).
create or replace function public.settle_market(outcome text, admin_password text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- ============================================================
  -- CHANGE THIS PASSWORD BEFORE DEPLOYING.
  -- ============================================================
  admin_secret constant text := ',VKLH5V+aq&Q5P/';

  m           public.market;
  b           record;
  winners     int := 0;
  losers      int := 0;
  total_paid  numeric := 0;
  payout_val  numeric;
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
      payout_val := b.stake * b.odds;

      update public.players
        set balance = balance + payout_val,
            total_won = total_won + payout_val,
            bets_won = bets_won + 1
        where user_id = b.user_id;

      update public.bets
        set resolved = 'won', payout = payout_val
        where id = b.id;

      winners := winners + 1;
      total_paid := total_paid + payout_val;
    else
      update public.players
        set bets_lost = bets_lost + 1
        where user_id = b.user_id;

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

-- Reset the market (admin only). Nukes bets, resets balances and pools.
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
  update public.players set
    balance = 1000,
    total_wagered = 0,
    total_won = 0,
    bets_placed = 0,
    bets_won = 0,
    bets_lost = 0;
  update public.market
    set pool_yes = 7719,
        pool_no = 4731,
        settled_outcome = null,
        settled_at = null
    where id = 1;
end;
$$;

-- Grants.
grant execute on function public.ensure_player()                       to authenticated;
grant execute on function public.place_bet(text, numeric)              to authenticated;
grant execute on function public.settle_market(text, text)             to authenticated;
grant execute on function public.reset_market(text)                    to authenticated;
grant execute on function public.set_leaderboard_visibility(boolean)   to authenticated;
grant execute on function public.set_display_name(text)                to authenticated;
