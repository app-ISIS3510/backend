-- Ejecutar como postgres. Todo queda dentro de una transacción que se revierte.
begin;
insert into auth.users(id) values
 ('00000000-0000-4000-a000-000000003001'),
 ('00000000-0000-4000-a000-000000003002');
insert into public.parking_lots(id,name,address,car_spaces,motorcycle_spaces)
 values('00000000-0000-4000-a000-000000003003','Flow 3 test','Test',1,1);
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-a000-000000003001',true);
do $$
declare car public.vehicles; moto public.vehicles; s public.parking_sessions;
begin
  car := public.add_my_vehicle('car',' abc123 ');
  moto := public.add_my_vehicle('motorcycle','xyz45d');
  assert car.plate='ABC123' and car.is_selected, 'Normalize and select first vehicle';
  assert not moto.is_selected, 'Only one selected vehicle';
  perform public.select_my_vehicle(moto.id);
  assert (select count(*) from public.vehicles where is_selected)=1, 'Single selection';
  begin
    perform public.add_my_vehicle('car','ABC12');
    raise exception 'Incomplete plate accepted';
  exception when check_violation then null; end;
  begin
    perform public.add_my_vehicle('car','ABC123');
    raise exception 'Duplicate plate accepted';
  exception when unique_violation then null; end;
  s := public.start_parking_with_vehicle('00000000-0000-4000-a000-000000003003',now()+interval '1 hour',car.id);
  assert s.vehicle_plate='ABC123' and s.vehicle_type='car', 'Session stores chosen vehicle';
  begin
    perform public.delete_my_vehicle(car.id);
    raise exception 'Active vehicle deleted';
  exception when raise_exception then
    if sqlerrm <> 'VEHICLE_IN_USE' then raise; end if;
  end;
  begin
    perform public.start_parking_with_vehicle('00000000-0000-4000-a000-000000003003',now()+interval '1 hour',moto.id);
    raise exception 'Second active session accepted';
  exception when raise_exception then
    if sqlerrm <> 'ACTIVE_SESSION_EXISTS' then raise; end if;
  end;
  insert into public.favorites(user_id,parking_id) values(auth.uid(),'00000000-0000-4000-a000-000000003003');
  perform set_config('flow3.car',car.id::text,true);
end; $$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-a000-000000003002',true);
do $$
declare car public.vehicles;
begin
  assert (select count(*) from public.vehicles)=0, 'Vehicles isolated';
  assert (select count(*) from public.parking_sessions)=0, 'Sessions isolated';
  assert (select count(*) from public.favorites)=0, 'Favorites isolated';
  begin
    perform public.select_my_vehicle(current_setting('flow3.car')::uuid);
    raise exception 'Another account vehicle selected';
  exception when raise_exception then
    if sqlerrm <> 'VEHICLE_NOT_FOUND' then raise; end if;
  end;
  car := public.add_my_vehicle('car','DEF456');
  begin
    perform public.start_parking_with_vehicle('00000000-0000-4000-a000-000000003003',now()+interval '1 hour',car.id);
    raise exception 'Capacity exceeded';
  exception when raise_exception then
    if sqlerrm <> 'NO_AVAILABLE_SPACES' then raise; end if;
  end;
end; $$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-a000-000000003001',true);
do $$
declare moto_id uuid;
begin
  update public.parking_sessions set status='completed', ended_at=now() where user_id=auth.uid();
  select id into moto_id from public.vehicles where vehicle_type='motorcycle';
  perform public.delete_my_vehicle(moto_id);
  assert (select is_selected from public.vehicles where plate='ABC123'), 'Reselect remaining vehicle';
  perform public.delete_my_vehicle(current_setting('flow3.car')::uuid);
  assert (select count(*) from public.vehicles)=0, 'Delete final vehicle';
  assert (select vehicle_plate from public.parking_sessions limit 1)='ABC123', 'Keep historical plate';
  assert (select vehicle_id from public.parking_sessions limit 1) is null, 'Remove deleted vehicle reference';
end; $$;
reset role;
select 'PASS: validation, selection, deletion, ownership, capacity and session snapshot' as flow3_checks;
rollback;
