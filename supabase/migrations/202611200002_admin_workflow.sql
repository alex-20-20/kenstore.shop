begin;
alter table public.orders
  add column if not exists paid_at timestamptz,
  add column if not exists activated_at timestamptz,
  add column if not exists expires_at timestamptz,
  add column if not exists access_duration jsonb;
alter table public.claims
  add column if not exists workflow_status text not null default 'nuevo' check (workflow_status in ('nuevo','en_atencion','resuelto')),
  add column if not exists internal_note text not null default '' check (char_length(internal_note)<=2000);

grant update (workflow_status, internal_note) on public.claims to authenticated;
drop policy if exists ken_claims_workflow on public.claims;
create policy ken_claims_workflow on public.claims for update to authenticated
  using ((select auth.jwt()->'app_metadata'->'kenstore_admin')='true'::jsonb)
  with check ((select auth.jwt()->'app_metadata'->'kenstore_admin')='true'::jsonb);

drop policy if exists ken_orders_unpaused on public.orders;
create policy ken_orders_unpaused on public.orders as restrictive for insert to authenticated
  with check (exists (
    select 1 from public.store_catalog c
    cross join lateral jsonb_array_elements(c.products) as p(value)
    where c.id=1 and p.value->>'id'=orders.pid::text
      and p.value->>'paused' is distinct from 'true'
  ));

create or replace function public.ken_order_access_dates()
returns trigger language plpgsql set search_path='' as $$
declare
  duration jsonb;
  quantity integer;
  period interval;
begin
  if tg_op='INSERT' then
    select p.value->'accessDuration' into new.access_duration
    from public.store_catalog c cross join lateral jsonb_array_elements(c.products) as p(value)
    where c.id=1 and p.value->>'id'=new.pid::text;
    new.paid_at := null;
    new.activated_at := null;
    new.expires_at := null;
    return new;
  end if;
  if new.paid_at is null and new.status in ('aceptado','en_proceso','entregado') then
    new.paid_at := now();
  end if;
  if new.status='entregado' and new.activated_at is null then
    new.activated_at := now();
    duration := new.access_duration;
    if duration is null then
      select p.value->'accessDuration' into duration
      from public.store_catalog c cross join lateral jsonb_array_elements(c.products) as p(value)
      where c.id=1 and p.value->>'id'=new.pid::text;
    end if;
    if duration->>'amount' ~ '^[0-9]{1,4}$' then
      quantity := (duration->>'amount')::integer;
      period := case duration->>'unit'
        when 'days' then make_interval(days=>quantity)
        when 'months' then make_interval(months=>quantity)
        when 'years' then make_interval(years=>quantity)
      end;
      new.expires_at := ((new.activated_at at time zone 'America/Lima')+period) at time zone 'America/Lima';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.ken_order_access_dates() from public;
drop trigger if exists ken_order_access_dates on public.orders;
create trigger ken_order_access_dates before insert or update of status on public.orders
  for each row execute function public.ken_order_access_dates();
commit;
