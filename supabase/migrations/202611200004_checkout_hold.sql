begin;
create table public.ken_checkout_holds (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null,
  product_id bigint not null,
  price numeric not null check (price>=0),
  expires_at timestamptz not null,
  order_id text unique references public.orders(id),
  released boolean not null default false
);
create index ken_checkout_holds_product on public.ken_checkout_holds(product_id) where not released;
alter table public.ken_checkout_holds enable row level security;
revoke all on public.ken_checkout_holds from public, anon, authenticated;
alter table public.orders add column stock_committed boolean not null default false;
alter table public.orders add column late_checkout boolean not null default false;

create function public.ken_checkout_available(product bigint, ignore_hold uuid default null)
returns bigint language sql volatile set search_path='' as $$
  select count(*) from public.ken_checkout_holds h
  where h.product_id=product and not h.released and h.id is distinct from ignore_hold
    and (h.order_id is not null or h.expires_at>clock_timestamp())
$$;
revoke all on function public.ken_checkout_available(bigint,uuid) from public, anon, authenticated;

create function public.ken_reserve_checkout(product bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  customer uuid := auth.uid();
  catalog public.store_catalog%rowtype;
  item jsonb;
  hold public.ken_checkout_holds%rowtype;
  instant timestamptz;
  stock integer;
begin
  if customer is null then raise exception 'KEN_LOGIN_REQUIRED'; end if;
  select * into catalog from public.store_catalog where id=1 for update;
  instant := clock_timestamp();
  select value into item from jsonb_array_elements(catalog.products) where value->>'id'=product::text;
  if item is null or item->>'paused'='true' or coalesce(catalog.site->>'maint','')<>''
    or not exists (
      select 1
      from jsonb_array_elements(
        jsonb_build_array(jsonb_build_object('category',item->>'c','subs',
          case when jsonb_typeof(item->'subcategories')='array' and item->'subcategories'<>'[]'::jsonb then item->'subcategories'
          else jsonb_build_array(coalesce(item->>'s','')) end))
        || case when jsonb_typeof(item->'extraCategories')='array' then item->'extraCategories' else '[]'::jsonb end
      ) placement
      cross join lateral jsonb_array_elements(case when jsonb_typeof(placement->'subs')='array' and placement->'subs'<>'[]'::jsonb
        then placement->'subs' else jsonb_build_array(''::text) end) as member(value)
      where not exists (
        select 1 from jsonb_array_elements(case when jsonb_typeof(catalog.site->'hiddenCatalog')='array'
          then catalog.site->'hiddenCatalog' else '[]'::jsonb end) as hidden(value)
        where hidden.value=jsonb_build_array(placement->>'category')
           or hidden.value=jsonb_build_array(to_jsonb(placement->>'category'),member.value)
      )
    ) then raise exception 'KEN_UNAVAILABLE'; end if;

  stock := (item->>'st')::integer;
  select * into hold from public.ken_checkout_holds
    where product_id=product and customer_id=customer and expires_at>instant and order_id is null and not released limit 1;
  if stock is not null and stock<=public.ken_checkout_available(product,hold.id) then
    raise exception 'KEN_OUT_OF_STOCK';
  end if;
  if hold.id is null then
    insert into public.ken_checkout_holds(customer_id,product_id,price,expires_at)
      values (customer,product,public.ken_effective_price(item,instant),instant+interval '15 minutes') returning * into hold;
  end if;
  return jsonb_build_object('id',hold.id,'price',hold.price,'expires_at',hold.expires_at,'server_time',instant);
end
$$;
revoke all on function public.ken_reserve_checkout(bigint) from public, anon;
grant execute on function public.ken_reserve_checkout(bigint) to authenticated;

create function public.ken_submit_checkout(hold_id uuid, order_ref text, customer_name text, phone text, delivery_data text, delivery_label text, allow_late boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  customer uuid := auth.uid();
  catalog public.store_catalog%rowtype;
  item jsonb;
  hold public.ken_checkout_holds%rowtype;
  saved public.orders%rowtype;
  instant timestamptz;
  late boolean;
  stock integer;
begin
  if customer is null then raise exception 'KEN_LOGIN_REQUIRED'; end if;
  if order_ref is null or order_ref !~ '^KEN-[A-F0-9]{12}$' or phone is null or phone !~ '^519[0-9]{8}$'
    or coalesce(char_length(btrim(customer_name)),0) not between 1 and 200
    or char_length(coalesce(delivery_data,''))>500 or char_length(coalesce(delivery_label,''))>150 then
    raise exception 'KEN_INVALID_ORDER';
  end if;
  select * into catalog from public.store_catalog where id=1 for update;
  select * into hold from public.ken_checkout_holds where id=hold_id and customer_id=customer for update;
  if not found then raise exception 'KEN_RESERVATION_MISSING'; end if;
  if hold.order_id is not null then
    select * into saved from public.orders where id=hold.order_id;
    return to_jsonb(saved);
  end if;
  instant := clock_timestamp();
  late := hold.expires_at<=instant;
  if hold.released or (late and (hold.price=0 or not coalesce(allow_late,false))) then raise exception 'KEN_RESERVATION_EXPIRED'; end if;
  select value into item from jsonb_array_elements(catalog.products) where value->>'id'=hold.product_id::text;
  if item is null then raise exception 'KEN_UNAVAILABLE'; end if;
  stock := (item->>'st')::integer;
  if not late and stock is not null and stock<=public.ken_checkout_available(hold.product_id,hold.id) then
    raise exception 'KEN_OUT_OF_STOCK';
  end if;
  insert into public.orders(id,pid,pn,cat,sub,price,extra,extra_label,wa,voucher,name,email,date,status,reason,customer_id,late_checkout)
  values(order_ref,hold.product_id,item->>'n',item->>'c',item->>'s',hold.price,btrim(delivery_data),delivery_label,phone,'',
    btrim(customer_name),auth.jwt()->>'email',instant,'pendiente','',customer,late)
  returning * into saved;
  update public.ken_checkout_holds set order_id=saved.id,released=late where id=hold.id;
  return to_jsonb(saved);
end
$$;
revoke all on function public.ken_submit_checkout(uuid,text,text,text,text,text,boolean) from public, anon;
grant execute on function public.ken_submit_checkout(uuid,text,text,text,text,text,boolean) to authenticated;

create function public.ken_apply_order_stock()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  catalog public.store_catalog%rowtype;
  hold public.ken_checkout_holds%rowtype;
  item jsonb;
  item_index integer;
  stock integer;
begin
  if new.status=old.status then return new; end if;
  if new.status not in ('aceptado','en_proceso','entregado','rechazado') then return new; end if;
  select * into catalog from public.store_catalog where id=1 for update;
  select * into hold from public.ken_checkout_holds where order_id=new.id for update;
  if new.status='rechazado' then
    update public.ken_checkout_holds set released=true where id=hold.id;
    return new;
  end if;
  if new.stock_committed or (hold.id is null and old.status in ('aceptado','en_proceso','entregado')) then return new; end if;
  select value,(ordinality-1)::integer into item,item_index
    from jsonb_array_elements(catalog.products) with ordinality where value->>'id'=new.pid::text;
  if item is null then raise exception 'KEN_UNAVAILABLE'; end if;
  stock := (item->>'st')::integer;
  if stock is not null then
    if stock<=public.ken_checkout_available(new.pid,hold.id) then raise exception 'KEN_OUT_OF_STOCK'; end if;
    update public.store_catalog
      set products=jsonb_set(products,array[item_index::text,'st'],to_jsonb(stock-1)),updated_at=clock_timestamp()
      where id=1;
  end if;
  update public.ken_checkout_holds set released=true where id=hold.id;
  new.stock_committed := true;
  return new;
end
$$;
revoke all on function public.ken_apply_order_stock() from public, anon, authenticated;
create trigger ken_apply_order_stock before update of status on public.orders
for each row execute function public.ken_apply_order_stock();

-- Los nuevos pedidos se crean con una reserva mediante la función transaccional.
revoke insert on public.orders from authenticated;
commit;
