-- ============================================================================
-- Swampy Prediction Market — v4 Schema (Multi-market platform)
-- ============================================================================
-- Upgrade from v3. Adds:
--   1. Multiple markets instead of a single market row
--   2. User-created markets with creator-seeded pools
--   3. Creator-proposed resolution with admin override
--   4. Yes/No/Cancelled resolution types
--   5. Close dates enforced at the database level
--   6. Disputes table for flagging bad resolutions
--
-- This migration PRESERVES existing player accounts and balances but WIPES
-- the single Swampy market and its bets. If you want to keep them, don't run
-- this.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Drop v3 single-market structures
-- ----------------------------------------------------------------------------
drop function if exists public.place_bet(text, numeric);
drop function if exists public.settle_market(text, text);
drop function if exists public.reset_market(text);

drop table if exists public.bets cascade;
drop table if exists public.market cascade;

-- Keep players table, but add some stats columns if they don't exist.
alter table public.players add column if not exists markets_created int not null default 0;

-- Reset player stats since markets are being wiped.
update public.players set
  total_wagered = 0,
  total_won = 0,
  bets_placed = 0,
  bets_won = 0,
  bets_lost = 0;

-- ----------------------------------------------------------------------------
-- 1. Tables
-- ----------------------------------------------------------------------------

-- Multi-market table.
create table public.markets (
  id                  bigserial primary key,
  creator_id          uuid not null references auth.users(id) on delete set null,
  creator_name        text not null,
  question            text not null check (length(trim(question)) between 10 and 200),
  description         text check (length(description) <= 1000),
  pool_yes            numeric not null default 0 check (pool_yes >= 0),
  pool_no             numeric not null default 0 check (pool_no >= 0),
  house_edge          numeric not null default 0.95,
  close_at            timestamptz not null,
  status              text not null default 'open'
                      check (status in ('open', 'pending_resolution', 'settled', 'cancelled')),
  proposed_outcome    text check (proposed_outcome in ('yes', 'no', 'cancelled')) default null,
  proposed_by         uuid references auth.users(id) on delete set null,
  proposed_at         timestamptz,
  settled_outcome     text check (settled_outcome in ('yes', 'no', 'cancelled')) default null,
  settled_at          timestamptz,
  settled_by          uuid references auth.users(id) on delete set null,
  created_at          timestamptz not null default now()
);

create index markets_status_idx on public.markets(status);
create index markets_close_at_idx on public.markets(close_at);
create index markets_creator_idx on public.markets(creator_id);

-- Bets now reference a specific market.
create table public.bets (
  id               bigserial primary key,
  market_id        bigint not null references public.markets(id) on delete cascade,
  user_id          uuid not null references auth.users(id) on delete cascade,
  display_name     text not null,
  side             text not null check (side in ('yes', 'no')),
  stake            numeric not null check (stake > 0),
  odds             numeric not null check (odds > 0),
  resolved         text check (resolved in ('won', 'lost', 'refunded')) default null,
  payout           numeric default null,
  created_at       timestamptz not null default now()
);

create index bets_market_idx on public.bets(market_id);
create index bets_user_idx on public.bets(user_id);
create index bets_created_at_idx on public.bets(created_at desc);

-- Disputes raised against a proposed resolution.
create table public.disputes (
  id               bigserial primary key,
  market_id        bigint not null references public.markets(id) on delete cascade,
  user_id          uuid not null references auth.users(id) on delete cascade,
  display_name     text not null,
  reason           text not null check (length(trim(reason)) between 5 and 500),
  created_at       timestamptz not null default now()
);

create index disputes_market_idx on public.disputes(market_id);

-- ----------------------------------------------------------------------------
-- 2. Row Level Security
-- ----------------------------------------------------------------------------

alter table public.markets  enable row level security;
alter table public.bets     enable row level security;
alter table public.disputes enable row level security;

-- Public read on all market-related data.
create policy "markets_read_all"  on public.markets  for select using (true);
create policy "bets_read_all"     on public.bets     for select using (true);
create policy "disputes_read_all" on public.disputes for select using (true);

-- Writes go through functions only.

-- ----------------------------------------------------------------------------
-- 3. Realtime
-- ----------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'markets') then
    alter publication supabase_realtime add table public.markets;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'bets') then
    alter publication supabase_realtime add table public.bets;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'disputes') then
    alter publication supabase_realtime add table public.disputes;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 4. Functions
-- ----------------------------------------------------------------------------

-- Create a new market. Creator puts up their own seed money.
-- Minimum seed is 500 FungBucks total, split as 250/250 default, or custom.
create or replace function public.create_market(
  q text,
  description_text text,
  seed_yes numeric,
  seed_no numeric,
  close_at_param timestamptz
)
returns public.markets
language plpgsql
security definer
set search_path = public
as $$
declare
  p       public.players;
  m       public.markets;
  total   numeric;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if q is null or length(trim(q)) < 10 or length(trim(q)) > 200 then
    raise exception 'Question must be 10-200 characters';
  end if;

  if description_text is not null and length(description_text) > 1000 then
    raise exception 'Description must be under 1000 characters';
  end if;

  if seed_yes is null or seed_no is null or seed_yes <= 0 or seed_no <= 0 then
    raise exception 'Both seed amounts must be positive';
  end if;

  total := seed_yes + seed_no;
  if total < 500 then
    raise exception 'Total seed must be at least Ƒ500 (you entered Ƒ%)', total;
  end if;

  if close_at_param is null or close_at_param <= now() + interval '5 minutes' then
    raise exception 'Close date must be at least 5 minutes in the future';
  end if;

  if close_at_param > now() + interval '90 days' then
    raise exception 'Close date cannot be more than 90 days out';
  end if;

  select * into p from public.players where user_id = auth.uid() for update;
  if p is null then raise exception 'Player not initialized — reload'; end if;
  if p.balance < total then
    raise exception 'Insufficient balance to seed: have Ƒ%, need Ƒ%', p.balance, total;
  end if;

  -- Deduct seed from creator balance.
  update public.players
    set balance = balance - total,
        markets_created = markets_created + 1
    where user_id = auth.uid();

  insert into public.markets (creator_id, creator_name, question, description, pool_yes, pool_no, close_at)
  values (auth.uid(), p.display_name, trim(q), nullif(trim(description_text), ''), seed_yes, seed_no, close_at_param)
  returning * into m;

  return m;
end;
$$;

-- Place a bet on a specific market.
create or replace function public.place_bet(
  target_market_id bigint,
  bet_side text,
  bet_stake numeric
)
returns public.bets
language plpgsql
security definer
set search_path = public
as $$
declare
  m         public.markets;
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

  select * into m from public.markets where id = target_market_id for update;
  if m is null then
    raise exception 'Market not found';
  end if;

  if m.status <> 'open' then
    raise exception 'Market is not open for betting (status: %)', m.status;
  end if;

  if now() >= m.close_at then
    raise exception 'Market has closed';
  end if;

  select * into p from public.players where user_id = auth.uid() for update;
  if p is null then
    raise exception 'Player not initialized — reload';
  end if;
  if p.balance < bet_stake then
    raise exception 'Insufficient balance (have Ƒ%, need Ƒ%)', p.balance, bet_stake;
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

  insert into public.bets (market_id, user_id, display_name, side, stake, odds)
  values (target_market_id, auth.uid(), p.display_name, bet_side, bet_stake, new_odds)
  returning * into new_bet;

  if bet_side = 'yes' then
    update public.markets set pool_yes = pool_yes + bet_stake where id = target_market_id;
  else
    update public.markets set pool_no  = pool_no  + bet_stake where id = target_market_id;
  end if;

  return new_bet;
end;
$$;

-- Creator proposes a resolution. Market enters pending_resolution state.
-- Does NOT pay out yet — gives disputers a window to object.
create or replace function public.propose_resolution(
  target_market_id bigint,
  outcome text
)
returns public.markets
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.markets;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if outcome not in ('yes', 'no', 'cancelled') then
    raise exception 'Outcome must be yes, no, or cancelled';
  end if;

  select * into m from public.markets where id = target_market_id for update;
  if m is null then raise exception 'Market not found'; end if;

  if m.creator_id <> auth.uid() then
    raise exception 'Only the market creator can propose a resolution';
  end if;

  if m.status not in ('open', 'pending_resolution') then
    raise exception 'Market is already settled or cancelled';
  end if;

  if now() < m.close_at and outcome <> 'cancelled' then
    raise exception 'Cannot resolve before close date (only cancel allowed)';
  end if;

  update public.markets
    set status = 'pending_resolution',
        proposed_outcome = outcome,
        proposed_by = auth.uid(),
        proposed_at = now()
    where id = target_market_id
    returning * into m;

  return m;
end;
$$;

-- Creator confirms their own proposed resolution after a cooling period
-- (or admin can skip the wait). Pays out winners.
-- Cooling period: 1 hour from proposal, unless overridden by admin.
create or replace function public.confirm_resolution(
  target_market_id bigint,
  admin_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_secret constant text := 'swampy-admin-CHANGE-ME';
  cooling_period constant interval := '1 hour';

  m           public.markets;
  b           record;
  winners     int := 0;
  losers      int := 0;
  refunded    int := 0;
  total_paid  numeric := 0;
  payout_val  numeric;
  is_admin    boolean;
  outcome     text;
begin
  is_admin := (admin_password is not null and admin_password = admin_secret);

  if auth.uid() is null and not is_admin then
    raise exception 'Not authenticated';
  end if;

  select * into m from public.markets where id = target_market_id for update;
  if m is null then raise exception 'Market not found'; end if;

  if m.status <> 'pending_resolution' then
    raise exception 'Market is not pending resolution (status: %)', m.status;
  end if;

  -- Only creator or admin can confirm.
  if m.creator_id <> auth.uid() and not is_admin then
    raise exception 'Only the creator or admin can confirm the resolution';
  end if;

  -- Creator must wait out the cooling period; admin can skip.
  if not is_admin and now() < m.proposed_at + cooling_period then
    raise exception 'Cooling period not over (% left)',
      (m.proposed_at + cooling_period - now())::text;
  end if;

  outcome := m.proposed_outcome;

  for b in select * from public.bets where market_id = target_market_id and resolved is null loop
    if outcome = 'cancelled' then
      -- Refund every bet.
      update public.players set balance = balance + b.stake where user_id = b.user_id;
      update public.bets set resolved = 'refunded', payout = b.stake where id = b.id;
      refunded := refunded + 1;
    elsif b.side = outcome then
      payout_val := b.stake * b.odds;
      update public.players
        set balance = balance + payout_val,
            total_won = total_won + payout_val,
            bets_won = bets_won + 1
        where user_id = b.user_id;
      update public.bets set resolved = 'won', payout = payout_val where id = b.id;
      winners := winners + 1;
      total_paid := total_paid + payout_val;
    else
      update public.players set bets_lost = bets_lost + 1 where user_id = b.user_id;
      update public.bets set resolved = 'lost', payout = 0 where id = b.id;
      losers := losers + 1;
    end if;
  end loop;

  -- If cancelled, also refund the creator's initial seed.
  if outcome = 'cancelled' then
    update public.players
      set balance = balance + (m.pool_yes + m.pool_no) - (
        select coalesce(sum(stake), 0) from public.bets where market_id = target_market_id
      )
      where user_id = m.creator_id;
  end if;

  update public.markets
    set status = 'settled',
        settled_outcome = outcome,
        settled_at = now(),
        settled_by = coalesce(auth.uid(), m.creator_id)
    where id = target_market_id;

  return jsonb_build_object(
    'outcome', outcome,
    'winners', winners,
    'losers', losers,
    'refunded', refunded,
    'total_paid', total_paid
  );
end;
$$;

-- Admin can override a pending resolution with a different outcome.
create or replace function public.admin_override_resolution(
  target_market_id bigint,
  outcome text,
  admin_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_secret constant text := 'swampy-admin-CHANGE-ME';

  m           public.markets;
  b           record;
  winners     int := 0;
  losers      int := 0;
  refunded    int := 0;
  total_paid  numeric := 0;
  payout_val  numeric;
begin
  if admin_password is null or admin_password <> admin_secret then
    raise exception 'Invalid admin password';
  end if;

  if outcome not in ('yes', 'no', 'cancelled') then
    raise exception 'Outcome must be yes, no, or cancelled';
  end if;

  select * into m from public.markets where id = target_market_id for update;
  if m is null then raise exception 'Market not found'; end if;

  if m.status = 'settled' then
    raise exception 'Market already settled — cannot override';
  end if;

  for b in select * from public.bets where market_id = target_market_id and resolved is null loop
    if outcome = 'cancelled' then
      update public.players set balance = balance + b.stake where user_id = b.user_id;
      update public.bets set resolved = 'refunded', payout = b.stake where id = b.id;
      refunded := refunded + 1;
    elsif b.side = outcome then
      payout_val := b.stake * b.odds;
      update public.players
        set balance = balance + payout_val,
            total_won = total_won + payout_val,
            bets_won = bets_won + 1
        where user_id = b.user_id;
      update public.bets set resolved = 'won', payout = payout_val where id = b.id;
      winners := winners + 1;
      total_paid := total_paid + payout_val;
    else
      update public.players set bets_lost = bets_lost + 1 where user_id = b.user_id;
      update public.bets set resolved = 'lost', payout = 0 where id = b.id;
      losers := losers + 1;
    end if;
  end loop;

  if outcome = 'cancelled' then
    update public.players
      set balance = balance + (m.pool_yes + m.pool_no) - (
        select coalesce(sum(stake), 0) from public.bets where market_id = target_market_id
      )
      where user_id = m.creator_id;
  end if;

  update public.markets
    set status = 'settled',
        settled_outcome = outcome,
        settled_at = now(),
        settled_by = auth.uid()
    where id = target_market_id;

  return jsonb_build_object(
    'outcome', outcome,
    'winners', winners,
    'losers', losers,
    'refunded', refunded,
    'total_paid', total_paid
  );
end;
$$;

-- Anyone signed in can raise a dispute on a pending resolution.
create or replace function public.raise_dispute(
  target_market_id bigint,
  reason_text text
)
returns public.disputes
language plpgsql
security definer
set search_path = public
as $$
declare
  m  public.markets;
  p  public.players;
  d  public.disputes;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if reason_text is null or length(trim(reason_text)) < 5 then
    raise exception 'Dispute reason must be at least 5 characters';
  end if;
  if length(trim(reason_text)) > 500 then
    raise exception 'Dispute reason must be under 500 characters';
  end if;

  select * into m from public.markets where id = target_market_id;
  if m is null then raise exception 'Market not found'; end if;
  if m.status <> 'pending_resolution' then
    raise exception 'Can only dispute markets with a pending resolution';
  end if;

  select * into p from public.players where user_id = auth.uid();
  if p is null then raise exception 'Player not initialized — reload'; end if;

  insert into public.disputes (market_id, user_id, display_name, reason)
  values (target_market_id, auth.uid(), p.display_name, trim(reason_text))
  returning * into d;

  return d;
end;
$$;

-- Grants.
grant execute on function public.create_market(text, text, numeric, numeric, timestamptz) to authenticated;
grant execute on function public.place_bet(bigint, text, numeric)                           to authenticated;
grant execute on function public.propose_resolution(bigint, text)                           to authenticated;
grant execute on function public.confirm_resolution(bigint, text)                           to authenticated;
grant execute on function public.admin_override_resolution(bigint, text, text)              to authenticated;
grant execute on function public.raise_dispute(bigint, text)                                to authenticated;
