-- ============================================================
-- Security hardening: SECURITY DEFINER surface + payroll view
-- 2026-06-11
--
-- 1) v_payroll_unified ran as its owner (postgres), bypassing RLS
--    on paystubs/settlements. Switch to security_invoker so the
--    querying user's RLS (profile_id = auth.uid()) is enforced.
-- 2) Trigger-only functions removed from the PostgREST RPC surface
--    entirely (no role needs to call them via API).
--    auth.users triggers keep EXECUTE for supabase_auth_admin so
--    signup continues to work.
-- 3) App RPCs + RLS helper functions: EXECUTE revoked from PUBLIC
--    and anon; kept for authenticated + service_role.
-- 4) Pin search_path on functions flagged mutable.
-- ============================================================

-- ---- 1) Payroll view: enforce caller RLS --------------------
alter view public.v_payroll_unified set (security_invoker = true);
revoke all on public.v_payroll_unified from anon;

-- ---- 2) Trigger-only functions: no API callers --------------
revoke execute on function public.handle_new_user() from public, anon, authenticated;
grant  execute on function public.handle_new_user() to supabase_auth_admin;

revoke execute on function public.sph_sync_profile_account_role_from_auth() from public, anon, authenticated;
grant  execute on function public.sph_sync_profile_account_role_from_auth() to supabase_auth_admin;

revoke execute on function public.sph_notify_dispatch_push() from public, anon, authenticated;
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
revoke execute on function public._sph_d1_recreate_user_setnull(text, text, text) from public, anon, authenticated;

-- ---- 3) App RPCs + RLS helpers: authenticated only ----------
revoke execute on function public.accept_carrier_invite(text) from public, anon;
revoke execute on function public.preview_carrier_invite(text) from public, anon;
revoke execute on function public.driver_dashboard_data(timestamptz, timestamptz) from public, anon;
revoke execute on function public.sph_find_connectable_user(text) from public, anon;
revoke execute on function public.sph_current_account_role() from public, anon;
revoke execute on function public.sph_conn_is_accepted_member(uuid) from public, anon;
revoke execute on function public.sph_dispatch_caller_muted_out(uuid) from public, anon;
revoke execute on function public.sph_dispatch_can_access_agreement(uuid, uuid) from public, anon;
revoke execute on function public.sph_dispatch_can_access_thread(uuid, uuid) from public, anon;
revoke execute on function public.sph_dispatch_is_company_admin(uuid) from public, anon;
revoke execute on function public.sph_dispatch_is_platform_admin() from public, anon;
revoke execute on function public.sph_dispatch_mark_read(uuid) from public, anon;

-- Explicit grants so behavior for signed-in users is unchanged
grant execute on function public.accept_carrier_invite(text) to authenticated;
grant execute on function public.preview_carrier_invite(text) to authenticated;
grant execute on function public.driver_dashboard_data(timestamptz, timestamptz) to authenticated;
grant execute on function public.sph_find_connectable_user(text) to authenticated;
grant execute on function public.sph_current_account_role() to authenticated;
grant execute on function public.sph_conn_is_accepted_member(uuid) to authenticated;
grant execute on function public.sph_dispatch_caller_muted_out(uuid) to authenticated;
grant execute on function public.sph_dispatch_can_access_agreement(uuid, uuid) to authenticated;
grant execute on function public.sph_dispatch_can_access_thread(uuid, uuid) to authenticated;
grant execute on function public.sph_dispatch_is_company_admin(uuid) to authenticated;
grant execute on function public.sph_dispatch_is_platform_admin() to authenticated;
grant execute on function public.sph_dispatch_mark_read(uuid) to authenticated;

-- ---- 4) Pin mutable search_path ------------------------------
alter function public.set_documents_updated_at() set search_path = public, pg_temp;
alter function public.set_updated_at() set search_path = public, pg_temp;
alter function public.sph_conn_touch_updated_at() set search_path = public, pg_temp;
alter function public._sph_d1_recreate_user_setnull(text, text, text) set search_path = public, pg_temp;
