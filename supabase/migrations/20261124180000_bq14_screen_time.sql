create or replace view public.bq14_screen_time_by_day as
with events as (
  select
    screen,
    metadata ->> 'platform' as platform,
    created_at at time zone 'America/Bogota' as ended_at,
    case when jsonb_typeof(metadata -> 'duration_ms') = 'number'
      then (metadata ->> 'duration_ms')::numeric
    end as duration_ms
  from public.analytics_events
  where event_type = 'screen_time_spent'
    and created_at <= now()
    and nullif(btrim(screen), '') is not null
), visits as (
  select
    screen,
    platform,
    ended_at,
    ended_at - duration_ms::double precision * interval '1 millisecond' as started_at
  from events
  where duration_ms > 0 and duration_ms <= 86400000
    and platform in ('flutter', 'kotlin')
)
select
  day::date as activity_date,
  initcap(replace(screen, '_', ' ')) as screen,
  platform,
  round(sum(extract(epoch from (
    least(ended_at, day + interval '1 day') - greatest(started_at, day)
  ))), 3) as total_seconds
from visits
cross join lateral generate_series(
  date_trunc('day', started_at),
  date_trunc('day', ended_at),
  interval '1 day'
) as days(day)
where day < ended_at
group by activity_date, initcap(replace(screen, '_', ' ')), platform;

revoke all on public.bq14_screen_time_by_day from public, anon, authenticated;
grant select on public.bq14_screen_time_by_day to service_role, parku_bi_reader;
