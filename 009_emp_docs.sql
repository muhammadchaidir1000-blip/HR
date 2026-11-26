-- 009: dokumen karyawan (emp_docs) — staf mengunggah sendiri KTP, KK, SIP, sertifikat, asuransi, dll.
-- Staf hanya bisa menulis dokumen miliknya yang BELUM diverifikasi HRD; tanda verifikasi hanya bisa diisi admin.
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
  elsif new.collection in ('att_month','leaves','hr_claims','pay_slips','overtime','hr_requests','hr_tasks','hr_activity','emp_docs') then
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
      where collection in ('att_month','leaves','hr_claims','pay_slips','overtime','hr_requests','hr_tasks','hr_activity','emp_docs') and data->>'employeeId' = new.id
        and owner_id is distinct from new.owner_id;
  end if;
  return new;
end $$;

-- dokumen staf yang boleh ditulis staf: miliknya, belum diverifikasi
create or replace function app.empdoc_own(d jsonb) returns boolean language sql stable security definer set search_path = '' as $$
  select (select app.my_employee()) is not null and d->>'employeeId' = (select app.my_employee()) and (d->'verified') is null $$;
grant execute on function app.empdoc_own(jsonb) to authenticated;

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
           or (collection = 'hr_activity' and (select app.my_employee()) is not null and data->>'employeeId' = (select app.my_employee()))
           or (collection = 'emp_docs' and app.empdoc_own(data))))
);

drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update to authenticated using (
  (select app.my_role()) = 'superadmin'
  or ((select app.my_role()) = 'company' and collection <> 'initpass' and company_id = (select app.my_company()))
  or ((select app.my_role()) = 'user' and company_id = (select app.my_company())
      and owner_id = (select app.my_account())
      and (collection in ('accounts','disc_sessions','ist_sessions','papi_sessions','skill_sessions','disc_results','ist_results','papi_results','skill_results','audit','hr_activity')
           or (collection = 'emp_docs' and data->>'employeeId' = (select app.my_employee()))
           or (collection in ('leaves','hr_claims','overtime','hr_requests') and app.staff_open(collection, data))))
) with check (
  (select app.my_role()) = 'superadmin'
  or ((select app.my_role()) = 'company' and collection <> 'initpass' and company_id = (select app.my_company()))
  or ((select app.my_role()) = 'user' and company_id = (select app.my_company())
      and owner_id = (select app.my_account())
      and (collection in ('accounts','disc_sessions','ist_sessions','papi_sessions','skill_sessions','disc_results','ist_results','papi_results','skill_results','audit')
           or (collection = 'hr_activity' and data->>'employeeId' = (select app.my_employee()))
           or (collection = 'emp_docs' and app.empdoc_own(data))
           or (collection in ('leaves','hr_claims','overtime','hr_requests') and data->>'employeeId' = (select app.my_employee()) and app.staff_newok(collection, data))))
);

drop policy if exists docs_delete on public.docs;
create policy docs_delete on public.docs for delete to authenticated using (
  (select app.my_role()) = 'superadmin'
  or ((select app.my_role()) = 'company' and collection not in ('initpass','companies','employees') and company_id = (select app.my_company()))
  or ((select app.my_role()) = 'user' and company_id = (select app.my_company())
      and owner_id = (select app.my_account())
      and (collection in ('disc_sessions','ist_sessions','papi_sessions','skill_sessions','hr_activity')
           or (collection = 'emp_docs' and app.empdoc_own(data))
           or (collection in ('leaves','hr_claims','overtime','hr_requests') and app.staff_pending(collection, data))))
);
