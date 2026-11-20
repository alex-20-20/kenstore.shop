begin;
update public.ken_checkout_holds h set expires_at=o.date+interval '2 hours'
from public.orders o where o.id=h.order_id and o.status='pendiente' and not h.released;
create or replace function public.ken_checkout_available(product bigint, ignore_hold uuid default null)
returns bigint language sql volatile set search_path='' as $$
  select count(*) from public.ken_checkout_holds h
  where h.product_id=product and not h.released and h.id is distinct from ignore_hold
    and h.expires_at>clock_timestamp()
$$;
revoke all on function public.ken_checkout_available(bigint,uuid) from public, anon, authenticated;

create or replace function public.ken_submit_checkout(hold_id uuid, order_ref text, customer_name text, phone text, delivery_data text, delivery_label text, allow_late boolean default false)
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
  update public.ken_checkout_holds set order_id=saved.id,released=late,expires_at=case when late then expires_at else instant+interval '2 hours' end where id=hold.id;
  return to_jsonb(saved);
end
$$;
revoke all on function public.ken_submit_checkout(uuid,text,text,text,text,text,boolean) from public, anon;
grant execute on function public.ken_submit_checkout(uuid,text,text,text,text,text,boolean) to authenticated;


create function public.ken_public_availability()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_object_agg(product.value->>'id',greatest(0,(product.value->>'st')::int-coalesce(held.units,0))),'{}'::jsonb)
  from public.store_catalog c cross join lateral jsonb_array_elements(c.products) product(value)
  left join (
    select product_id,count(*) as units from public.ken_checkout_holds
    where not released and expires_at>now() group by product_id
  ) held on held.product_id::text=product.value->>'id'
  where c.id=1 and product.value->>'st' ~ '^[0-9]{1,9}$'
$$;
revoke all on function public.ken_public_availability() from public;
grant execute on function public.ken_public_availability() to anon, authenticated;

create function public.ken_my_checkouts()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(h) order by h.expires_at desc),'[]'::jsonb)
  from (
    select id,product_id,price,expires_at,now() as server_time
    from public.ken_checkout_holds
    where customer_id=auth.uid() and not released and order_id is null
      and (expires_at>now() or (price>0 and expires_at>now()-interval '7 days'))
    order by expires_at desc limit 50
  ) h
$$;
revoke all on function public.ken_my_checkouts() from public, anon;
grant execute on function public.ken_my_checkouts() to authenticated;

create function public.ken_pending_hold_status()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_object_agg(h.order_id,h.expires_at),'{}'::jsonb)
  from public.ken_checkout_holds h join public.orders o on o.id=h.order_id
  where o.status='pendiente' and (select auth.jwt()->'app_metadata'->'kenstore_admin')='true'::jsonb
$$;
revoke all on function public.ken_pending_hold_status() from public, anon;
grant execute on function public.ken_pending_hold_status() to authenticated;

create function public.ken_extend_pending_hold(order_ref text)
returns timestamptz language plpgsql security definer set search_path='' as $$
declare
  item jsonb;
  catalog public.store_catalog%rowtype;
  hold public.ken_checkout_holds%rowtype;
  deadline timestamptz;
begin
  if (auth.jwt()->'app_metadata'->'kenstore_admin') is distinct from 'true'::jsonb then raise exception 'KEN_ADMIN_REQUIRED'; end if;
  perform 1 from public.orders where id=order_ref and status='pendiente' for update;
  if not found then raise exception 'KEN_UNAVAILABLE'; end if;
  select * into catalog from public.store_catalog where id=1 for update;
  select * into hold from public.ken_checkout_holds where order_id=order_ref for update;
  if not found then raise exception 'KEN_UNAVAILABLE'; end if;
  select value into item from jsonb_array_elements(catalog.products) where value->>'id'=hold.product_id::text;
  if item is null then raise exception 'KEN_UNAVAILABLE'; end if;
  if (item->>'st')::int<=public.ken_checkout_available(hold.product_id,hold.id) then raise exception 'KEN_OUT_OF_STOCK'; end if;
  deadline:=greatest(clock_timestamp(),hold.expires_at)+interval '2 hours';
  update public.ken_checkout_holds set expires_at=deadline,released=false where id=hold.id;
  return deadline;
end
$$;
revoke all on function public.ken_extend_pending_hold(text) from public, anon;
grant execute on function public.ken_extend_pending_hold(text) to authenticated;
commit;
