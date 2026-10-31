-- Rol de solo lectura que usa el panel de Looker Studio.
--
-- Se aplico directo sobre la base y nunca quedo en el repositorio, asi que el
-- historial remoto registraba esta version sin archivo que la respaldara y
-- `db push` se negaba a continuar. El contenido es el mismo que se ejecuto,
-- tomado de supabase_migrations.schema_migrations.
--
-- Unico cambio: CREATE ROLE no admite IF NOT EXISTS y falla si el rol ya esta,
-- asi que va dentro de una guarda para poder reproducir la historia desde cero.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'parku_bi_reader') then
    create role parku_bi_reader
      nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
  end if;
end $$;

grant connect on database postgres to parku_bi_reader;
grant usage on schema public to parku_bi_reader;

grant select on table
  public.bq1_parking_starts_last_7_days,
  public.bq2_top_parking_completed_last_7_days,
  public.bq3_parking_flow_abandonment_last_7_days,
  public.bq4_favorite_additions_last_7_days,
  public.bq5_action_usage_last_7_days,
  public.bq6_top_parking_by_2h_slot_last_30_days
  to parku_bi_reader;

alter role parku_bi_reader set default_transaction_read_only = on;
alter role parku_bi_reader set statement_timeout = '60s';
