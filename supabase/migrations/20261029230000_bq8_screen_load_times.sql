create table if not exists public.screen_load_times (
  id uuid primary key default gen_random_uuid(),
  user_id uuid default auth.uid() references auth.users(id) on delete set null,
  screen text not null,
  load_ms integer not null check (load_ms >= 0),
  device_model text not null,
  os_version text not null,
  from_cache boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.screen_load_times enable row level security;

drop policy if exists "insert own load times" on public.screen_load_times;
create policy "insert own load times"
  on public.screen_load_times for insert to authenticated
  with check (user_id = auth.uid());

grant usage on schema public to authenticated;
grant insert on public.screen_load_times to authenticated;

create or replace view public.bq2_slowest_screens_by_device as
select
  screen,
  device_model,
  os_version,
  round(avg(load_ms) filter (where not from_cache))::int as avg_network_ms,
  round(avg(load_ms) filter (where from_cache))::int as avg_cached_ms,
  count(*)::int as samples
from public.screen_load_times
group by screen, device_model, os_version
having count(*) filter (where not from_cache) > 0
order by avg_network_ms desc
limit 20;

revoke all on public.bq2_slowest_screens_by_device from public, anon, authenticated;
grant select on public.bq2_slowest_screens_by_device to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'parku_bi_reader') then
    grant select on public.bq2_slowest_screens_by_device to parku_bi_reader;
  end if;
end $$;
