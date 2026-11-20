begin;
alter table public.ken_checkout_holds add column product_snapshot jsonb;
create function public.ken_checkout_snapshot(item jsonb)
returns jsonb language sql immutable strict set search_path='' as $$
  select jsonb_build_object('id',item->'id','n',item->'n','c',item->'c','s',item->'s',
    't',item->'t','x',item->'x','accessDuration',item->'accessDuration')
$$;
revoke all on function public.ken_checkout_snapshot(jsonb) from public, anon, authenticated;
update public.ken_checkout_holds h set product_snapshot=public.ken_checkout_snapshot(p.value)
from public.store_catalog c cross join lateral jsonb_array_elements(c.products) p(value)
where c.id=1 and p.value->>'id'=h.product_id::text and h.order_id is null;
create or replace function public.ken_reserve_checkout(product bigint)
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
    insert into public.ken_checkout_holds(customer_id,product_id,price,expires_at,product_snapshot)
      values (customer,product,public.ken_effective_price(item,instant),instant+interval '15 minutes',public.ken_checkout_snapshot(item)) returning * into hold;
  end if;
  return jsonb_build_object('id',hold.id,'price',hold.price,'expires_at',hold.expires_at,'server_time',instant,'product',hold.product_snapshot);
end
$$;
revoke all on function public.ken_reserve_checkout(bigint) from public, anon;
grant execute on function public.ken_reserve_checkout(bigint) to authenticated;

create or replace function public.ken_submit_checkout(hold_id uuid, order_ref text, customer_name text, phone text, delivery_data text, delivery_label text, allow_late boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  customer uuid := auth.uid();
  catalog public.store_catalog%rowtype;
  item jsonb;
  snapshot jsonb;
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
  select value into item from jsonb_array_elements(catalog.products) where value->>'id'=hold.product_id::text;
  snapshot:=coalesce(hold.product_snapshot,public.ken_checkout_snapshot(item));
  late := hold.expires_at<=instant or item is null;
  if hold.released or (late and (hold.price=0 or not coalesce(allow_late,false))) then raise exception 'KEN_RESERVATION_EXPIRED'; end if;
  if snapshot is null then raise exception 'KEN_UNAVAILABLE'; end if;
  stock := (item->>'st')::integer;
  if not late and stock is not null and stock<=public.ken_checkout_available(hold.product_id,hold.id) then
    if hold.price>0 and coalesce(allow_late,false) then late:=true;
    else raise exception 'KEN_OUT_OF_STOCK';
    end if;
  end if;
  insert into public.orders(id,pid,pn,cat,sub,price,extra,extra_label,wa,voucher,name,email,date,status,reason,customer_id,late_checkout,access_duration)
  values(order_ref,hold.product_id,snapshot->>'n',snapshot->>'c',snapshot->>'s',hold.price,btrim(delivery_data),delivery_label,phone,'',
    btrim(customer_name),auth.jwt()->>'email',instant,'pendiente','',customer,late,coalesce(snapshot->'accessDuration','null'::jsonb))
  returning * into saved;
  update public.ken_checkout_holds set order_id=saved.id,released=late,expires_at=case when late then expires_at else instant+interval '2 hours' end where id=hold.id;
  return to_jsonb(saved);
end
$$;
revoke all on function public.ken_submit_checkout(uuid,text,text,text,text,text,boolean) from public, anon;
grant execute on function public.ken_submit_checkout(uuid,text,text,text,text,text,boolean) to authenticated;


create or replace function public.ken_my_checkouts()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(h) order by h.expires_at desc),'[]'::jsonb)
  from (
    select h.id,h.product_id,h.price,h.expires_at,now() as server_time,h.product_snapshot as product,
      not exists(select 1 from public.store_catalog c cross join lateral jsonb_array_elements(c.products) p
        where c.id=1 and p->>'id'=h.product_id::text) as unavailable
    from public.ken_checkout_holds h
    where customer_id=auth.uid() and not released and order_id is null
      and (expires_at>now() or (price>0 and expires_at>now()-interval '7 days'))
    order by expires_at desc limit 50
  ) h
$$;
revoke all on function public.ken_my_checkouts() from public, anon;
grant execute on function public.ken_my_checkouts() to authenticated;

create or replace function public.ken_pending_hold_status()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_object_agg(h.order_id,case when h.released or o.stock_committed then null else h.expires_at end),'{}'::jsonb)
  from public.ken_checkout_holds h join public.orders o on o.id=h.order_id
  where o.status='pendiente' and (select auth.jwt()->'app_metadata'->'kenstore_admin')='true'::jsonb
$$;
revoke all on function public.ken_pending_hold_status() from public, anon;
grant execute on function public.ken_pending_hold_status() to authenticated;

create or replace function public.ken_order_access_dates()
returns trigger language plpgsql set search_path='' as $$
declare
  duration jsonb;
  quantity integer;
  period interval;
begin
  if tg_op='INSERT' then
    if new.access_duration is null then
      select p.value->'accessDuration' into new.access_duration
    from public.store_catalog c cross join lateral jsonb_array_elements(c.products) as p(value)
    where c.id=1 and p.value->>'id'=new.pid::text;
    end if;
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
commit;
