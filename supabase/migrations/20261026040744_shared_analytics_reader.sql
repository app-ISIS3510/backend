-- Shared Data Studio dashboard: read only the six aggregated BQ views.
-- Keep NOLOGIN until the project owner sets a credential and enables login.
CREATE ROLE parku_bi_reader NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT CONNECT ON DATABASE postgres TO parku_bi_reader;
GRANT USAGE ON SCHEMA public TO parku_bi_reader;
GRANT SELECT ON TABLE public.bq1_parking_starts_last_7_days, public.bq2_top_parking_completed_last_7_days, public.bq3_parking_flow_abandonment_last_7_days, public.bq4_favorite_additions_last_7_days, public.bq5_action_usage_last_7_days, public.bq6_top_parking_by_2h_slot_last_30_days TO parku_bi_reader;
ALTER ROLE parku_bi_reader SET default_transaction_read_only = on;
ALTER ROLE parku_bi_reader SET statement_timeout = '60s';
