-- ============================================================================
-- v4.2 Migration — FungBucks Injection Mechanisms
-- ============================================================================
-- Safe to run on top of v4.1 schema. Does NOT drop any tables or data.
-- Adds: claim tracking columns, UBI claim function, emergency reset function,
-- admin grant function.
--
-- Paste into Supabase SQL Editor and click Run.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Add tracking columns to players
-- ----------------------------------------------------------------------------
alter table public.players add column if not exists last_ubi_claim   timestamptz;
alter table public.players add column if not exists last_reset_claim timestamptz;
alter table public.players add column if not exists total_ubi_claimed numeric not null default 0;
alter table public.players add column if not exists admin_grants_received numeric not null default 0;

-- ----------------------------------------------------------------------------
-- 2. UBI claim function
-- ----------------------------------------------------------------------------
-- User claims Ƒ200 per calendar week. "Week" = rolling 7 days from last claim.
create or replace function public.claim_ubi()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- ============================================================
  -- TUNE THESE VALUES
  -- ============================================================
  ubi_amount  constant numeric  := 200;
  ubi_period  constant interval := '7 days';
  -- ============================================================

  p             public.players;
  next_claim    timestamptz;
  seconds_left  int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select * into p from public.players where user_id = auth.uid() for update;
  if p is null then
    raise exception 'Player not initialized — reload';
  end if;

  if p.last_ubi_claim is not null and p.last_ubi_claim + ubi_period > now() then
    next_claim   := p.last_ubi_claim + ubi_period;
    seconds_left := extract(epoch from (next_claim - now()))::int;
    raise exception 'Next UBI available in % hours', round(seconds_left / 3600.0, 1);
  end if;

  update public.players
    set balance = balance + ubi_amount,
        last_ubi_claim = now(),
        total_ubi_claimed = total_ubi_claimed + ubi_amount
    where user_id = auth.uid();

  return jsonb_build_object(
    'claimed', ubi_amount,
    'new_balance', p.balance + ubi_amount,
    'next_claim_at', (now() + ubi_period)
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. Emergency reset function
-- ----------------------------------------------------------------------------
-- If balance < Ƒ50, user can claim a top-up to Ƒ500. Limited to once per 7 days.
create or replace function public.claim_emergency_reset()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- ============================================================
  -- TUNE THESE VALUES
  -- ============================================================
  reset_threshold  constant numeric  := 50;
  reset_to         constant numeric  := 500;
  reset_period     constant interval := '7 days';
  -- ============================================================

  p             public.players;
  top_up_amount numeric;
  next_claim    timestamptz;
  seconds_left  int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select * into p from public.players where user_id = auth.uid() for update;
  if p is null then
    raise exception 'Player not initialized — reload';
  end if;

  if p.balance >= reset_threshold then
    raise exception 'Emergency reset only available when balance is below Ƒ% (you have Ƒ%)', reset_threshold, p.balance;
  end if;

  if p.last_reset_claim is not null and p.last_reset_claim + reset_period > now() then
    next_claim   := p.last_reset_claim + reset_period;
    seconds_left := extract(epoch from (next_claim - now()))::int;
    raise exception 'Next emergency reset available in % hours', round(seconds_left / 3600.0, 1);
  end if;

  top_up_amount := reset_to - p.balance;

  update public.players
    set balance = reset_to,
        last_reset_claim = now()
    where user_id = auth.uid();

  return jsonb_build_object(
    'topped_up_by', top_up_amount,
    'new_balance', reset_to,
    'next_reset_at', (now() + reset_period)
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Admin grant function
-- ----------------------------------------------------------------------------
-- Admin can top up a specific user by any amount. Password-gated.
-- Find target_user_id via Supabase Table Editor → players → copy user_id.
create or replace function public.admin_grant(
  target_user_id uuid,
  amount numeric,
  admin_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_secret constant text := ',VKLH5V+aq&Q5P/';
  p            public.players;
begin
  if admin_password is null or admin_password <> admin_secret then
    raise exception 'Invalid admin password';
  end if;

  if amount is null or amount = 0 then
    raise exception 'Amount cannot be zero';
  end if;

  select * into p from public.players where user_id = target_user_id for update;
  if p is null then
    raise exception 'Target player not found';
  end if;

  update public.players
    set balance = balance + amount,
        admin_grants_received = admin_grants_received + amount
    where user_id = target_user_id;

  return jsonb_build_object(
    'target', p.display_name,
    'amount', amount,
    'new_balance', p.balance + amount
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Grants
-- ----------------------------------------------------------------------------
grant execute on function public.claim_ubi()                                 to authenticated;
grant execute on function public.claim_emergency_reset()                     to authenticated;
grant execute on function public.admin_grant(uuid, numeric, text)            to authenticated;
