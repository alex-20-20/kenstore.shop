begin;

-- Qualify hold columns so PL/pgSQL does not confuse guest_token (the RPC
-- argument) with ken_checkout_holds.guest_token.
create or replace function public.ken_reserve_product_plan(product bigint, selected_plan text, guest_token uuid)
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
  select h.* into hold from public.ken_checkout_holds as h
    where h.product_id=product and h.customer_id is not distinct from customer and h.guest_token is not distinct from request_token
      and h.plan_key is not distinct from selected_plan and h.expires_at>instant and h.order_id is null and not h.released
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

commit;
