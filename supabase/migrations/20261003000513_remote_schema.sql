SET local check_function_bodies = off;

SELECT cron.unschedule('reset-parking-availability-daily');

REVOKE ALL ON FUNCTION "public"."start_parking_session"(uuid, timestamp WITH time zone, text) FROM "anon";

DROP POLICY "Create analytics during development" ON "public"."analytics_events";

DROP POLICY "Read analytics during development" ON "public"."analytics_events";

DROP POLICY "Create favorites during development" ON "public"."favorites";

DROP POLICY "Delete favorites during development" ON "public"."favorites";

DROP POLICY "Read favorites during development" ON "public"."favorites";

DROP POLICY "Create parking sessions during development" ON "public"."parking_sessions";

DROP POLICY "Read parking sessions during development" ON "public"."parking_sessions";

DROP POLICY "Update parking sessions during development" ON "public"."parking_sessions";

DROP VIEW "public"."bq1_parking_starts_last_7_days";

DROP VIEW "public"."bq4_favorite_additions_last_7_days";

DROP VIEW "public"."bq6_top_parking_by_2h_slot_last_30_days";

DROP VIEW "public"."parking_lots_with_availability";

CREATE TABLE "public"."app_admins" (
  "user_id"    uuid                     NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "app_admins_pkey" PRIMARY KEY (user_id)
);

ALTER TABLE "public"."app_admins"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."vehicles" (
  "id"           uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"      uuid                     NOT NULL,
  "vehicle_type" text                     NOT NULL,
  "plate"        text                     NOT NULL,
  "is_selected"  boolean                  NOT NULL DEFAULT false,
  "created_at"   timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "vehicles_check"
    CHECK ((((vehicle_type = 'car'::text) AND (plate ~ '^[A-Z]{3}[0-9]{3}$'::text)) OR ((vehicle_type = 'motorcycle'::text) AND (plate ~ '^[A-Z]{3}[0-9]{2}[A-Z]$'::text)))),
  CONSTRAINT "vehicles_pkey" PRIMARY KEY (id),
  CONSTRAINT "vehicles_user_id_plate_key" UNIQUE (user_id, plate),
  CONSTRAINT "vehicles_vehicle_type_check" CHECK ((vehicle_type = ANY (ARRAY['car'::text, 'motorcycle'::text])))
);

ALTER TABLE "public"."vehicles"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."parking_sessions"
  ADD COLUMN "vehicle_id" uuid;

ALTER TABLE "public"."parking_sessions"
  ADD COLUMN "vehicle_plate" text;

CREATE OR REPLACE FUNCTION public.add_my_vehicle (
  p_vehicle_type text,
  p_plate        text
)
  RETURNS public.vehicles
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare v_user uuid:=auth.uid(); v_vehicle public.vehicles;
begin
 if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended('vehicles:'||v_user::text,0));
 insert into public.vehicles(user_id,vehicle_type,plate,is_selected) values(v_user,p_vehicle_type,upper(trim(p_plate)),not exists(select 1 from public.vehicles where user_id=v_user and is_selected)) returning * into v_vehicle;
 return v_vehicle;
end; $function$;

REVOKE ALL ON FUNCTION "public"."add_my_vehicle"(text, text) FROM PUBLIC, "anon", "service_role";

CREATE OR REPLACE FUNCTION public.delete_my_vehicle (
  p_vehicle_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare v_user uuid:=auth.uid(); v_selected boolean;
begin
 if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended('vehicles:'||v_user::text,0));
 select is_selected into v_selected from public.vehicles where id=p_vehicle_id and user_id=v_user for update;
 if not found then raise exception 'VEHICLE_NOT_FOUND'; end if;
 delete from public.vehicles where id=p_vehicle_id and user_id=v_user;
 if v_selected then update public.vehicles set is_selected=true where id=(select id from public.vehicles where user_id=v_user order by created_at,id limit 1); end if;
end; $function$;

REVOKE ALL ON FUNCTION "public"."delete_my_vehicle"(uuid) FROM PUBLIC, "anon", "service_role";

CREATE OR REPLACE FUNCTION public.guard_vehicle_delete()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
 if exists(select 1 from public.parking_sessions where vehicle_id=old.id and status='active') then raise exception 'VEHICLE_IN_USE'; end if;
 return old;
end; $function$;

REVOKE ALL ON FUNCTION "public"."guard_vehicle_delete"() FROM PUBLIC, "anon", "authenticated", "service_role";

CREATE OR REPLACE FUNCTION public.select_my_vehicle (
  p_vehicle_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare v_user uuid:=auth.uid();
begin
 if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended('vehicles:'||v_user::text,0));
 if not exists(select 1 from public.vehicles where id=p_vehicle_id and user_id=v_user) then raise exception 'VEHICLE_NOT_FOUND'; end if;
 update public.vehicles set is_selected=false where user_id=v_user and is_selected;
 update public.vehicles set is_selected=true where id=p_vehicle_id and user_id=v_user;
end; $function$;

REVOKE ALL ON FUNCTION "public"."select_my_vehicle"(uuid) FROM PUBLIC, "anon", "service_role";

CREATE OR REPLACE FUNCTION public.start_parking_session (
  p_parking_id   uuid,
  p_pickup_time  timestamp with time zone,
  p_vehicle_type text
)
  RETURNS public.parking_sessions
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare v_user uuid:=auth.uid(); v_capacity integer; v_active integer; v_session public.parking_sessions;
begin
 if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
 if p_vehicle_type is null or p_vehicle_type not in ('car','motorcycle') then raise exception 'INVALID_VEHICLE_TYPE'; end if;
 if p_pickup_time is null or p_pickup_time<=now() then raise exception 'INVALID_PICKUP_TIME'; end if;
 perform pg_advisory_xact_lock(hashtextextended('vehicles:'||v_user::text,0));
 if exists(select 1 from public.parking_sessions where user_id=v_user and status='active') then raise exception 'ACTIVE_SESSION_EXISTS'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_parking_id::text,0));
 select case when p_vehicle_type='car' then car_spaces else motorcycle_spaces end into v_capacity from public.parking_lots where id=p_parking_id;
 if v_capacity is null then raise exception 'PARKING_NOT_FOUND'; end if;
 select count(*) into v_active from public.parking_sessions where parking_id=p_parking_id and status='active' and vehicle_type=p_vehicle_type;
 if v_active>=v_capacity then raise exception 'NO_AVAILABLE_SPACES'; end if;
 insert into public.parking_sessions(user_id,parking_id,pickup_time,vehicle_type,status) values(v_user,p_parking_id,p_pickup_time,p_vehicle_type,'active') returning * into v_session;
 return v_session;
end; $function$;

CREATE OR REPLACE FUNCTION public.start_parking_with_vehicle (
  p_parking_id  uuid,
  p_pickup_time timestamp with time zone,
  p_vehicle_id  uuid
)
  RETURNS public.parking_sessions
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare v_user uuid:=auth.uid(); v_vehicle public.vehicles; v_session public.parking_sessions;
begin
 if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended('vehicles:'||v_user::text,0));
 select * into v_vehicle from public.vehicles where id=p_vehicle_id and user_id=v_user for update;
 if not found then raise exception 'VEHICLE_NOT_FOUND'; end if;
 if p_pickup_time<=now() then raise exception 'INVALID_PICKUP_TIME'; end if;
 if exists(select 1 from public.parking_sessions where user_id=v_user and status='active') then raise exception 'ACTIVE_SESSION_EXISTS'; end if;
 select * into v_session from public.start_parking_session(p_parking_id,p_pickup_time,v_vehicle.vehicle_type);
 update public.parking_sessions set vehicle_id=v_vehicle.id,vehicle_plate=v_vehicle.plate where id=v_session.id returning * into v_session;
 return v_session;
end; $function$;

REVOKE ALL ON FUNCTION "public"."start_parking_with_vehicle"(uuid, timestamp WITH time zone, uuid) FROM PUBLIC, "anon", "service_role";

ALTER TABLE "public"."app_admins"
  ADD CONSTRAINT "app_admins_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."parking_sessions"
  ADD CONSTRAINT "parking_sessions_vehicle_id_fkey" FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id) ON DELETE SET NULL;

ALTER TABLE "public"."vehicles"
  ADD CONSTRAINT "vehicles_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

CREATE VIEW "public"."bq1_parking_starts_last_7_days" AS  SELECT date((created_at AT TIME ZONE 'America/Bogota'::text)) AS day,
    count(*) AS parking_sessions_started
   FROM public.analytics_events
  WHERE ((event_type = 'parking_started'::text) AND (created_at >= (now() - '7 days'::interval)))
  GROUP BY (date((created_at AT TIME ZONE 'America/Bogota'::text)))
  ORDER BY (date((created_at AT TIME ZONE 'America/Bogota'::text)));

CREATE VIEW "public"."bq4_favorite_additions_last_7_days" AS  SELECT count(DISTINCT user_id) AS favorite_add_events
   FROM public.analytics_events
  WHERE ((event_type = 'favorite_added'::text) AND (user_id IS NOT NULL) AND (created_at >= (now() - '7 days'::interval)));

CREATE VIEW "public"."bq4_users_with_favorites_last_7_days" AS  SELECT count(DISTINCT user_id) AS users_with_favorites
   FROM public.analytics_events
  WHERE ((event_type = 'favorite_added'::text) AND (user_id IS NOT NULL) AND (created_at >= (now() - '7 days'::interval)));

CREATE VIEW "public"."bq6_top_parking_by_2h_slot_last_30_days" AS  WITH starts AS (
         SELECT a.parking_id,
            p.name AS parking_name,
            (EXTRACT(hour FROM (a.created_at AT TIME ZONE 'America/Bogota'::text)))::integer AS event_hour
           FROM (public.analytics_events a
             JOIN public.parking_lots p ON ((p.id = a.parking_id)))
          WHERE ((a.event_type = 'parking_started'::text) AND (a.created_at >= (now() - '30 days'::interval)) AND (EXTRACT(hour FROM (a.created_at AT TIME ZONE 'America/Bogota'::text)) >= (6)::numeric) AND (EXTRACT(hour FROM (a.created_at AT TIME ZONE 'America/Bogota'::text)) < (22)::numeric))
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

CREATE VIEW "public"."parking_lots_with_availability" AS  WITH context AS (
         SELECT (EXTRACT(dow FROM (now() AT TIME ZONE 'America/Bogota'::text)))::integer AS current_dow,
            ((floor((EXTRACT(hour FROM (now() AT TIME ZONE 'America/Bogota'::text)) / (2)::numeric)) * (2)::numeric))::integer AS current_slot_start
        ), current_availability AS (
         SELECT p.id,
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
            (GREATEST((p.car_spaces - count(s.id) FILTER (WHERE ((s.status = 'active'::text) AND (s.vehicle_type = 'car'::text)))), (0)::bigint))::integer AS real_car_availability,
            (GREATEST((p.motorcycle_spaces - count(s.id) FILTER (WHERE ((s.status = 'active'::text) AND (s.vehicle_type = 'motorcycle'::text)))), (0)::bigint))::integer AS real_motorcycle_availability
           FROM (public.parking_lots p
             LEFT JOIN public.parking_sessions s ON ((s.parking_id = p.id)))
          GROUP BY p.id, p.name, p.address, p.latitude, p.longitude, p.car_spaces, p.motorcycle_spaces, p.price_per_minute, p.opening_time, p.closing_time, p.created_at
        ), session_context AS (
         SELECT ps.parking_id,
            ps.vehicle_type,
            date((ps.started_at AT TIME ZONE 'America/Bogota'::text)) AS local_date,
            (EXTRACT(dow FROM (ps.started_at AT TIME ZONE 'America/Bogota'::text)))::integer AS session_dow,
            ((floor((EXTRACT(hour FROM (ps.started_at AT TIME ZONE 'America/Bogota'::text)) / (2)::numeric)) * (2)::numeric))::integer AS slot_start
           FROM public.parking_sessions ps
        ), same_weekday_slot AS (
         SELECT sc.parking_id,
            sc.vehicle_type,
            count(*) AS session_count,
            ((count(*))::numeric / (NULLIF(count(DISTINCT sc.local_date), 0))::numeric) AS avg_sessions_per_day
           FROM (session_context sc
             CROSS JOIN context c_1)
          WHERE ((sc.session_dow = c_1.current_dow) AND (sc.slot_start = c_1.current_slot_start))
          GROUP BY sc.parking_id, sc.vehicle_type
        ), same_slot_all_days AS (
         SELECT sc.parking_id,
            sc.vehicle_type,
            count(*) AS session_count,
            ((count(*))::numeric / (NULLIF(count(DISTINCT sc.local_date), 0))::numeric) AS avg_sessions_per_day
           FROM (session_context sc
             CROSS JOIN context c_1)
          WHERE (sc.slot_start = c_1.current_slot_start)
          GROUP BY sc.parking_id, sc.vehicle_type
        ), prediction AS (
         SELECT p.id AS parking_id,
                CASE
                    WHEN (car_week.session_count >= 3) THEN car_week.avg_sessions_per_day
                    WHEN (car_slot.session_count >= 3) THEN car_slot.avg_sessions_per_day
                    ELSE NULL::numeric
                END AS expected_car_demand,
                CASE
                    WHEN (moto_week.session_count >= 3) THEN moto_week.avg_sessions_per_day
                    WHEN (moto_slot.session_count >= 3) THEN moto_slot.avg_sessions_per_day
                    ELSE NULL::numeric
                END AS expected_motorcycle_demand
           FROM ((((public.parking_lots p
             LEFT JOIN same_weekday_slot car_week ON (((car_week.parking_id = p.id) AND (car_week.vehicle_type = 'car'::text))))
             LEFT JOIN same_slot_all_days car_slot ON (((car_slot.parking_id = p.id) AND (car_slot.vehicle_type = 'car'::text))))
             LEFT JOIN same_weekday_slot moto_week ON (((moto_week.parking_id = p.id) AND (moto_week.vehicle_type = 'motorcycle'::text))))
             LEFT JOIN same_slot_all_days moto_slot ON (((moto_slot.parking_id = p.id) AND (moto_slot.vehicle_type = 'motorcycle'::text))))
        )
 SELECT c.id,
    c.name,
    c.address,
    c.latitude,
    c.longitude,
    c.car_spaces,
    c.motorcycle_spaces,
    c.price_per_minute,
    c.opening_time,
    c.closing_time,
    c.created_at,
        CASE
            WHEN (pr.expected_car_demand IS NULL) THEN c.real_car_availability
            ELSE LEAST(c.real_car_availability, (GREATEST(round(((0.75 * (c.real_car_availability)::numeric) + (0.25 * GREATEST(((c.car_spaces)::numeric - pr.expected_car_demand), (0)::numeric)))), (0)::numeric))::integer)
        END AS available_car_spaces,
        CASE
            WHEN (pr.expected_motorcycle_demand IS NULL) THEN c.real_motorcycle_availability
            ELSE LEAST(c.real_motorcycle_availability, (GREATEST(round(((0.75 * (c.real_motorcycle_availability)::numeric) + (0.25 * GREATEST(((c.motorcycle_spaces)::numeric - pr.expected_motorcycle_demand), (0)::numeric)))), (0)::numeric))::integer)
        END AS available_motorcycle_spaces
   FROM (current_availability c
     LEFT JOIN prediction pr ON ((pr.parking_id = c.id)));

CREATE UNIQUE INDEX one_selected_vehicle_per_user ON public.vehicles USING btree (user_id)
  WHERE is_selected;

CREATE TRIGGER guard_vehicle_delete
  BEFORE DELETE ON public.vehicles
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_vehicle_delete();

CREATE POLICY "Authenticated users can read analytics" ON "public"."analytics_events"
  FOR SELECT
  TO "authenticated"
  USING (true);

CREATE POLICY "Users can create their own analytics" ON "public"."analytics_events"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((auth.uid() = user_id));

CREATE POLICY "Users can check own admin status" ON "public"."app_admins"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = auth.uid()));

CREATE POLICY "Create favorites during development" ON "public"."favorites"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Delete favorites during development" ON "public"."favorites"
  FOR DELETE
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Read favorites during development" ON "public"."favorites"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Create parking sessions during development" ON "public"."parking_sessions"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Read parking sessions during development" ON "public"."parking_sessions"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Update parking sessions during development" ON "public"."parking_sessions"
  FOR UPDATE
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)))
  WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Delete own vehicles" ON "public"."vehicles"
  FOR DELETE
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Insert own vehicles" ON "public"."vehicles"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Read own vehicles" ON "public"."vehicles"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Update own vehicles" ON "public"."vehicles"
  FOR UPDATE
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)))
  WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));

GRANT EXECUTE ON FUNCTION "public"."add_my_vehicle"(text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."add_my_vehicle"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."add_my_vehicle"(text, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."delete_my_vehicle"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."delete_my_vehicle"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."delete_my_vehicle"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "public"."guard_vehicle_delete"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."guard_vehicle_delete"() TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."select_my_vehicle"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."select_my_vehicle"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."select_my_vehicle"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "public"."start_parking_session"(uuid, timestamp WITH time zone, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."start_parking_with_vehicle"(uuid, timestamp WITH time zone, uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."start_parking_with_vehicle"(uuid, timestamp WITH time zone, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."start_parking_with_vehicle"(uuid, timestamp WITH time zone, uuid) TO "postgres";

REVOKE ALL ON TABLE "public"."app_admins" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."app_admins" TO "anon";

REVOKE ALL ON TABLE "public"."app_admins" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."app_admins" TO "authenticated";

REVOKE ALL ON TABLE "public"."app_admins" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."app_admins" TO "postgres";

REVOKE ALL ON TABLE "public"."app_admins" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."app_admins" TO "service_role";

REVOKE ALL ON TABLE "public"."vehicles" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."vehicles" TO "anon";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."vehicles" TO "authenticated";

REVOKE ALL ON TABLE "public"."vehicles" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."vehicles" TO "postgres";

REVOKE ALL ON TABLE "public"."vehicles" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."vehicles" TO "service_role";

REVOKE ALL ON TABLE "public"."bq1_parking_starts_last_7_days" FROM "anon";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq1_parking_starts_last_7_days" TO "anon";

REVOKE ALL ON TABLE "public"."bq1_parking_starts_last_7_days" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq1_parking_starts_last_7_days" TO "authenticated";

REVOKE ALL ON TABLE "public"."bq1_parking_starts_last_7_days" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq1_parking_starts_last_7_days" TO "postgres";

REVOKE ALL ON TABLE "public"."bq1_parking_starts_last_7_days" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq1_parking_starts_last_7_days" TO "service_role";

REVOKE ALL ON TABLE "public"."bq4_favorite_additions_last_7_days" FROM "anon";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq4_favorite_additions_last_7_days" TO "anon";

REVOKE ALL ON TABLE "public"."bq4_favorite_additions_last_7_days" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq4_favorite_additions_last_7_days" TO "authenticated";

REVOKE ALL ON TABLE "public"."bq4_favorite_additions_last_7_days" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq4_favorite_additions_last_7_days" TO "postgres";

REVOKE ALL ON TABLE "public"."bq4_favorite_additions_last_7_days" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq4_favorite_additions_last_7_days" TO "service_role";

REVOKE ALL ON TABLE "public"."bq4_users_with_favorites_last_7_days" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq4_users_with_favorites_last_7_days" TO "anon";

REVOKE ALL ON TABLE "public"."bq4_users_with_favorites_last_7_days" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq4_users_with_favorites_last_7_days" TO "authenticated";

REVOKE ALL ON TABLE "public"."bq4_users_with_favorites_last_7_days" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq4_users_with_favorites_last_7_days" TO "postgres";

REVOKE ALL ON TABLE "public"."bq4_users_with_favorites_last_7_days" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq4_users_with_favorites_last_7_days" TO "service_role";

REVOKE ALL ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" FROM "anon";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" TO "anon";

REVOKE ALL ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" TO "authenticated";

REVOKE ALL ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" TO "postgres";

REVOKE ALL ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."bq6_top_parking_by_2h_slot_last_30_days" TO "service_role";

REVOKE ALL ON TABLE "public"."parking_lots_with_availability" FROM "anon";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."parking_lots_with_availability" TO "anon";

REVOKE ALL ON TABLE "public"."parking_lots_with_availability" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."parking_lots_with_availability" TO "authenticated";

REVOKE ALL ON TABLE "public"."parking_lots_with_availability" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."parking_lots_with_availability" TO "postgres";

REVOKE ALL ON TABLE "public"."parking_lots_with_availability" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."parking_lots_with_availability" TO "service_role";

SELECT cron.schedule_in_database('reset-parking-availability-daily', '0 5 * * *', '
    update public.parking_sessions
    set
      status = ''completed'',
      ended_at = now()
    where status = ''active'';
  ', 'postgres', NULL, true);

ALTER TABLE "public"."analytics_events"
  ALTER COLUMN "user_id" SET DEFAULT auth.uid();

