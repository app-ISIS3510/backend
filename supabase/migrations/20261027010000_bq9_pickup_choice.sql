create or replace view public.bq9_pickup_time_choice_last_7_days as
with choices as (
  select distinct on (user_id, metadata->>'session_id')
    user_id,
    metadata->>'session_id' as session_id,
    metadata->>'pickup_selection' as choice
  from public.analytics_events
  where event_type = 'parking_pickup_choice'
    and metadata->>'pickup_selection' in ('suggested', 'manual')
  order by user_id, metadata->>'session_id', created_at, id
), counts as (
  select coalesce(c.choice, 'unrecorded') as choice, count(*) as starts
  from public.parking_sessions s
  left join choices c on c.session_id = s.id::text and c.user_id = s.user_id
  where s.started_at >= now() - interval '7 days' and s.started_at <= now()
  group by coalesce(c.choice, 'unrecorded')
), labels(choice, pickup_choice) as (
  values ('suggested', 'Suggested'), ('manual', 'Manual'), ('unrecorded', 'Not recorded')
), totals as (
  select l.pickup_choice, coalesce(c.starts, 0) as successful_starts
  from labels l left join counts c on c.choice = l.choice
)
select pickup_choice, successful_starts,
  coalesce(round(100.0 * successful_starts /
    nullif(sum(successful_starts) over (), 0), 2), 0) as percentage,
  (sum(successful_starts) over ())::bigint as total_successful_starts
from totals;

revoke all on public.bq9_pickup_time_choice_last_7_days from public, anon, authenticated;
grant select on public.bq9_pickup_time_choice_last_7_days to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'parku_bi_reader') then
    grant select on public.bq9_pickup_time_choice_last_7_days to parku_bi_reader;
  end if;
end $$;
