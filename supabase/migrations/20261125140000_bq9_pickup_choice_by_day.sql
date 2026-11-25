create or replace view public.bq9_pickup_choice_by_day as
with choices as (
  select distinct on (user_id, metadata ->> 'session_id')
    user_id,
    metadata ->> 'session_id' as session_id,
    metadata ->> 'pickup_selection' as choice
  from public.analytics_events
  where event_type = 'parking_pickup_choice'
    and metadata ->> 'pickup_selection' in ('suggested', 'manual')
  order by user_id, metadata ->> 'session_id', created_at, id
)
select
  (s.started_at at time zone 'America/Bogota')::date as activity_date,
  case c.choice
    when 'suggested' then 'Suggested'
    when 'manual' then 'Manual'
    else 'Not recorded'
  end as pickup_choice,
  count(*) as successful_starts
from public.parking_sessions s
left join choices c on c.session_id = s.id::text and c.user_id = s.user_id
where s.started_at <= now()
group by 1, 2;

revoke all on public.bq9_pickup_choice_by_day from public, anon, authenticated;
grant select on public.bq9_pickup_choice_by_day to service_role, parku_bi_reader;
