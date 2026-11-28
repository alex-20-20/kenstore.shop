begin;

-- Guest checkout keeps the order in the admin panel while allowing the buyer
-- to complete it without an account. Guest holds are bound to an unguessable
-- per-checkout UUID supplied by the browser.
alter table public.orders alter column customer_id drop not null;
alter table public.orders alter column email drop not null;
alter table public.ken_checkout_holds alter column customer_id drop not null;
alter table public.ken_checkout_holds add column guest_token uuid;
create index if not exists ken_checkout_holds_guest_active_idx
  on public.ken_checkout_holds (guest_token, expires_at) where not released;
create index if not exists ken_orders_guest_gift_lookup_idx
  on public.orders (pid, wa) where price=0 and status<>'rechazado';

-- Five active reservations per signed-in account or per anonymous checkout token.
create or replace function public.ken_limit_active_checkout_holds()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  reservation_key text := coalesce(new.guest_token::text,new.customer_id::text);
begin
  if reservation_key is null then raise exception 'KEN_GUEST_TOKEN_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ken-checkout:' || reservation_key, 0));
  if (select count(*) from public.ken_checkout_holds h
      where not h.released and h.expires_at>clock_timestamp()
        and ((new.guest_token is not null and h.guest_token=new.guest_token)
          or (new.guest_token is null and h.customer_id=new.customer_id)))>=5 then
    raise exception 'KEN_RESERVATION_LIMIT';
  end if;
  return new;
end;
$$;

create function public.ken_reserve_product_plan(product bigint, selected_plan text, guest_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  customer uuid := auth.uid();
  request_token alias for $3;
  catalog public.store_catalog%rowtype;
  item jsonb;
  plan jsonb;
  snapshot jsonb;
  quoted_price numeric;
  first_plan boolean;
  hold public.ken_checkout_holds%rowtype;
  instant timestamptz;
  stock integer;
begin
  if request_token is null and customer is null then raise exception 'KEN_GUEST_TOKEN_REQUIRED'; end if;
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

  if jsonb_typeof(item->'plans')='array' and jsonb_array_length(item->'plans')>0 then
    select value,(ordinality=1) into plan,first_plan
      from jsonb_array_elements(item->'plans') with ordinality where value->>'id'=selected_plan limit 1;
    if plan is null then raise exception 'KEN_PLAN_UNAVAILABLE'; end if;
    quoted_price:=(plan->>'price')::numeric;
    if quoted_price<=0 then raise exception 'KEN_PLAN_UNAVAILABLE'; end if;
    if first_plan then quoted_price:=public.ken_effective_price(item||jsonb_build_object('p',quoted_price),instant); end if;
    snapshot:=public.ken_checkout_snapshot(item)||jsonb_build_object('planName',plan->>'name','accessDuration',plan->'duration');
  else
    if selected_plan is not null then raise exception 'KEN_PLAN_UNAVAILABLE'; end if;
    quoted_price:=public.ken_effective_price(item,instant);
    snapshot:=public.ken_checkout_snapshot(item);
  end if;
  stock := (item->>'st')::integer;
  select * into hold from public.ken_checkout_holds
    where product_id=product and customer_id is not distinct from customer and guest_token is not distinct from request_token
      and plan_key is not distinct from selected_plan and expires_at>instant and order_id is null and not released
    limit 1;
  if stock is not null and stock<=public.ken_checkout_available(product,hold.id) then raise exception 'KEN_OUT_OF_STOCK'; end if;
  if hold.id is null then
    insert into public.ken_checkout_holds(customer_id,guest_token,product_id,price,expires_at,product_snapshot,plan_key)
      values(customer,request_token,product,quoted_price,instant+interval '15 minutes',snapshot,selected_plan) returning * into hold;
  end if;
  return jsonb_build_object('id',hold.id,'price',hold.price,'expires_at',hold.expires_at,
    'server_time',instant,'product',hold.product_snapshot);
end
$$;
revoke all on function public.ken_reserve_product_plan(bigint,text,uuid) from public;
grant execute on function public.ken_reserve_product_plan(bigint,text,uuid) to anon, authenticated;

create function public.ken_submit_checkout(hold_id uuid, order_ref text, customer_name text, phone text,
  delivery_data text, delivery_label text, allow_late boolean, guest_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  customer uuid := auth.uid();
  request_token alias for $8;
  catalog public.store_catalog%rowtype;
  item jsonb;
  snapshot jsonb;
  hold public.ken_checkout_holds%rowtype;
  saved public.orders%rowtype;
  instant timestamptz;
  late boolean;
  stock integer;
begin
  if (request_token is null and customer is null) or order_ref is null or order_ref !~ '^KEN-[A-F0-9]{12}$'
    or phone is null or phone !~ '^519[0-9]{8}$'
    or coalesce(char_length(btrim(customer_name)),0) not between 1 and 200
    or char_length(coalesce(delivery_data,''))>500 or char_length(coalesce(delivery_label,''))>150 then
    raise exception 'KEN_INVALID_ORDER';
  end if;
  select * into catalog from public.store_catalog where id=1 for update;
  select * into hold from public.ken_checkout_holds
    where id=hold_id and customer_id is not distinct from customer and guest_token is not distinct from request_token
    for update;
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
  if hold.price=0 and exists(select 1 from public.orders o where o.pid=hold.product_id and o.wa=phone and o.status<>'rechazado') then
    raise exception 'KEN_GIFT_ALREADY_CLAIMED';
  end if;
  stock := (item->>'st')::integer;
  if not late and stock is not null and stock<=public.ken_checkout_available(hold.product_id,hold.id) then
    if hold.price>0 and coalesce(allow_late,false) then late:=true; else raise exception 'KEN_OUT_OF_STOCK'; end if;
  end if;
  insert into public.orders(id,pid,pn,cat,sub,price,extra,extra_label,wa,voucher,name,email,date,status,reason,
    customer_id,late_checkout,access_duration,plan_name)
  values(order_ref,hold.product_id,snapshot->>'n',snapshot->>'c',snapshot->>'s',hold.price,btrim(delivery_data),delivery_label,
    phone,'',btrim(customer_name),auth.jwt()->>'email',instant,'pendiente','',customer,late,
    coalesce(snapshot->'accessDuration','null'::jsonb),snapshot->>'planName')
  returning * into saved;
  update public.ken_checkout_holds set order_id=saved.id,released=late,
    expires_at=case when late then expires_at else instant+interval '2 hours' end where id=hold.id;
  return to_jsonb(saved);
end
$$;
revoke all on function public.ken_submit_checkout(uuid,text,text,text,text,text,boolean,uuid) from public;
grant execute on function public.ken_submit_checkout(uuid,text,text,text,text,text,boolean,uuid) to anon, authenticated;

-- Preserve authenticated recovery for holds created before guest checkout.
create or replace function public.ken_my_checkouts()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(h) order by h.expires_at desc),'[]'::jsonb)
  from (
    select h.id,h.product_id,h.price,h.expires_at,now() as server_time,
      h.product_snapshot as product,h.guest_token,
      not exists(select 1 from public.store_catalog c cross join lateral jsonb_array_elements(c.products) p
        where c.id=1 and p->>'id'=h.product_id::text) as unavailable
    from public.ken_checkout_holds h
    where h.customer_id=auth.uid() and not h.released and h.order_id is null
      and (h.expires_at>now() or (h.price>0 and h.expires_at>now()-interval '7 days'))
    order by h.expires_at desc limit 50
  ) h
$$;
revoke all on function public.ken_my_checkouts() from public, anon;
grant execute on function public.ken_my_checkouts() to authenticated;

commit;
