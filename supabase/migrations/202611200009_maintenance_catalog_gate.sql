begin;

-- The maintenance message is safe to expose; product data is only readable
-- while the store is open, or to an authenticated Ken Store administrator.
create or replace function public.ken_public_maintenance_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'active', coalesce(nullif(btrim(c.site->>'maint'), ''), '') <> '',
    'message', coalesce(nullif(btrim(c.site->>'maint'), ''), 'Volvemos pronto.')
  )
  from public.store_catalog as c
  where c.id = 1
  limit 1;
$$;

create or replace function public.ken_catalog_read_allowed()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    nullif(btrim(c.site->>'maint'), '') is null
    or (select auth.jwt()->'app_metadata'->'kenstore_admin') = 'true'::jsonb,
    true
  )
  from public.store_catalog as c
  where c.id = 1
  limit 1;
$$;

revoke all on function public.ken_public_maintenance_status() from public;
revoke all on function public.ken_catalog_read_allowed() from public;
grant execute on function public.ken_public_maintenance_status() to anon, authenticated;
grant execute on function public.ken_catalog_read_allowed() to anon, authenticated;

alter table public.store_catalog enable row level security;
grant select on public.store_catalog to anon, authenticated;
revoke insert, update, delete on public.store_catalog from public, anon, authenticated;
grant insert, update, delete on public.store_catalog to authenticated;

-- Keep normal storefront reads available, then AND every SELECT policy with
-- the restrictive maintenance gate. Existing broader policies cannot bypass it.
drop policy if exists ken_store_catalog_public_select on public.store_catalog;
create policy ken_store_catalog_public_select on public.store_catalog
  for select to anon, authenticated using (true);

drop policy if exists ken_store_catalog_maintenance_gate on public.store_catalog;
create policy ken_store_catalog_maintenance_gate on public.store_catalog
  as restrictive for select to anon, authenticated
  using ((select public.ken_catalog_read_allowed()));

drop policy if exists ken_store_catalog_admin_write on public.store_catalog;
create policy ken_store_catalog_admin_write on public.store_catalog
  for all to authenticated
  using ((select auth.jwt()->'app_metadata'->'kenstore_admin') = 'true'::jsonb)
  with check ((select auth.jwt()->'app_metadata'->'kenstore_admin') = 'true'::jsonb);

drop policy if exists ken_store_catalog_admin_insert_gate on public.store_catalog;
create policy ken_store_catalog_admin_insert_gate on public.store_catalog
  as restrictive for insert to authenticated
  with check ((select auth.jwt()->'app_metadata'->'kenstore_admin') = 'true'::jsonb);

drop policy if exists ken_store_catalog_admin_update_gate on public.store_catalog;
create policy ken_store_catalog_admin_update_gate on public.store_catalog
  as restrictive for update to authenticated
  using ((select auth.jwt()->'app_metadata'->'kenstore_admin') = 'true'::jsonb)
  with check ((select auth.jwt()->'app_metadata'->'kenstore_admin') = 'true'::jsonb);

drop policy if exists ken_store_catalog_admin_delete_gate on public.store_catalog;
create policy ken_store_catalog_admin_delete_gate on public.store_catalog
  as restrictive for delete to authenticated
  using ((select auth.jwt()->'app_metadata'->'kenstore_admin') = 'true'::jsonb);

commit;
