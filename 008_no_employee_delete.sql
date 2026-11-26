-- 008: Admin Perusahaan tidak boleh menghapus karyawan (hanya menonaktifkan). Super Admin tetap bisa (pembersihan data contoh).
drop policy if exists docs_delete on public.docs;
create policy docs_delete on public.docs for delete to authenticated using (
  (select app.my_role()) = 'superadmin'
  or ((select app.my_role()) = 'company' and collection not in ('initpass','companies','employees') and company_id = (select app.my_company()))
  or ((select app.my_role()) = 'user' and company_id = (select app.my_company())
      and owner_id = (select app.my_account())
      and (collection in ('disc_sessions','ist_sessions','papi_sessions','skill_sessions','hr_activity')
           or (collection in ('leaves','hr_claims','overtime','hr_requests') and app.staff_pending(collection, data))))
);
