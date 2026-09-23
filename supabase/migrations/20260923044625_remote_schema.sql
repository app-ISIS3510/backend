SET local check_function_bodies = off;

CREATE EXTENSION "pg_cron";

CREATE TABLE "public"."analytics_events" (
  "id"         uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"    uuid,
  "event_type" text                     NOT NULL,
  "screen"     text,
  "parking_id" uuid,
  "metadata"   jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "analytics_events_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."analytics_events"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."parking_sessions"
  ADD COLUMN "vehicle_type" text NOT NULL DEFAULT 'car'::text;

CREATE OR REPLACE FUNCTION public.start_parking_session (
  p_parking_id   uuid,
  p_pickup_time  timestamp with time zone,
  p_vehicle_type text
)
  RETURNS public.parking_sessions
  LANGUAGE plpgsql
  AS $function$
declare
  v_capacity integer;
  v_active_sessions integer;
  v_session public.parking_sessions;
begin
  if p_vehicle_type not in ('car', 'motorcycle') then
    raise exception 'INVALID_VEHICLE_TYPE';
  end if;

  -- Bloquea operaciones simultáneas para este parqueadero.
  perform pg_advisory_xact_lock(
    hashtextextended(p_parking_id::text, 0)
  );

  select
    case
      when p_vehicle_type = 'car'
        then car_spaces
      else motorcycle_spaces
    end
  into v_capacity
  from public.parking_lots
  where id = p_parking_id;

  if v_capacity is null then
    raise exception 'PARKING_NOT_FOUND';
  end if;

  select count(*)
  into v_active_sessions
  from public.parking_sessions
  where parking_id = p_parking_id
    and status = 'active'
    and vehicle_type = p_vehicle_type;

  if v_active_sessions >= v_capacity then
    raise exception 'NO_AVAILABLE_SPACES';
  end if;

  insert into public.parking_sessions (
    user_id,
    parking_id,
    pickup_time,
    vehicle_type,
    status
  )
  values (
    auth.uid(),
    p_parking_id,
    p_pickup_time,
    p_vehicle_type,
    'active'
  )
  returning *
  into v_session;

  return v_session;
end;
$function$;

ALTER TABLE "public"."analytics_events"
  ADD CONSTRAINT "analytics_events_parking_id_fkey" FOREIGN KEY (parking_id) REFERENCES public.parking_lots(id) ON DELETE SET NULL;

ALTER TABLE "public"."parking_sessions"
  ADD CONSTRAINT "parking_sessions_vehicle_type_check" CHECK ((vehicle_type = ANY (ARRAY['car'::text, 'motorcycle'::text])));

CREATE VIEW "public"."bq1_parking_starts_last_7_days" AS  SELECT date(created_at) AS day,
    count(*) AS parking_sessions_started
   FROM public.analytics_events
  WHERE ((event_type = 'parking_started'::text) AND (created_at >= (now() - '7 days'::interval)))
  GROUP BY (date(created_at))
  ORDER BY (date(created_at));

CREATE VIEW "public"."bq2_top_parking_completed_last_7_days" AS  SELECT p.id AS parking_id,
    p.name AS parking_name,
    count(*) AS completed_sessions
   FROM (public.analytics_events a
     JOIN public.parking_lots p ON ((p.id = a.parking_id)))
  WHERE ((a.event_type = 'parking_ended'::text) AND (a.created_at >= (now() - '7 days'::interval)))
  GROUP BY p.id, p.name
  ORDER BY (count(*)) DESC
 LIMIT 3;

CREATE VIEW "public"."bq3_parking_flow_abandonment_last_7_days" AS  WITH funnel AS (
         SELECT count(*) FILTER (WHERE (analytics_events.event_type = 'parking_detail_viewed'::text)) AS detail_views,
            count(*) FILTER (WHERE (analytics_events.event_type = 'pickup_time_viewed'::text)) AS pickup_views,
            count(*) FILTER (WHERE (analytics_events.event_type = 'parking_started'::text)) AS parking_starts
           FROM public.analytics_events
          WHERE (analytics_events.created_at >= (now() - '7 days'::interval))
        ), dropoffs AS (
         SELECT 'Parking details → Pickup time'::text AS flow_step,
            GREATEST((funnel.detail_views - funnel.pickup_views), (0)::bigint) AS abandonment_count
           FROM funnel
        UNION ALL
         SELECT 'Pickup time → Start parking'::text AS flow_step,
            GREATEST((funnel.pickup_views - funnel.parking_starts), (0)::bigint) AS abandonment_count
           FROM funnel
        )
 SELECT flow_step,
    abandonment_count
   FROM dropoffs
  ORDER BY abandonment_count DESC;

CREATE VIEW "public"."bq4_favorite_additions_last_7_days" AS  SELECT count(*) AS favorite_add_events
   FROM public.analytics_events
  WHERE ((event_type = 'favorite_added'::text) AND (created_at >= (now() - '7 days'::interval)));

CREATE VIEW "public"."bq5_action_usage_last_7_days" AS  SELECT event_type,
    count(*) AS usage_count
   FROM public.analytics_events
  WHERE ((event_type = ANY (ARRAY['pickup_time_changed'::text, 'navigation_opened'::text, 'favorite_added'::text, 'parking_ended'::text])) AND (created_at >= (now() - '7 days'::interval)))
  GROUP BY event_type
  ORDER BY (count(*));

CREATE VIEW "public"."bq5_least_used_action_last_7_days" AS  SELECT event_type,
    count(*) AS usage_count
   FROM public.analytics_events
  WHERE ((event_type = ANY (ARRAY['pickup_time_changed'::text, 'navigation_opened'::text, 'favorite_added'::text, 'parking_ended'::text])) AND (created_at >= (now() - '7 days'::interval)))
  GROUP BY event_type
  ORDER BY (count(*))
 LIMIT 1;

CREATE VIEW "public"."bq6_top_parking_by_2h_slot_last_30_days" AS  WITH starts AS (
         SELECT a.parking_id,
            p.name AS parking_name,
            (EXTRACT(hour FROM a.created_at))::integer AS event_hour
           FROM (public.analytics_events a
             JOIN public.parking_lots p ON ((p.id = a.parking_id)))
          WHERE ((a.event_type = 'parking_started'::text) AND (a.created_at >= (now() - '30 days'::interval)) AND (EXTRACT(hour FROM a.created_at) >= (6)::numeric) AND (EXTRACT(hour FROM a.created_at) < (22)::numeric))
        ), grouped AS (
         SELECT starts.parking_id,
            starts.parking_name,
                CASE
                    WHEN ((starts.event_hour >= 6) AND (starts.event_hour <= 7)) THEN '06:00 - 08:00'::text
                    WHEN ((starts.event_hour >= 8) AND (starts.event_hour <= 9)) THEN '08:00 - 10:00'::text
                    WHEN ((starts.event_hour >= 10) AND (starts.event_hour <= 11)) THEN '10:00 - 12:00'::text
                    WHEN ((starts.event_hour >= 12) AND (starts.event_hour <= 13)) THEN '12:00 - 14:00'::text
                    WHEN ((starts.event_hour >= 14) AND (starts.event_hour <= 15)) THEN '14:00 - 16:00'::text
                    WHEN ((starts.event_hour >= 16) AND (starts.event_hour <= 17)) THEN '16:00 - 18:00'::text
                    WHEN ((starts.event_hour >= 18) AND (starts.event_hour <= 19)) THEN '18:00 - 20:00'::text
                    WHEN ((starts.event_hour >= 20) AND (starts.event_hour <= 21)) THEN '20:00 - 22:00'::text
                    ELSE NULL::text
                END AS time_slot,
            count(*) AS parking_starts
           FROM starts
          GROUP BY starts.parking_id, starts.parking_name,
                CASE
                    WHEN ((starts.event_hour >= 6) AND (starts.event_hour <= 7)) THEN '06:00 - 08:00'::text
                    WHEN ((starts.event_hour >= 8) AND (starts.event_hour <= 9)) THEN '08:00 - 10:00'::text
                    WHEN ((starts.event_hour >= 10) AND (starts.event_hour <= 11)) THEN '10:00 - 12:00'::text
                    WHEN ((starts.event_hour >= 12) AND (starts.event_hour <= 13)) THEN '12:00 - 14:00'::text
                    WHEN ((starts.event_hour >= 14) AND (starts.event_hour <= 15)) THEN '14:00 - 16:00'::text
                    WHEN ((starts.event_hour >= 16) AND (starts.event_hour <= 17)) THEN '16:00 - 18:00'::text
                    WHEN ((starts.event_hour >= 18) AND (starts.event_hour <= 19)) THEN '18:00 - 20:00'::text
                    WHEN ((starts.event_hour >= 20) AND (starts.event_hour <= 21)) THEN '20:00 - 22:00'::text
                    ELSE NULL::text
                END
        ), ranked AS (
         SELECT grouped.parking_id,
            grouped.parking_name,
            grouped.time_slot,
            grouped.parking_starts,
            row_number() OVER (PARTITION BY grouped.time_slot ORDER BY grouped.parking_starts DESC) AS ranking
           FROM grouped
        )
 SELECT time_slot,
    parking_id,
    parking_name,
    parking_starts
   FROM ranked
  WHERE (ranking = 1)
  ORDER BY time_slot;

CREATE VIEW "public"."parking_lots_with_availability" AS  SELECT p.id,
    p.name,
    p.address,
    p.latitude,
    p.longitude,
    p.car_spaces,
    p.motorcycle_spaces,
    p.price_per_minute,
    p.opening_time,
    p.closing_time,
    p.created_at,
    (GREATEST((p.car_spaces - count(s.id) FILTER (WHERE ((s.status = 'active'::text) AND (s.vehicle_type = 'car'::text)))), (0)::bigint))::integer AS available_car_spaces,
    (GREATEST((p.motorcycle_spaces - count(s.id) FILTER (WHERE ((s.status = 'active'::text) AND (s.vehicle_type = 'motorcycle'::text)))), (0)::bigint))::integer AS available_motorcycle_spaces
   FROM (public.parking_lots p
     LEFT JOIN public.parking_sessions s ON ((s.parking_id = p.id)))
  GROUP BY p.id, p.name, p.address, p.latitude, p.longitude, p.car_spaces, p.motorcycle_spaces, p.price_per_minute, p.opening_time, p.closing_time, p.created_at;

CREATE POLICY "Create analytics during development" ON "public"."analytics_events"
  FOR INSERT
  TO "anon", "authenticated"
  WITH CHECK (true);

CREATE POLICY "Read analytics during development" ON "public"."analytics_events"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

COMMENT ON EXTENSION "pg_cron" IS 'Job scheduler for PostgreSQL';

GRANT EXECUTE ON FUNCTION "public"."start_parking_session"(uuid, timestamp WITH time zone, text) TO PUBLIC, "anon", "authenticated", "postgres";

GRANT INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."analytics_events" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."analytics_events" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."analytics_events" TO "service_role";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq1_parking_starts_last_7_days" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq1_parking_starts_last_7_days" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq1_parking_starts_last_7_days" TO "service_role";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq2_top_parking_completed_last_7_days" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq2_top_parking_completed_last_7_days" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq2_top_parking_completed_last_7_days" TO "service_role";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq3_parking_flow_abandonment_last_7_days" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq3_parking_flow_abandonment_last_7_days" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq3_parking_flow_abandonment_last_7_days" TO "service_role";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq4_favorite_additions_last_7_days" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq4_favorite_additions_last_7_days" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq4_favorite_additions_last_7_days" TO "service_role";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq5_action_usage_last_7_days" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq5_action_usage_last_7_days" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq5_action_usage_last_7_days" TO "service_role";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq5_least_used_action_last_7_days" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq5_least_used_action_last_7_days" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq5_least_used_action_last_7_days" TO "service_role";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" TO "service_role";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."parking_lots_with_availability" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."parking_lots_with_availability" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."parking_lots_with_availability" TO "service_role";

SELECT cron.schedule_in_database('reset-parking-availability-daily', '0 5 * * *', '
    update public.parking_sessions
    set
      status = ''completed'',
      ended_at = now()
    where status = ''active'';
  ', 'postgres', NULL, true);

