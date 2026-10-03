-- Flow 3: los vehículos pertenecen a la cuenta de Supabase Auth.
begin;

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  vehicle_type text not null check (vehicle_type in ('car', 'motorcycle')),
  plate text not null,
  is_selected boolean not null default false,
  created_at timestamptz not null default now(),
  unique (user_id, plate),
  check ((vehicle_type = 'car' and plate ~ '^[A-Z]{3}[0-9]{3}$')
      or (vehicle_type = 'motorcycle' and plate ~ '^[A-Z]{3}[0-9]{2}[A-Z]$'))
);
create unique index one_selected_vehicle_per_user
  on public.vehicles(user_id) where is_selected;
alter table public.vehicles enable row level security;
create policy "Read own vehicles" on public.vehicles for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Insert own vehicles" on public.vehicles for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "Update own vehicles" on public.vehicles for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Delete own vehicles" on public.vehicles for delete to authenticated
  using (user_id = (select auth.uid()));
grant select, insert, update, delete on public.vehicles to authenticated;

alter table public.parking_sessions
  add column vehicle_id uuid references public.vehicles(id) on delete set null,
  add column vehicle_plate text;

create function public.add_my_vehicle(p_vehicle_type text, p_plate text)
returns public.vehicles language plpgsql security invoker set search_path = '' as $$
declare v_user uuid := auth.uid(); v_vehicle public.vehicles;
begin
  if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('vehicles:' || v_user::text, 0));
  insert into public.vehicles(user_id, vehicle_type, plate, is_selected)
  values (v_user, p_vehicle_type, upper(trim(p_plate)),
    not exists(select 1 from public.vehicles where user_id = v_user and is_selected))
  returning * into v_vehicle;
  return v_vehicle;
end;
$$;

create function public.select_my_vehicle(p_vehicle_id uuid)
returns void language plpgsql security invoker set search_path = '' as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('vehicles:' || v_user::text, 0));
  if not exists(select 1 from public.vehicles where id = p_vehicle_id and user_id = v_user) then
    raise exception 'VEHICLE_NOT_FOUND';
  end if;
  update public.vehicles set is_selected = false where user_id = v_user and is_selected;
  update public.vehicles set is_selected = true where id = p_vehicle_id and user_id = v_user;
end;
$$;

-- También protege el borrado por REST, no solo el botón de la aplicación.
create function public.guard_vehicle_delete()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if exists(select 1 from public.parking_sessions where vehicle_id = old.id and status = 'active') then
    raise exception 'VEHICLE_IN_USE';
  end if;
  return old;
end;
$$;
create trigger guard_vehicle_delete before delete on public.vehicles
  for each row execute function public.guard_vehicle_delete();

create function public.delete_my_vehicle(p_vehicle_id uuid)
returns void language plpgsql security invoker set search_path = '' as $$
declare v_user uuid := auth.uid(); v_selected boolean;
begin
  if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('vehicles:' || v_user::text, 0));
  select is_selected into v_selected from public.vehicles
    where id = p_vehicle_id and user_id = v_user for update;
  if not found then raise exception 'VEHICLE_NOT_FOUND'; end if;
  delete from public.vehicles where id = p_vehicle_id and user_id = v_user;
  if v_selected then
    update public.vehicles set is_selected = true where id = (
      select id from public.vehicles where user_id = v_user order by created_at, id limit 1
    );
  end if;
end;
$$;

create function public.start_parking_with_vehicle(
  p_parking_id uuid, p_pickup_time timestamptz, p_vehicle_id uuid
) returns public.parking_sessions
language plpgsql security invoker set search_path = '' as $$
declare v_user uuid := auth.uid(); v_vehicle public.vehicles; v_session public.parking_sessions;
begin
  if v_user is null then raise exception 'SIGN_IN_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('vehicles:' || v_user::text, 0));
  select * into v_vehicle from public.vehicles where id = p_vehicle_id and user_id = v_user for update;
  if not found then raise exception 'VEHICLE_NOT_FOUND'; end if;
  if p_pickup_time <= now() then raise exception 'INVALID_PICKUP_TIME'; end if;
  if exists(select 1 from public.parking_sessions where user_id = v_user and status = 'active') then
    raise exception 'ACTIVE_SESSION_EXISTS';
  end if;
  -- Reutiliza el control de capacidad existente del equipo.
  select * into v_session from public.start_parking_session(p_parking_id, p_pickup_time, v_vehicle.vehicle_type);
  update public.parking_sessions set vehicle_id = v_vehicle.id, vehicle_plate = v_vehicle.plate
    where id = v_session.id returning * into v_session;
  return v_session;
end;
$$;

revoke all on function public.add_my_vehicle(text, text) from public, anon;
revoke all on function public.select_my_vehicle(uuid) from public, anon;
revoke all on function public.delete_my_vehicle(uuid) from public, anon;
revoke all on function public.start_parking_with_vehicle(uuid, timestamptz, uuid) from public, anon;
revoke all on function public.guard_vehicle_delete() from public, anon;
grant execute on function public.add_my_vehicle(text, text) to authenticated;
grant execute on function public.select_my_vehicle(uuid) to authenticated;
grant execute on function public.delete_my_vehicle(uuid) to authenticated;
grant execute on function public.start_parking_with_vehicle(uuid, timestamptz, uuid) to authenticated;
commit;
