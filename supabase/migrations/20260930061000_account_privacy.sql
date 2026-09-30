-- Al iniciar sesión, favoritos y parqueos deben ser privados por cuenta.
begin;
alter policy "Read favorites during development" on public.favorites to authenticated
  using (user_id = (select auth.uid()));
alter policy "Create favorites during development" on public.favorites to authenticated
  with check (user_id = (select auth.uid()));
alter policy "Delete favorites during development" on public.favorites to authenticated
  using (user_id = (select auth.uid()));
alter policy "Read parking sessions during development" on public.parking_sessions to authenticated
  using (user_id = (select auth.uid()));
alter policy "Create parking sessions during development" on public.parking_sessions to authenticated
  with check (user_id = (select auth.uid()));
alter policy "Update parking sessions during development" on public.parking_sessions to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Esta función cuenta todos los cupos, incluso con RLS activado por usuario.
-- Su contrato anterior se conserva para los otros flujos del equipo.
create or replace function public.start_parking_session(
  p_parking_id uuid, p_pickup_time timestamptz, p_vehicle_type text
) returns public.parking_sessions
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_capacity integer; v_active integer; v_session public.parking_sessions;
begin
  if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
  if p_vehicle_type is null or p_vehicle_type not in ('car','motorcycle') then
    raise exception 'INVALID_VEHICLE_TYPE';
  end if;
  if p_pickup_time is null or p_pickup_time <= now() then raise exception 'INVALID_PICKUP_TIME'; end if;
  perform pg_advisory_xact_lock(hashtextextended('vehicles:' || v_user::text, 0));
  if exists(select 1 from public.parking_sessions where user_id = v_user and status = 'active') then
    raise exception 'ACTIVE_SESSION_EXISTS';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_parking_id::text, 0));
  select case when p_vehicle_type = 'car' then car_spaces else motorcycle_spaces end
    into v_capacity from public.parking_lots where id = p_parking_id;
  if v_capacity is null then raise exception 'PARKING_NOT_FOUND'; end if;
  select count(*) into v_active from public.parking_sessions
    where parking_id = p_parking_id and status = 'active' and vehicle_type = p_vehicle_type;
  if v_active >= v_capacity then raise exception 'NO_AVAILABLE_SPACES'; end if;
  insert into public.parking_sessions(user_id,parking_id,pickup_time,vehicle_type,status)
    values(v_user,p_parking_id,p_pickup_time,p_vehicle_type,'active') returning * into v_session;
  return v_session;
end; $$;
revoke all on function public.start_parking_session(uuid,timestamptz,text) from public,anon;
grant execute on function public.start_parking_session(uuid,timestamptz,text) to authenticated;
commit;
