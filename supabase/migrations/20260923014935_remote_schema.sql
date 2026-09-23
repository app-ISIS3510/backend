DROP POLICY "Authenticated users can read parking lots" ON "public"."parking_lots";

CREATE TABLE "public"."favorites" (
  "id"         uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"    uuid,
  "parking_id" uuid                     NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "favorites_pkey" PRIMARY KEY (id),
  CONSTRAINT "favorites_user_id_parking_id_key" UNIQUE (user_id, parking_id)
);

ALTER TABLE "public"."favorites"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."parking_sessions" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"     uuid,
  "parking_id"  uuid                     NOT NULL,
  "pickup_time" timestamp with time zone NOT NULL,
  "started_at"  timestamp with time zone NOT NULL DEFAULT now(),
  "ended_at"    timestamp with time zone,
  "status"      text                     NOT NULL DEFAULT 'active'::text,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "parking_sessions_pkey" PRIMARY KEY (id),
  CONSTRAINT "parking_sessions_status_check" CHECK ((status = ANY (ARRAY['active'::text, 'completed'::text])))
);

ALTER TABLE "public"."parking_sessions"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."favorites"
  ADD CONSTRAINT "favorites_parking_id_fkey" FOREIGN KEY (parking_id) REFERENCES public.parking_lots(id) ON DELETE CASCADE;

ALTER TABLE "public"."parking_sessions"
  ADD CONSTRAINT "parking_sessions_parking_id_fkey" FOREIGN KEY (parking_id) REFERENCES public.parking_lots(id) ON DELETE CASCADE;

CREATE POLICY "Create favorites during development" ON "public"."favorites"
  FOR INSERT
  TO "anon", "authenticated"
  WITH CHECK (true);

CREATE POLICY "Delete favorites during development" ON "public"."favorites"
  FOR DELETE
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "Read favorites during development" ON "public"."favorites"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "Anyone can read parking lots" ON "public"."parking_lots"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "Create parking sessions during development" ON "public"."parking_sessions"
  FOR INSERT
  TO "anon", "authenticated"
  WITH CHECK (true);

CREATE POLICY "Read parking sessions during development" ON "public"."parking_sessions"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "Update parking sessions during development" ON "public"."parking_sessions"
  FOR UPDATE
  TO "anon", "authenticated"
  USING (true)
  WITH CHECK (true);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."favorites" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."favorites" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."favorites" TO "service_role";

REVOKE ALL ON TABLE "public"."parking_lots" FROM "anon";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."parking_lots" TO "anon";

REVOKE ALL ON TABLE "public"."parking_lots" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."parking_lots" TO "authenticated";

GRANT INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."parking_sessions" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."parking_sessions" TO "postgres";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."parking_sessions" TO "service_role";

