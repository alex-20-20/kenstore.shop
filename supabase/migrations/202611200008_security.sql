begin;
create index if not exists ken_checkout_holds_customer_active_idx
  on public.ken_checkout_holds (customer_id, expires_at)
  where not released;
create function public.ken_limit_active_checkout_holds()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('ken-checkout:' || new.customer_id::text, 0));
  if (select count(*) from public.ken_checkout_holds h
      where h.customer_id=new.customer_id and not h.released
        and h.expires_at>clock_timestamp())>=5 then
    raise exception 'KEN_RESERVATION_LIMIT';
  end if;
  return new;
end;
$$;
revoke all on function public.ken_limit_active_checkout_holds() from public, anon, authenticated;
create trigger ken_limit_active_checkout_holds
before insert on public.ken_checkout_holds
for each row execute function public.ken_limit_active_checkout_holds();
commit;
