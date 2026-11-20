begin;
create table if not exists public.ken_product_costs (
  product_id bigint primary key,
  cost numeric(12,2) not null check (cost>=0),
  fee_percent numeric(5,2) not null check (fee_percent between 0 and 100),
  fixed_fee numeric(12,2) not null check (fixed_fee>=0)
);
create table if not exists public.ken_product_history (
  id bigint generated always as identity primary key,
  product_id bigint not null,
  changed_at timestamptz not null default now(),
  before_value jsonb,
  after_value jsonb
);
create index if not exists ken_product_history_latest on public.ken_product_history(id desc);
alter table public.ken_product_costs enable row level security;
alter table public.ken_product_history enable row level security;
revoke all on public.ken_product_costs, public.ken_product_history from public, anon, authenticated;
grant select, insert, update on public.ken_product_costs to authenticated;
grant select on public.ken_product_history to authenticated;
create policy ken_costs_admin on public.ken_product_costs for all to authenticated
  using ((select auth.jwt()->'app_metadata'->'kenstore_admin')='true'::jsonb)
  with check ((select auth.jwt()->'app_metadata'->'kenstore_admin')='true'::jsonb);
create policy ken_history_admin on public.ken_product_history for select to authenticated
  using ((select auth.jwt()->'app_metadata'->'kenstore_admin')='true'::jsonb);

create or replace function public.ken_record_product_history()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.ken_product_history(product_id,before_value,after_value)
  with snapshots as (
    select 1 as version, value from jsonb_array_elements(old.products)
    union all
    select 2, value from jsonb_array_elements(new.products)
  ), fields as (
    select version, value->>'id' as product_id,
      jsonb_build_object('n',value->'n','p',value->'p','po',value->'po','st',value->'st',
        'paused',value->'paused','promotion',value->'promotion') as summary
    from snapshots
  )
  select coalesce(a.product_id,b.product_id)::bigint,a.summary,b.summary
  from (select * from fields where version=1) a
  full join (select * from fields where version=2) b using (product_id)
  where a.summary is distinct from b.summary;
  return new;
end;
$$;
revoke all on function public.ken_record_product_history() from public;
create trigger ken_record_product_history after update of products on public.store_catalog
  for each row when (old.products is distinct from new.products) execute function public.ken_record_product_history();

create or replace function public.ken_effective_price(product jsonb, instant timestamptz)
returns numeric language plpgsql stable set search_path='' as $$
declare
  regular numeric;
  discounted numeric;
  starts timestamptz;
  ends timestamptz;
begin
  regular := (product->>'p')::numeric;
  begin
    discounted := (product->'promotion'->>'price')::numeric;
    starts := (product->'promotion'->>'start')::timestamptz;
    ends := (product->'promotion'->>'end')::timestamptz;
    if discounted > 0 and discounted < regular and instant >= starts and instant < ends then
      return discounted;
    end if;
  exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then
    return regular;
  end;
  return regular;
end;
$$;
alter policy ken_orders_create on public.orders with check (
  customer_id = (select auth.uid())
  and email = (select auth.jwt()->>'email')
  and status='pendiente' and coalesce(reason,'')=''
  and price>=0
  and exists (
    select 1 from public.store_catalog catalog
    cross join lateral jsonb_array_elements(catalog.products) as product(value)
    where catalog.id=1 and coalesce(catalog.site->>'maint','')=''
      and product.value->>'id'=orders.pid::text
      and product.value->>'n'=orders.pn and product.value->>'c'=orders.cat
      and coalesce(product.value->>'s','')=coalesce(orders.sub,'')
      and public.ken_effective_price(product.value,now())=orders.price
      and product.value->>'st' is distinct from '0'
  )
);
commit;
