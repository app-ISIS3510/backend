-- BQ10 (Nicolas Valentin): Which parking lots are added to favorites by the
-- highest proportion of the users who view their details, during the last
-- 7 days?
--
-- Counting favorites on their own rewards whichever lot is seen the most, which
-- usually means whichever one sits at the top of the listing. Measuring them
-- against the users who actually opened a lot's details isolates preference
-- from exposure.
--
-- In both apps a favorite can only be added from the parking details screen, so
-- every favorite is preceded by a detail view and the rate stays within 0-100%.
--
-- Two exclusions worth stating:
--   * Rows with a null user_id. The column had no default while the insert
--     policy required auth.uid() = user_id, so early rows cannot be attributed
--     to anyone and would corrupt the distinct counts.
--   * Users who favorited inside the window but whose detail view fell outside
--     it. They belong to neither the numerator nor the denominator, which keeps
--     both sides measured over the same period.

create or replace view public.bq10_favorite_conversion_last_7_days as
with recent as (
  select parking_id, user_id, event_type
  from public.analytics_events
  where created_at >= now() - interval '7 days'
    and created_at <= now()
    and user_id is not null
    and parking_id is not null
    and event_type in ('parking_detail_viewed', 'favorite_added')
), per_user as (
  -- One row per person per parking lot, so repeated visits count once.
  select
    parking_id,
    user_id,
    bool_or(event_type = 'parking_detail_viewed') as viewed,
    bool_or(event_type = 'favorite_added')        as favorited
  from recent
  group by parking_id, user_id
), totals as (
  select
    parking_id,
    count(*) filter (where viewed)               as detail_viewers,
    count(*) filter (where viewed and favorited) as favoriting_users
  from per_user
  group by parking_id
)
select
  p.id   as parking_id,
  p.name as parking_name,
  t.detail_viewers,
  t.favoriting_users,
  coalesce(
    round(100.0 * t.favoriting_users / nullif(t.detail_viewers, 0), 2),
    0
  ) as favorite_rate_percent,
  -- A rate over two or three viewers is noise. The flag is reported instead of
  -- filtering the row away, so the dashboard can show or hide thin lots without
  -- the view hiding data from it.
  (t.detail_viewers >= 5) as meets_minimum_sample
from totals t
join public.parking_lots p on p.id = t.parking_id
where t.detail_viewers > 0
order by favorite_rate_percent desc, t.detail_viewers desc;

revoke all on public.bq10_favorite_conversion_last_7_days from public, anon, authenticated;
grant select on public.bq10_favorite_conversion_last_7_days to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'parku_bi_reader') then
    grant select on public.bq10_favorite_conversion_last_7_days to parku_bi_reader;
  end if;
end $$;
