-- ============================================================================
-- Sacred Pathway Driver Hub — Sponsored-driver dashboard scope fix
-- 20260527000000_driver_dashboard_data.sql
-- ----------------------------------------------------------------------------
-- Adds a READ-ONLY SECURITY DEFINER function that returns the loads,
-- paystubs, and expenses attributable to the calling driver via their active
-- carrier_members row. Used by /dashboard when accessLevel = "carrier_driver"
-- so the driver sees ONLY their own attributed records — never the carrier's
-- whole book, never another driver's data.
--
-- Why an RPC instead of new RLS policies:
--   • RLS would need to allow drivers to SELECT carrier rows where
--     driver_id matches their linked_driver_id. That policy would be
--     evaluated on every query against the table — including queries the
--     Carrier HQ pages run from the carrier's side. Easy to get wrong.
--   • A single RPC returning a JSON blob gives one well-tested gate that
--     resolves the membership, scopes the data, and never leaks across
--     drivers / carriers.
--
-- READ-ONLY GUARANTEE:
--   • Function contains only SELECT statements.
--   • No INSERT / UPDATE / DELETE / TRUNCATE / ALTER anywhere.
--   • Does not modify, backfill, or migrate any existing data.
--   • Schema additions are pure CREATE; no changes to existing tables.
--   • Idempotent: CREATE OR REPLACE FUNCTION + DROP-IF-EXISTS-then-CREATE on
--     grants.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.driver_dashboard_data(
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to   TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE                                       -- read-only marker
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_member   public.carrier_members%ROWTYPE;
  v_loads    JSONB;
  v_paystubs JSONB;
  v_expenses JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_signed_in');
  END IF;

  -- Active driver-role membership. If a user is sponsored by multiple
  -- carriers (rare), we take the most-recently joined one. The UI can grow
  -- a carrier-picker later; today there's no UX for it.
  SELECT *
    INTO v_member
  FROM public.carrier_members
  WHERE user_id = v_user_id
    AND status  = 'active'
    AND role    = 'driver'
  ORDER BY joined_at DESC NULLS LAST
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_active_membership');
  END IF;

  -- linked_driver_id is what ties the auth user to the carrier-side
  -- drivers roster row (paystub history, load assignment). If the carrier
  -- hasn't linked them yet, return empty arrays + a needs_link flag so the
  -- UI can prompt the driver to ask their carrier to complete linkage.
  IF v_member.linked_driver_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',                 true,
      'carrier_profile_id', v_member.carrier_profile_id,
      'linked_driver_id',   NULL,
      'needs_link',         true,
      'loads',              '[]'::jsonb,
      'paystubs',           '[]'::jsonb,
      'expenses',           '[]'::jsonb
    );
  END IF;

  -- ---- loads scoped to (carrier, this driver) + optional date window ----
  SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.created_at DESC), '[]'::jsonb)
    INTO v_loads
  FROM public.loads l
  WHERE l.profile_id = v_member.carrier_profile_id
    AND l.driver_id  = v_member.linked_driver_id
    AND (p_from IS NULL OR l.created_at >= p_from)
    AND (p_to   IS NULL OR l.created_at <= p_to);

  -- ---- paystubs scoped same way ----
  SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.check_date DESC NULLS LAST), '[]'::jsonb)
    INTO v_paystubs
  FROM public.paystubs p
  WHERE p.profile_id = v_member.carrier_profile_id
    AND p.driver_id  = v_member.linked_driver_id
    AND (p_from IS NULL OR p.created_at >= p_from)
    AND (p_to   IS NULL OR p.created_at <= p_to);

  -- ---- expenses tied to this driver's loads ----
  -- We only return expenses whose load_id is one of the driver-attributed
  -- loads. This intentionally OMITS unattached / carrier-overhead expenses
  -- (factoring fees, authority fees) — those are carrier-level, not the
  -- driver's to see.
  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC), '[]'::jsonb)
    INTO v_expenses
  FROM public.expenses e
  WHERE e.profile_id = v_member.carrier_profile_id
    AND e.load_id IN (
      SELECT id
      FROM public.loads
      WHERE profile_id = v_member.carrier_profile_id
        AND driver_id  = v_member.linked_driver_id
    )
    AND (p_from IS NULL OR e.created_at >= p_from)
    AND (p_to   IS NULL OR e.created_at <= p_to);

  RETURN jsonb_build_object(
    'ok',                 true,
    'carrier_profile_id', v_member.carrier_profile_id,
    'linked_driver_id',   v_member.linked_driver_id,
    'needs_link',         false,
    'loads',              v_loads,
    'paystubs',           v_paystubs,
    'expenses',           v_expenses
  );
END;
$$;
-- Only authenticated users may call. anon role gets nothing.
REVOKE ALL ON FUNCTION public.driver_dashboard_data(TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.driver_dashboard_data(TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
