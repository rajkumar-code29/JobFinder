-- Buying credits: Stripe Checkout on the website and Android, Apple In-App Purchase on iPhone.
-- The payments Edge Functions call these with the service key after checking the payment with Stripe or Apple.
-- Each payment is granted once (unique source + ref); a refund takes the credits back, never below zero.

create table if not exists purchases (
  id             bigserial primary key,
  user_id        uuid references auth.users(id) on delete set null,   -- kept (anonymised) for the accounts
  source         text not null check (source in ('stripe', 'apple')),
  ref            text not null,          -- Stripe Checkout session id / Apple transaction id
  payment_intent text,                   -- Stripe, to match refunds
  pack           text not null,
  credits        int  not null check (credits > 0),
  amount         int,                    -- minor units (pence)
  currency       text,
  environment    text not null default 'production',   -- Apple sandbox purchases (TestFlight, App Review) say so
  status         text not null default 'paid' check (status in ('paid', 'refunded')),
  created_at     timestamptz not null default now(),
  refunded_at    timestamptz,
  unique (source, ref)
);
create index if not exists purchases_user_idx on purchases(user_id, created_at desc);
create index if not exists purchases_intent_idx on purchases(payment_intent) where payment_intent is not null;
alter table purchases enable row level security;
drop policy if exists "own purchases read" on purchases;
create policy "own purchases read" on purchases for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on purchases from anon, authenticated;
grant select on purchases to authenticated;

create or replace function public.grant_purchase(p_user uuid, p_source text, p_ref text, p_pack text, p_credits int,
                                                 p_amount int default null, p_currency text default null,
                                                 p_payment_intent text default null,
                                                 p_environment text default 'production')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id  bigint;
  v_bal int;
begin
  insert into purchases (user_id, source, ref, payment_intent, pack, credits, amount, currency, environment)
  values (p_user, p_source, p_ref, p_payment_intent, p_pack, p_credits, p_amount, lower(p_currency), coalesce(p_environment, 'production'))
  on conflict (source, ref) do nothing
  returning id into v_id;
  if v_id is null then
    select credits into v_bal from accounts where user_id = p_user;
    return jsonb_build_object('granted', false, 'balance', v_bal);  -- already done (webhook retry, second tap)
  end if;
  update accounts set credits = credits + p_credits where user_id = p_user returning credits into v_bal;
  if v_bal is null then
    raise exception 'No account for this purchase';
  end if;
  insert into credit_ledger (user_id, delta, balance_after, reason, note)
  values (p_user, p_credits, v_bal, 'purchase',
          p_credits || ' credits bought' || case when p_source = 'apple' then ' in the App Store' else '' end
          || case when coalesce(p_environment, 'production') <> 'production' then ' (test purchase)' else '' end);
  return jsonb_build_object('granted', true, 'balance', v_bal);
end $$;
revoke all on function public.grant_purchase(uuid, text, text, text, int, int, text, text, text) from public, anon, authenticated;

-- refunds: by Apple transaction / Stripe session, or by Stripe payment intent (charge.refunded)
create or replace function public.refund_purchase(p_source text, p_ref text default null, p_payment_intent text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p     purchases;
  v_bal int;
  v_old int;
begin
  select * into p from purchases
  where source = p_source and status = 'paid'
    and ((p_ref is not null and ref = p_ref) or (p_payment_intent is not null and payment_intent = p_payment_intent))
  for update;
  if not found then
    return jsonb_build_object('refunded', false);
  end if;
  update purchases set status = 'refunded', refunded_at = now() where id = p.id;
  if p.user_id is not null then
    select credits into v_old from accounts where user_id = p.user_id for update;
    update accounts set credits = greatest(credits - p.credits, 0) where user_id = p.user_id returning credits into v_bal;
    insert into credit_ledger (user_id, delta, balance_after, reason, note)
    values (p.user_id, v_bal - v_old, v_bal, 'refund', 'Purchase refunded');
  end if;
  return jsonb_build_object('refunded', true, 'balance', v_bal);
end $$;
revoke all on function public.refund_purchase(text, text, text) from public, anon, authenticated;
