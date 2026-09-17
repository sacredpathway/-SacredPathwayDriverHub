-- ============================================================================
-- Sacred Pathway Driver Hub — Driver invite → roster row linkage
-- 20260528000000_carrier_invites_linked_driver.sql
-- ----------------------------------------------------------------------------
-- Lets a carrier pre-stage a drivers roster row (name / pay / etc.) BEFORE
-- the driver accepts the invite, then auto-link the driver's auth user to
-- that roster row the moment they accept. Without this, the carrier had to
-- manually re-enter the driver info AFTER acceptance.
--
-- ADDITIVE ONLY. No DROP, no RENAME, no NOT NULL tightening on any existing
-- column. Idempotent.
--
-- READ-PATH ONLY for existing data:
--   • Adds one nullable column to carrier_invites.
--   • Replaces the SECURITY DEFINER accept_carrier_invite() body so the new
--     carrier_members row also copies linked_driver_id from the invite.
--     For any invite created BEFORE this migration (linked_driver_id NULL),
--     behavior is identical to the prior version.
--   • Touches NO existing rows in any data table.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Carrier_invites — optional pointer to a pre-staged drivers row
-- ----------------------------------------------------------------------------
ALTER TABLE public.carrier_invites
  ADD COLUMN IF NOT EXISTS linked_driver_id UUID
    REFERENCES public.drivers(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_carrier_invites_linked_driver
  ON public.carrier_invites (linked_driver_id)
  WHERE linked_driver_id IS NOT NULL;
-- ----------------------------------------------------------------------------
-- 2. accept_carrier_invite — copy linked_driver_id into the membership row
-- ----------------------------------------------------------------------------
-- Same shape as before; the only delta is one extra column in the INSERT.
-- All validation gates (revoked / expired / max_uses / email match / already-
-- member idempotency) preserved verbatim so existing flows behave identically.
CREATE OR REPLACE FUNCTION public.accept_carrier_invite(p_invite_code TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id      UUID := auth.uid();
  v_invite       public.carrier_invites%ROWTYPE;
  v_existing_id  UUID;
  v_new_member   UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_signed_in');
  END IF;

  SELECT * INTO v_invite
  FROM public.carrier_invites
  WHERE invite_code = p_invite_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invite_not_found');
  END IF;

  IF v_invite.revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invite_revoked');
  END IF;

  IF v_invite.expires_at IS NOT NULL AND v_invite.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invite_expired');
  END IF;

  IF v_invite.use_count >= v_invite.max_uses THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invite_max_uses_reached');
  END IF;

  IF v_invite.email IS NOT NULL THEN
    -- Email match is case-insensitive — Supabase Auth stores emails lower
    -- but UIs sometimes display as typed.
    IF lower((SELECT email FROM auth.users WHERE id = v_user_id))
       IS DISTINCT FROM lower(v_invite.email) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invite_email_mismatch');
    END IF;
  END IF;

  -- Already a member? Idempotent success.
  SELECT id INTO v_existing_id
  FROM public.carrier_members
  WHERE carrier_profile_id = v_invite.carrier_profile_id
    AND user_id = v_user_id
    AND status = 'active';

  IF v_existing_id IS NOT NULL THEN
    -- If the existing membership has no linked_driver_id but the invite
    -- does, back-fill the link so historical re-accepts heal automatically.
    UPDATE public.carrier_members
       SET linked_driver_id = COALESCE(linked_driver_id, v_invite.linked_driver_id)
     WHERE id = v_existing_id;

    RETURN jsonb_build_object(
      'ok',                 true,
      'carrier_profile_id', v_invite.carrier_profile_id,
      'carrier_member_id',  v_existing_id,
      'already_member',     true
    );
  END IF;

  -- Insert the membership + bump use_count atomically. linked_driver_id
  -- copied from the invite so the driver-side dashboard immediately
  -- resolves to the right roster row.
  INSERT INTO public.carrier_members (
    carrier_profile_id, user_id, role, status, invite_id, linked_driver_id
  )
  VALUES (
    v_invite.carrier_profile_id,
    v_user_id,
    v_invite.role,
    'active',
    v_invite.id,
    v_invite.linked_driver_id
  )
  RETURNING id INTO v_new_member;

  UPDATE public.carrier_invites
  SET use_count = use_count + 1
  WHERE id = v_invite.id;

  RETURN jsonb_build_object(
    'ok',                 true,
    'carrier_profile_id', v_invite.carrier_profile_id,
    'carrier_member_id',  v_new_member,
    'already_member',     false
  );
END;
$$;
-- Grants preserved.
REVOKE ALL ON FUNCTION public.accept_carrier_invite(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_carrier_invite(TEXT) TO authenticated;
