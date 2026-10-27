begin;

create temp table bq9_before as
select pickup_choice, successful_starts
from public.bq9_pickup_time_choice_last_7_days;

insert into auth.users(id) values
  ('00000000-0000-4000-a000-000000009001'),
  ('00000000-0000-4000-a000-000000009002');
insert into public.parking_lots(id, name, address, car_spaces)
values ('00000000-0000-4000-a000-000000009003', 'BQ9 test', 'Test', 10);

insert into public.parking_sessions(id, user_id, parking_id, pickup_time, started_at, status)
select ('00000000-0000-4000-a000-00000000900' || n)::uuid,
  '00000000-0000-4000-a000-000000009001'::uuid,
  '00000000-0000-4000-a000-000000009003'::uuid,
  now() + interval '1 hour',
  case when n = 7 then now() - interval '8 days'
       when n = 8 then now() + interval '1 day'
       else now() - interval '1 minute' end,
  'completed'
from generate_series(4, 8) n;

insert into public.analytics_events(id, user_id, event_type, parking_id, created_at, metadata)
select id, user_id, 'parking_pickup_choice', parking_id, started_at,
  jsonb_build_object('session_id', id, 'platform', 'flutter',
    'pickup_selection', case when right(id::text,1) = '5' then 'manual' else 'suggested' end)
from public.parking_sessions
where id in ('00000000-0000-4000-a000-000000009004',
  '00000000-0000-4000-a000-000000009005',
  '00000000-0000-4000-a000-000000009007',
  '00000000-0000-4000-a000-000000009008');

insert into public.analytics_events(id, user_id, event_type, metadata)
values ('00000000-0000-4000-a000-000000009004',
  '00000000-0000-4000-a000-000000009001', 'parking_pickup_choice',
  '{"session_id":"00000000-0000-4000-a000-000000009004","pickup_selection":"manual"}')
on conflict (id) do nothing;

insert into public.analytics_events(user_id, event_type, metadata) values
  ('00000000-0000-4000-a000-000000009001', 'parking_pickup_choice',
   '{"session_id":"00000000-0000-4000-a000-000000009004","pickup_selection":"manual"}'),
  ('00000000-0000-4000-a000-000000009002', 'parking_pickup_choice',
   '{"session_id":"00000000-0000-4000-a000-000000009006","pickup_selection":"suggested"}'),
  ('00000000-0000-4000-a000-000000009001', 'parking_pickup_choice',
   '{"session_id":"00000000-0000-4000-a000-000000009006","pickup_selection":"invalid"}'),
  ('00000000-0000-4000-a000-000000009001', 'parking_pickup_choice',
   '{"session_id":"00000000-0000-4000-a000-000000009099","pickup_selection":"suggested"}');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-a000-000000009001', true);
insert into public.analytics_events(id, user_id, event_type, metadata)
values ('00000000-0000-4000-a000-000000009004',
  '00000000-0000-4000-a000-000000009001', 'parking_pickup_choice',
  '{"session_id":"00000000-0000-4000-a000-000000009004","pickup_selection":"suggested"}')
on conflict (id) do nothing;
do $$
begin
  begin
    insert into public.analytics_events(user_id, event_type)
    values ('00000000-0000-4000-a000-000000009002', 'parking_pickup_choice');
    raise exception 'The app must not insert events for another user';
  exception when insufficient_privilege then
    null;
  end;
end $$;
reset role;

do $$
begin
  assert (select count(*) from public.bq9_pickup_time_choice_last_7_days) = 3,
    'Three categories, including unknown historical starts';
  assert not exists (
    select 1 from public.bq9_pickup_time_choice_last_7_days a
    join bq9_before b using (pickup_choice)
    where a.successful_starts <> b.successful_starts + 1
  ), 'One suggested, one manual and one unrecorded; exclude old, future, orphan and foreign-user events';
  assert (select sum(successful_starts) = max(total_successful_starts)
    from public.bq9_pickup_time_choice_last_7_days), 'Denominator matches successful sessions';
  assert (select abs(sum(percentage) - 100) < 0.02
    from public.bq9_pickup_time_choice_last_7_days), 'Percentages sum to 100 within rounding';
  assert (select count(*) from public.analytics_events
    where id = '00000000-0000-4000-a000-000000009004') = 1, 'Retry keeps the same event ID';
  assert not has_table_privilege('anon', 'public.bq9_pickup_time_choice_last_7_days', 'SELECT'),
    'No anonymous access';
  assert not has_table_privilege('authenticated', 'public.bq9_pickup_time_choice_last_7_days', 'SELECT'),
    'App users do not receive access to shared dashboard data';
  if exists (select 1 from pg_roles where rolname = 'parku_bi_reader') then
    assert has_table_privilege('parku_bi_reader', 'public.bq9_pickup_time_choice_last_7_days', 'SELECT'),
      'The existing dashboard reader can read the aggregate';
  end if;
end $$;

select 'PASS: BQ9 categories, deduplication, ownership, time window, denominator and permissions' as bq9_checks;
rollback;
