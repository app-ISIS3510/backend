begin;

-- Whatever the project already holds. Every assertion below is scoped to the
-- three fixture lots, and this snapshot proves the real rows were left alone.
create temp table bq10_before as
select parking_id, detail_viewers, favoriting_users, favorite_rate_percent
from public.bq10_favorite_conversion_last_7_days;

insert into auth.users(id) values
  ('00000000-0000-4000-a000-000000010011'),
  ('00000000-0000-4000-a000-000000010012'),
  ('00000000-0000-4000-a000-000000010013'),
  ('00000000-0000-4000-a000-000000010014'),
  ('00000000-0000-4000-a000-000000010015');

insert into public.parking_lots(id, name, address, car_spaces) values
  ('00000000-0000-4000-a000-000000010001', 'BQ10 lot A', 'Test', 10),
  ('00000000-0000-4000-a000-000000010002', 'BQ10 lot B', 'Test', 10),
  ('00000000-0000-4000-a000-000000010003', 'BQ10 lot C', 'Test', 10);

-- Lot A: three viewers, one of whom favorites. The first user opens the screen
-- twice, which must still count as one viewer.
insert into public.analytics_events(user_id, event_type, parking_id) values
  ('00000000-0000-4000-a000-000000010011', 'parking_detail_viewed', '00000000-0000-4000-a000-000000010001'),
  ('00000000-0000-4000-a000-000000010011', 'parking_detail_viewed', '00000000-0000-4000-a000-000000010001'),
  ('00000000-0000-4000-a000-000000010012', 'parking_detail_viewed', '00000000-0000-4000-a000-000000010001'),
  ('00000000-0000-4000-a000-000000010013', 'parking_detail_viewed', '00000000-0000-4000-a000-000000010001'),
  ('00000000-0000-4000-a000-000000010011', 'favorite_added',        '00000000-0000-4000-a000-000000010001');

-- Lot B: everyone who looked at it saved it. The third user favorites without a
-- detail view inside the window, so the rate must stay at 100 and not exceed it.
insert into public.analytics_events(user_id, event_type, parking_id) values
  ('00000000-0000-4000-a000-000000010011', 'parking_detail_viewed', '00000000-0000-4000-a000-000000010002'),
  ('00000000-0000-4000-a000-000000010012', 'parking_detail_viewed', '00000000-0000-4000-a000-000000010002'),
  ('00000000-0000-4000-a000-000000010011', 'favorite_added',        '00000000-0000-4000-a000-000000010002'),
  ('00000000-0000-4000-a000-000000010012', 'favorite_added',        '00000000-0000-4000-a000-000000010002'),
  ('00000000-0000-4000-a000-000000010013', 'favorite_added',        '00000000-0000-4000-a000-000000010002');

-- Lot C: five viewers, so this is the one that reaches the minimum sample.
insert into public.analytics_events(user_id, event_type, parking_id)
select ('00000000-0000-4000-a000-00000001001' || n)::uuid,
  'parking_detail_viewed', '00000000-0000-4000-a000-000000010003'
from generate_series(1, 5) n;

insert into public.analytics_events(user_id, event_type, parking_id) values
  ('00000000-0000-4000-a000-000000010011', 'favorite_added', '00000000-0000-4000-a000-000000010003');

-- Rows that must never reach the result: outside the window on either side,
-- unattributed, or an event type the question does not ask about.
insert into public.analytics_events(user_id, event_type, parking_id, created_at) values
  ('00000000-0000-4000-a000-000000010014', 'parking_detail_viewed', '00000000-0000-4000-a000-000000010001', now() - interval '8 days'),
  ('00000000-0000-4000-a000-000000010015', 'parking_detail_viewed', '00000000-0000-4000-a000-000000010001', now() + interval '1 day'),
  (null,                                   'parking_detail_viewed', '00000000-0000-4000-a000-000000010001', now()),
  ('00000000-0000-4000-a000-000000010014', 'navigation_opened',     '00000000-0000-4000-a000-000000010001', now());

do $$
declare
  v_lot_a constant uuid := '00000000-0000-4000-a000-000000010001';
  v_lot_b constant uuid := '00000000-0000-4000-a000-000000010002';
  v_lot_c constant uuid := '00000000-0000-4000-a000-000000010003';
begin
  assert (select detail_viewers = 3 and favoriting_users = 1
            and favorite_rate_percent = 33.33 and not meets_minimum_sample
          from public.bq10_favorite_conversion_last_7_days
          where parking_id = v_lot_a),
    'Lot A: repeated views count once, old, future, unattributed and unrelated events are excluded';

  assert (select detail_viewers = 2 and favoriting_users = 2
            and favorite_rate_percent = 100.00
          from public.bq10_favorite_conversion_last_7_days
          where parking_id = v_lot_b),
    'Lot B: a favorite without a detail view in the window cannot push the rate past 100';

  assert (select detail_viewers = 5 and favoriting_users = 1
            and favorite_rate_percent = 20.00 and meets_minimum_sample
          from public.bq10_favorite_conversion_last_7_days
          where parking_id = v_lot_c),
    'Lot C: five viewers reach the minimum sample flag';

  assert not exists (
    select 1 from public.bq10_favorite_conversion_last_7_days
    where favorite_rate_percent > 100 or favoriting_users > detail_viewers
  ), 'The rate is bounded because favorites can only be added from the details screen';

  assert (select parking_id from public.bq10_favorite_conversion_last_7_days
          where parking_id in (v_lot_a, v_lot_b, v_lot_c)
          order by favorite_rate_percent desc, detail_viewers desc
          limit 1) = v_lot_b,
    'The lot that convinces every viewer ranks first, not the one with most views';

  assert not exists (
    select 1 from public.bq10_favorite_conversion_last_7_days a
    join bq10_before b using (parking_id)
    where a.detail_viewers <> b.detail_viewers
       or a.favoriting_users <> b.favoriting_users
  ), 'Pre-existing parking lots are untouched by the fixtures';

  assert not has_table_privilege('anon', 'public.bq10_favorite_conversion_last_7_days', 'SELECT'),
    'No anonymous access';
  assert not has_table_privilege('authenticated', 'public.bq10_favorite_conversion_last_7_days', 'SELECT'),
    'App users do not receive access to shared dashboard data';

  if exists (select 1 from pg_roles where rolname = 'parku_bi_reader') then
    assert has_table_privilege('parku_bi_reader', 'public.bq10_favorite_conversion_last_7_days', 'SELECT'),
      'The existing dashboard reader can read the aggregate';
  end if;
end $$;

select 'PASS: BQ10 rate, deduplication, time window, attribution, ranking and permissions' as bq10_checks;
rollback;
