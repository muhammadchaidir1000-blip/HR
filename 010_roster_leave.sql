-- 010: cuti lewat jadwal shift
-- Kode jadwal "C" = cuti. Saat pimpinan menyimpan jadwal tim, sel C yang baru otomatis menjadi
-- pengajuan cuti tahunan (tahap atasan sudah disetujui, menunggu HRD); C yang diganti shift lain
-- membatalkan pengajuan "dari jadwal" yang terkait. Pimpinan juga bisa melihat cuti tim di jadwal.

create or replace function app.leave_dates(d jsonb) returns text[]
language sql immutable set search_path = '' as $$
  select case
    when jsonb_typeof(d->'slots') = 'array' and jsonb_array_length(d->'slots') > 0
      then array(select s->>'d' from jsonb_array_elements(d->'slots') s order by 1)
    when jsonb_typeof(d->'dates') = 'array' and jsonb_array_length(d->'dates') > 0
      then array(select x from jsonb_array_elements_text(d->'dates') x order by 1)
    when coalesce(d->>'start','') ~ '^\d{4}-\d\d-\d\d$' and coalesce(d->>'end','') ~ '^\d{4}-\d\d-\d\d$' and d->>'end' >= d->>'start'
      then array(select to_char(g, 'YYYY-MM-DD') from generate_series((d->>'start')::date, least((d->>'end')::date, (d->>'start')::date + 400), interval '1 day') g)
    else '{}'::text[] end $$;

-- simpan satu pengajuan per rentang tanggal berurutan
create or replace function app.roster_leave_insert(p_co text, p_emp text, p_dates text[], p_steps jsonb, p_type text, p_by text)
returns int language plpgsql security definer set search_path = '' as $$
declare d text; run text[] := '{}'; n int := 0; st text;
begin
  st := case when (select bool_and(s->>'status' = 'Disetujui') from jsonb_array_elements(p_steps) s) then 'Disetujui' else 'Menunggu' end;
  for d in select x from unnest(p_dates) x group by x order by x loop
    if cardinality(run) > 0 and (run[cardinality(run)]::date + 1) <> d::date then
      insert into public.docs (collection, id, company_id, data) values ('leaves', 'l' || substr(md5(random()::text || clock_timestamp()::text), 1, 12), p_co,
        jsonb_build_object('companyId', p_co, 'employeeId', p_emp, 'type', p_type, 'start', run[1], 'end', run[cardinality(run)], 'dates', to_jsonb(run),
          'slots', (select jsonb_agg(jsonb_build_object('d', x, 't1', '', 't2', '', 'f', 1, 'full', true) order by x) from unnest(run) x),
          'reason', 'Cuti dari jadwal shift', 'src', 'jadwal', 'steps', p_steps, 'status', st,
          'createdAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), 'createdBy', p_by, 'byLead', true));
      n := n + 1; run := '{}';
    end if;
    run := run || d;
  end loop;
  if cardinality(run) > 0 then
    insert into public.docs (collection, id, company_id, data) values ('leaves', 'l' || substr(md5(random()::text || clock_timestamp()::text), 1, 12), p_co,
      jsonb_build_object('companyId', p_co, 'employeeId', p_emp, 'type', p_type, 'start', run[1], 'end', run[cardinality(run)], 'dates', to_jsonb(run),
        'slots', (select jsonb_agg(jsonb_build_object('d', x, 't1', '', 't2', '', 'f', 1, 'full', true) order by x) from unnest(run) x),
        'reason', 'Cuti dari jadwal shift', 'src', 'jadwal', 'steps', p_steps, 'status', st,
        'createdAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), 'createdBy', p_by, 'byLead', true));
    n := n + 1;
  end if;
  return n;
end $$;

-- sinkron cuti dari jadwal untuk satu karyawan & bulan; p_changed = sel yang diubah { "dd": "kode" }
create or replace function app.roster_leave_sync(p_emp text, p_month text, p_changed jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare co text := app.my_company(); sched jsonb; cfg jsonb; ltype text; appr jsonb; n int; lvl int;
  who text := (select a.data->>'username' from public.docs a where a.collection = 'accounts' and a.id = app.my_account());
  nowt text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  r record; ds text[]; rest text[]; covered text[] := '{}'; keep jsonb := '[]'; k jsonb; fresh text[]; steps jsonb;
begin
  select coalesce(x.data->'sched', '{}'::jsonb) into sched from public.docs x where x.collection = 'att_month' and x.id = p_emp || '__' || p_month and x.company_id = co;
  sched := coalesce(sched, '{}'::jsonb);
  -- batalkan pengajuan "dari jadwal" yang tanggalnya tidak lagi C
  for r in select x.id, x.data from public.docs x
    where x.collection = 'leaves' and x.company_id = co and x.data->>'employeeId' = p_emp and coalesce(x.data->>'status', '') not in ('Ditolak', 'Dibatalkan')
  loop
    ds := array(select v from unnest(app.leave_dates(r.data)) v where v like p_month || '-%');
    if r.data->>'src' = 'jadwal' and cardinality(ds) > 0 and exists (select 1 from unnest(ds) v where coalesce(sched->>substr(v, 9, 2), '') <> 'C') then
      update public.docs set data = data || jsonb_build_object('status', 'Dibatalkan', 'cancelNote', 'Dihapus dari jadwal shift', 'cancelledAt', nowt, 'cancelledBy', who)
        where collection = 'leaves' and id = r.id;
      rest := array(select v from unnest(ds) v where sched->>substr(v, 9, 2) = 'C' order by v);
      if cardinality(rest) > 0 then keep := keep || jsonb_build_array(jsonb_build_object('dates', to_jsonb(rest), 'steps', r.data->'steps')); end if;
    else
      covered := covered || app.leave_dates(r.data);
    end if;
  end loop;
  select x.data into cfg from public.docs x where x.collection = 'hr_config' and x.id = co;
  if jsonb_typeof(cfg->'leaveTypes') = 'array' then
    ltype := (select t->>'name' from jsonb_array_elements(cfg->'leaveTypes') t where coalesce((t->>'annual')::boolean, false) limit 1);
  else ltype := 'Tahunan'; end if;
  if ltype is null then return; end if;
  -- tanggal yang masih C dari pengajuan yang dibatalkan: buat ulang dengan status persetujuan yang sama
  for k in select value from jsonb_array_elements(keep) loop
    rest := array(select v from jsonb_array_elements_text(k->'dates') v where not (v = any(covered)));
    if cardinality(rest) > 0 then perform app.roster_leave_insert(co, p_emp, rest, k->'steps', ltype, who); covered := covered || rest; end if;
  end loop;
  -- sel yang baru diberi C
  fresh := array(select p_month || '-' || key from jsonb_each_text(p_changed) where value = 'C' and not ((p_month || '-' || key) = any(covered)));
  if cardinality(fresh) = 0 then return; end if;
  appr := case when jsonb_typeof(cfg->'approvals') = 'array' and jsonb_array_length(cfg->'approvals') > 0 then cfg->'approvals' else '["Atasan langsung","HRD"]'::jsonb end;
  n := jsonb_array_length(appr); lvl := coalesce(app.lead_level(p_emp), 0);
  steps := (select jsonb_agg(case when t.i - 1 < least(lvl, n - 1)
      then jsonb_build_object('name', t.v, 'status', 'Disetujui', 'by', who, 'at', nowt, 'note', 'Dari jadwal shift', 'byLead', true)
      else jsonb_build_object('name', t.v, 'status', 'Menunggu') end order by t.i) from jsonb_array_elements_text(appr) with ordinality t(v, i));
  perform app.roster_leave_insert(co, p_emp, fresh, steps, ltype, who);
end $$;

create or replace function public.team_set_sched(p_emp text, p_month text, p_sched jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare co text := app.my_company(); did text := p_emp || '__' || p_month; cur jsonb; k text; v text; me text := app.my_employee();
begin
  if app.my_role() <> 'user' or me is null then raise exception 'forbidden'; end if;
  if not (p_emp in (select app.team_ids()) or (p_emp = me and exists (select 1 from app.team_ids()))) then raise exception 'forbidden'; end if;
  if p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' or jsonb_typeof(p_sched) <> 'object' then raise exception 'bad_input'; end if;
  for k, v in select key, value from jsonb_each_text(p_sched) loop
    if k !~ '^(0[1-9]|[12]\d|3[01])$' or not (v = '' or v ~ '^[A-Z0-9]{1,4}$' or v ~ '^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$') then raise exception 'bad_input'; end if;
  end loop;
  select d.data into cur from public.docs d where d.collection = 'att_month' and d.id = did for update;
  if cur is null then
    insert into public.docs (collection, id, company_id, data) values ('att_month', did, co,
      jsonb_build_object('companyId', co, 'employeeId', p_emp, 'month', p_month, 'scans', '{}'::jsonb, 'fix', '{}'::jsonb, 'updatedAt', now(),
        'sched', (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(p_sched) where value <> '""'::jsonb)));
  else
    cur := jsonb_set(cur, '{sched}', (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(coalesce(cur->'sched','{}'::jsonb) || p_sched) where value <> '""'::jsonb));
    update public.docs set data = cur || jsonb_build_object('updatedAt', now(), 'schedBy', (select a.data->>'username' from public.docs a where a.collection='accounts' and a.id = app.my_account()))
      where collection = 'att_month' and id = did;
  end if;
  perform app.roster_leave_sync(p_emp, p_month, p_sched);
end $$;

-- cuti tim yang masih berlaku dan menyentuh bulan ini (untuk ditampilkan di Jadwal Tim)
create or replace function public.team_leaves(p_month text) returns table (id text, data jsonb)
language sql stable security definer set search_path = '' as $$
  select d.id, d.data - 'files' from public.docs d
  where p_month ~ '^\d{4}-(0[1-9]|1[0-2])$' and d.collection = 'leaves' and d.company_id = app.my_company()
    and coalesce(d.data->>'status', '') not in ('Ditolak', 'Dibatalkan')
    and (d.data->>'employeeId' in (select app.team_ids()) or (d.data->>'employeeId' = app.my_employee() and exists (select 1 from app.team_ids())))
    and coalesce(d.data->>'start', '') <= p_month || '-31' and coalesce(d.data->>'end', d.data->>'start', '') >= p_month || '-01'
  limit 1000 $$;

revoke all on function app.leave_dates(jsonb) from public, anon;
revoke all on function app.roster_leave_insert(text, text, text[], jsonb, text, text) from public, anon, authenticated;
revoke all on function app.roster_leave_sync(text, text, jsonb) from public, anon, authenticated;
revoke all on function public.team_leaves(text) from public, anon;
grant execute on function app.leave_dates(jsonb) to authenticated;
grant execute on function public.team_leaves(text) to authenticated;
