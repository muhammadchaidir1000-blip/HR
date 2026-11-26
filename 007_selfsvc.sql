-- 007_selfsvc.sql · Layanan mandiri karyawan
--  * siklus pengajuan: batal (staf), Revisi (atasan/HRD, alasan wajib) → staf ubah & ajukan ulang
--  * hr_requests: koreksi absensi, ubah jadwal, perjalanan dinas, perubahan data, pembatalan cuti/lembur
--  * absen online (GPS + swafoto, radius lokasi)            → public.att_clock
--  * tugas tim (hr_tasks) & aktivitas harian (hr_activity)  → public.task_* / team_tasks / team_activity

-- ---------- aturan pengajuan staf ----------
create or replace function app.staff_pending(c text, d jsonb) returns boolean language sql immutable set search_path = '' as $$
  select case
    when c in ('leaves','overtime','hr_requests') then coalesce(d->>'status','') = 'Menunggu'
      and not jsonb_path_exists(d, '$.steps[*] ? (@.status != "Menunggu")')
      and jsonb_array_length(coalesce(d->'steps','[]'::jsonb)) > 0
      and (c = 'leaves' or length(trim(coalesce(d->>'note',''))) >= 5)
    when c = 'hr_claims' then coalesce(d->>'status','') = 'submitted' and (d->'approvedTotal') is null
    else false end $$;

-- baris lama yang masih boleh diubah staf: menunggu tanpa keputusan, atau dikembalikan untuk revisi
create or replace function app.staff_open(c text, d jsonb) returns boolean language sql immutable set search_path = '' as $$
  select app.staff_pending(c, d) or (c in ('leaves','overtime','hr_requests') and coalesce(d->>'status','') = 'Revisi') $$;
-- isi baru yang boleh ditulis staf: diajukan (ulang) dari awal, atau dibatalkan sendiri
create or replace function app.staff_newok(c text, d jsonb) returns boolean language sql immutable set search_path = '' as $$
  select app.staff_pending(c, d) or (c in ('leaves','overtime','hr_requests') and coalesce(d->>'status','') = 'Dibatalkan'
    and not jsonb_path_exists(d, '$.steps[*] ? (@.status == "Ditolak")')) $$;
grant execute on function app.staff_open(text, jsonb), app.staff_newok(text, jsonb) to authenticated;

-- ---------- pemilik baris (owner_id) mengikuti akun karyawan ----------
create or replace function app.docs_before() returns trigger language plpgsql security definer set search_path = '' as $$
declare r text; o text;
begin
  new.updated_at := now();
  if new.collection = 'accounts' then
    new.data := new.data - 'passHash' - 'salt' - 'initPass';
    new.company_id := nullif(new.data->>'companyId','');
    new.owner_id := new.id;
    select p.role into r from public.profiles p where p.account_id = new.id;
    if r is not null then new.data := new.data || jsonb_build_object('role', r); end if;
  elsif new.collection = 'companies' then
    new.company_id := new.id;
  elsif new.collection in ('att_month','leaves','hr_claims','pay_slips','overtime','hr_requests','hr_tasks','hr_activity') then
    new.company_id := coalesce(nullif(new.data->>'companyId',''), new.company_id);
    select e.owner_id into o from public.docs e
      where e.collection = 'employees' and e.id = new.data->>'employeeId' and e.company_id = new.company_id;
    new.owner_id := o;
  elsif new.collection <> 'initpass' then
    new.company_id := coalesce(nullif(new.data->>'companyId',''), new.company_id);
    new.owner_id := coalesce(nullif(new.data->>'accountId',''), new.owner_id);
  end if;
  return new;
end $$;

create or replace function app.docs_after_emp() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.owner_id is distinct from old.owner_id then
    update public.docs set owner_id = new.owner_id
      where collection in ('att_month','leaves','hr_claims','pay_slips','overtime','hr_requests','hr_tasks','hr_activity') and data->>'employeeId' = new.id
        and owner_id is distinct from new.owner_id;
  end if;
  return new;
end $$;

-- ---------- RLS ----------
drop policy if exists docs_insert on public.docs;
create policy docs_insert on public.docs for insert to authenticated with check (
  (select app.my_role()) = 'superadmin'
  or ((select app.my_role()) = 'company' and collection not in ('initpass','companies','accounts')
      and company_id = (select app.my_company()))
  or ((select app.my_role()) = 'user' and company_id = (select app.my_company())
      and owner_id = (select app.my_account())
      and (collection in ('disc_sessions','ist_sessions','papi_sessions','skill_sessions','disc_results','ist_results','papi_results','skill_results','audit')
           or (collection in ('leaves','hr_claims','overtime','hr_requests') and (select app.my_employee()) is not null
               and data->>'employeeId' = (select app.my_employee()) and app.staff_pending(collection, data))
           or (collection = 'hr_activity' and (select app.my_employee()) is not null and data->>'employeeId' = (select app.my_employee()))))
);

drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update to authenticated using (
  (select app.my_role()) = 'superadmin'
  or ((select app.my_role()) = 'company' and collection <> 'initpass' and company_id = (select app.my_company()))
  or ((select app.my_role()) = 'user' and company_id = (select app.my_company())
      and owner_id = (select app.my_account())
      and (collection in ('accounts','disc_sessions','ist_sessions','papi_sessions','skill_sessions','disc_results','ist_results','papi_results','skill_results','audit','hr_activity')
           or (collection in ('leaves','hr_claims','overtime','hr_requests') and app.staff_open(collection, data))))
) with check (
  (select app.my_role()) = 'superadmin'
  or ((select app.my_role()) = 'company' and collection <> 'initpass' and company_id = (select app.my_company()))
  or ((select app.my_role()) = 'user' and company_id = (select app.my_company())
      and owner_id = (select app.my_account())
      and (collection in ('accounts','disc_sessions','ist_sessions','papi_sessions','skill_sessions','disc_results','ist_results','papi_results','skill_results','audit')
           or (collection = 'hr_activity' and data->>'employeeId' = (select app.my_employee()))
           or (collection in ('leaves','hr_claims','overtime','hr_requests') and data->>'employeeId' = (select app.my_employee()) and app.staff_newok(collection, data))))
);

drop policy if exists docs_delete on public.docs;
create policy docs_delete on public.docs for delete to authenticated using (
  (select app.my_role()) = 'superadmin'
  or ((select app.my_role()) = 'company' and collection not in ('initpass','companies') and company_id = (select app.my_company()))
  or ((select app.my_role()) = 'user' and company_id = (select app.my_company())
      and owner_id = (select app.my_account())
      and (collection in ('disc_sessions','ist_sessions','papi_sessions','skill_sessions','hr_activity')
           or (collection in ('leaves','hr_claims','overtime','hr_requests') and app.staff_pending(collection, data))))
);

-- ---------- persetujuan pimpinan: setujui / tolak / minta revisi ----------
create or replace function public.team_requests(p_days int default 120) returns table (col text, id text, lvl int, data jsonb)
language sql stable security definer set search_path = '' as $$
  select d.collection, d.id, app.lead_level(d.data->>'employeeId'), d.data from public.docs d
  where d.collection in ('leaves','overtime','hr_requests') and d.company_id = app.my_company()
    and d.data->>'employeeId' in (select app.team_ids())
    and jsonb_array_length(coalesce(d.data->'steps','[]'::jsonb)) > 0
    and d.updated_at > now() - make_interval(days => least(greatest(coalesce(p_days,120),1),400))
  order by d.updated_at desc limit 500 $$;

create or replace function public.team_act(p_col text, p_id text, p_act text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d jsonb; st jsonb; i int; n int; lvl int; uname text; fin text; ns text;
begin
  if p_col not in ('leaves','overtime','hr_requests') or p_act not in ('ok','no','rev') then raise exception 'bad_input'; end if;
  select x.data into d from public.docs x where x.collection = p_col and x.id = p_id and x.company_id = app.my_company() for update;
  if d is null then raise exception 'not_found'; end if;
  if not ((d->>'employeeId') in (select app.team_ids())) then raise exception 'forbidden'; end if;
  if coalesce(d->>'status','Menunggu') <> 'Menunggu' then raise exception 'not_pending'; end if;
  st := coalesce(d->'steps','[]'::jsonb); n := jsonb_array_length(st);
  if exists (select 1 from jsonb_array_elements(st) s where s->>'status' in ('Ditolak','Revisi')) then raise exception 'not_pending'; end if;
  select min(o - 1) into i from jsonb_array_elements(st) with ordinality as t(s, o) where s->>'status' = 'Menunggu';
  if i is null then raise exception 'not_pending'; end if;
  if i >= n - 1 then raise exception 'hrd_step'; end if;  -- tahap terakhir = HRD
  lvl := app.lead_level(d->>'employeeId');
  if lvl < i + 1 then raise exception 'not_your_step'; end if;
  if p_act <> 'ok' and length(trim(coalesce(p_note,''))) < 3 then raise exception 'note_required'; end if;
  select a.data->>'username' into uname from public.docs a where a.collection = 'accounts' and a.id = app.my_account();
  ns := case p_act when 'ok' then 'Disetujui' when 'no' then 'Ditolak' else 'Revisi' end;
  st := jsonb_set(st, array[i::text], (st->i) || jsonb_build_object('status', ns, 'by', uname, 'at', now(), 'note', left(coalesce(p_note,''),200), 'byLead', true));
  fin := case when p_act = 'no' then 'Ditolak' when p_act = 'rev' then 'Revisi'
              when not exists (select 1 from jsonb_array_elements(st) s where s->>'status' <> 'Disetujui') then 'Disetujui' else 'Menunggu' end;
  update public.docs set data = d || jsonb_build_object('steps', st, 'status', fin) where collection = p_col and id = p_id;
  return jsonb_build_object('status', fin, 'step', i);
end $$;

create or replace function public.team_decide(p_col text, p_id text, p_ok boolean, p_note text default '') returns jsonb
language sql security definer set search_path = '' as $$ select public.team_act(p_col, p_id, case when p_ok then 'ok' else 'no' end, p_note) $$;

-- ---------- absen online ----------
-- hr_config.geo = { on:bool, selfie:bool, sites:[{name,lat,lng,radius}] }
create or replace function app.geo_m(a_lat float8, a_lng float8, b_lat float8, b_lng float8) returns float8 language sql immutable set search_path = '' as $$
  select 2 * 6371000 * asin(sqrt(power(sin(radians(b_lat - a_lat) / 2), 2) + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2))) $$;

create or replace function public.att_clock(p_lat float8, p_lng float8, p_acc float8 default null, p_photo jsonb default null, p_note text default '') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare me text := app.my_employee(); co text := app.my_company(); geo jsonb; s jsonb; best float8; best_site text; dm float8;
        loc timestamp := now() at time zone 'Asia/Jakarta'; t text; mon text; dd text; did text; cur jsonb; last text;
begin
  if app.my_role() <> 'user' or me is null then raise exception 'forbidden'; end if;
  select x.data->'geo' into geo from public.docs x where x.collection = 'hr_config' and x.id = co;
  if geo is null or coalesce((geo->>'on')::boolean, false) = false then raise exception 'geo_off'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'bad_input'; end if;
  for s in select * from jsonb_array_elements(coalesce(geo->'sites','[]'::jsonb)) loop
    dm := app.geo_m(p_lat, p_lng, (s->>'lat')::float8, (s->>'lng')::float8);
    if best is null or dm - coalesce((s->>'radius')::float8, 100) < best then best := dm - coalesce((s->>'radius')::float8, 100); best_site := s->>'name'; end if;
  end loop;
  if best is null then raise exception 'geo_off'; end if;
  if best > 0 then raise exception 'out_of_area:%', round(best)::int; end if;
  if coalesce((geo->>'selfie')::boolean, false) and (p_photo is null or coalesce(p_photo->>'path','') = '') then raise exception 'selfie_required'; end if;
  if p_photo is not null and split_part(coalesce(p_photo->>'path',''), '/', 1) || '/' || split_part(coalesce(p_photo->>'path',''), '/', 2) <> co || '/' || me then raise exception 'bad_input'; end if;
  t := to_char(loc, 'HH24:MI'); mon := to_char(loc, 'YYYY-MM'); dd := to_char(loc, 'DD'); did := me || '__' || mon;
  select x.data into cur from public.docs x where x.collection = 'att_month' and x.id = did for update;
  if cur is null then cur := jsonb_build_object('companyId', co, 'employeeId', me, 'month', mon, 'sched', '{}'::jsonb, 'scans', '{}'::jsonb, 'fix', '{}'::jsonb); end if;
  select e->>'at' into last from jsonb_array_elements(coalesce(cur->'web'->dd, '[]'::jsonb)) e order by e->>'at' desc limit 1;
  if last is not null and last::timestamptz > now() - interval '2 minutes' then raise exception 'too_soon'; end if;
  cur := jsonb_set(cur, '{scans}', coalesce(cur->'scans','{}'::jsonb) || jsonb_build_object(dd, coalesce(cur->'scans'->dd, '[]'::jsonb) || to_jsonb(t)));
  cur := jsonb_set(cur, '{web}', coalesce(cur->'web','{}'::jsonb) || jsonb_build_object(dd, coalesce(cur->'web'->dd, '[]'::jsonb) || jsonb_build_object(
    't', t, 'at', now(), 'lat', round(p_lat::numeric, 6), 'lng', round(p_lng::numeric, 6), 'acc', round(coalesce(p_acc,0)::numeric), 'site', best_site,
    'dist', round(greatest(best + coalesce((select (x->>'radius')::float8 from jsonb_array_elements(geo->'sites') x where x->>'name' = best_site limit 1), 100), 0)::numeric),
    'photo', p_photo, 'note', left(coalesce(p_note,''), 120))));
  cur := cur || jsonb_build_object('updatedAt', now());
  insert into public.docs (collection, id, company_id, data) values ('att_month', did, co, cur)
    on conflict (collection, id) do update set data = excluded.data;
  return jsonb_build_object('t', t, 'date', to_char(loc, 'YYYY-MM-DD'), 'site', best_site);
end $$;

-- data scan tim untuk satu tanggal (pimpinan: siapa sudah absen hari ini)
create or replace function public.team_day(p_date text) returns table (employee_id text, sched text, scans jsonb, web jsonb, fix jsonb)
language sql stable security definer set search_path = '' as $$
  select d.data->>'employeeId', d.data->'sched'->>substr(p_date, 9, 2), coalesce(d.data->'scans'->substr(p_date, 9, 2), '[]'::jsonb),
         coalesce(d.data->'web'->substr(p_date, 9, 2), '[]'::jsonb), d.data->'fix'->substr(p_date, 9, 2)
  from public.docs d
  where p_date ~ '^\d{4}-\d{2}-\d{2}$' and d.collection = 'att_month' and d.company_id = app.my_company() and d.data->>'month' = substr(p_date, 1, 7)
    and (d.data->>'employeeId' in (select app.team_ids()) or (d.data->>'employeeId' = app.my_employee() and exists (select 1 from app.team_ids()))) $$;

-- ---------- tugas tim ----------
-- hr_tasks/<id>: { employeeId, title, desc, due, priority, status: Baru|Dikerjakan|Selesai|Dibatalkan, byEmp, byName, log:[], rating, feedback }
create or replace function app.task_mine(d jsonb) returns boolean language sql stable security definer set search_path = '' as $$
  select d->>'byEmp' = app.my_employee() or app.lead_level(d->>'employeeId') > 0 $$;

create or replace function public.task_create(p_emps text[], p_task jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare me text := app.my_employee(); co text := app.my_company(); e text; n int := 0; nm text; uname text; grp text := 'g' || replace(gen_random_uuid()::text, '-', '');
begin
  if app.my_role() <> 'user' or me is null then raise exception 'forbidden'; end if;
  if coalesce(array_length(p_emps, 1), 0) = 0 or array_length(p_emps, 1) > 100 then raise exception 'bad_input'; end if;
  if length(trim(coalesce(p_task->>'title',''))) < 3 then raise exception 'bad_input'; end if;
  if coalesce(p_task->>'priority','Sedang') not in ('Rendah','Sedang','Tinggi','Mendesak') then raise exception 'bad_input'; end if;
  if coalesce(p_task->>'due','') !~ '^(\d{4}-\d{2}-\d{2})?$' then raise exception 'bad_input'; end if;
  select x.data->>'name' into nm from public.docs x where x.collection = 'employees' and x.id = me;
  select a.data->>'username' into uname from public.docs a where a.collection = 'accounts' and a.id = app.my_account();
  foreach e in array p_emps loop
    if not (e in (select app.team_ids())) then raise exception 'forbidden'; end if;
    insert into public.docs (collection, id, company_id, data) values ('hr_tasks', 't' || replace(gen_random_uuid()::text, '-', ''), co, jsonb_build_object(
      'companyId', co, 'employeeId', e, 'group', grp, 'title', left(trim(p_task->>'title'), 140), 'desc', left(coalesce(p_task->>'desc',''), 2000),
      'due', coalesce(p_task->>'due',''), 'priority', coalesce(p_task->>'priority','Sedang'), 'status', 'Baru', 'byEmp', me, 'byName', nm, 'by', uname,
      'createdAt', now(), 'log', jsonb_build_array(jsonb_build_object('at', now(), 'by', nm, 'status', 'Baru', 'note', 'Tugas diberikan'))));
    n := n + 1;
  end loop;
  return n;
end $$;

-- ubah status / tambah catatan: penerima tugas atau pemberi tugas / atasannya
create or replace function public.task_update(p_id text, p_status text, p_note text default '', p_files jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d jsonb; me text := app.my_employee(); nm text; own boolean; boss boolean;
begin
  if app.my_role() <> 'user' or me is null then raise exception 'forbidden'; end if;
  select x.data into d from public.docs x where x.collection = 'hr_tasks' and x.id = p_id and x.company_id = app.my_company() for update;
  if d is null then raise exception 'not_found'; end if;
  own := d->>'employeeId' = me; boss := app.task_mine(d);
  if not (own or boss) then raise exception 'forbidden'; end if;
  if p_status not in ('Baru','Dikerjakan','Selesai','Dibatalkan') or (p_status = 'Dibatalkan' and not boss) then raise exception 'bad_input'; end if;
  if p_files is not null and jsonb_typeof(p_files) <> 'array' then raise exception 'bad_input'; end if;
  select x.data->>'name' into nm from public.docs x where x.collection = 'employees' and x.id = me;
  d := d || jsonb_build_object('status', p_status, 'updatedAt', now(),
    'log', coalesce(d->'log','[]'::jsonb) || jsonb_build_object('at', now(), 'by', nm, 'status', p_status, 'note', left(coalesce(p_note,''), 500)),
    'files', coalesce(d->'files','[]'::jsonb) || coalesce(p_files, '[]'::jsonb));
  if p_status = 'Selesai' and d->>'doneAt' is null then d := d || jsonb_build_object('doneAt', now()); end if;
  update public.docs set data = d where collection = 'hr_tasks' and id = p_id;
  return jsonb_build_object('status', p_status);
end $$;

create or replace function public.task_rate(p_id text, p_rating int, p_feedback text default '') returns void
language plpgsql security definer set search_path = '' as $$
declare d jsonb; nm text;
begin
  if app.my_role() <> 'user' or app.my_employee() is null then raise exception 'forbidden'; end if;
  select x.data into d from public.docs x where x.collection = 'hr_tasks' and x.id = p_id and x.company_id = app.my_company() for update;
  if d is null then raise exception 'not_found'; end if;
  if not app.task_mine(d) then raise exception 'forbidden'; end if;
  if d->>'status' <> 'Selesai' or p_rating not between 1 and 5 then raise exception 'bad_input'; end if;
  select x.data->>'name' into nm from public.docs x where x.collection = 'employees' and x.id = app.my_employee();
  update public.docs set data = d || jsonb_build_object('rating', p_rating, 'feedback', left(coalesce(p_feedback,''), 500), 'ratedBy', nm, 'ratedAt', now())
    where collection = 'hr_tasks' and id = p_id;
end $$;

create or replace function public.team_tasks(p_days int default 120) returns table (id text, data jsonb)
language sql stable security definer set search_path = '' as $$
  select d.id, d.data from public.docs d
  where d.collection = 'hr_tasks' and d.company_id = app.my_company() and app.my_role() = 'user'
    and (d.data->>'byEmp' = app.my_employee() or d.data->>'employeeId' in (select app.team_ids()))
    and d.updated_at > now() - make_interval(days => least(greatest(coalesce(p_days,120),1),400))
  order by d.updated_at desc limit 1000 $$;

create or replace function public.team_activity(p_from text, p_to text) returns table (id text, data jsonb)
language sql stable security definer set search_path = '' as $$
  select d.id, d.data from public.docs d
  where d.collection = 'hr_activity' and d.company_id = app.my_company() and app.my_role() = 'user'
    and d.data->>'employeeId' in (select app.team_ids())
    and coalesce(d.data->>'date','') between coalesce(p_from,'') and coalesce(p_to,'9999')
  order by d.data->>'date' desc, d.data->>'t1' desc limit 1000 $$;

revoke all on function public.team_act(text, text, text, text), public.att_clock(float8, float8, float8, jsonb, text), public.team_day(text),
  public.task_create(text[], jsonb), public.task_update(text, text, text, jsonb), public.task_rate(text, int, text), public.team_tasks(int), public.team_activity(text, text) from public, anon;
grant execute on function public.team_act(text, text, text, text), public.att_clock(float8, float8, float8, jsonb, text), public.team_day(text),
  public.task_create(text[], jsonb), public.task_update(text, text, text, jsonb), public.task_rate(text, int, text), public.team_tasks(int), public.team_activity(text, text) to authenticated;
revoke all on function app.task_mine(jsonb), app.geo_m(float8, float8, float8, float8) from public, anon;
grant execute on function app.task_mine(jsonb), app.geo_m(float8, float8, float8, float8) to authenticated;
