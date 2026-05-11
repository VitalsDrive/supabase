-- VitalsDrive Device Provisioning - Pre-provisioning workflow
-- Version: 1.2.0
-- Description: 
--   - Add status to devices (unassigned/active/inactive)
--   - One device per vehicle constraint
--   - device_assignments history table
--   - Proper RLS for devices and device_assignments
--   - assign_device_to_vehicle / unassign_device RPCs
--
-- NOTE: devices table and provisioning_code on fleets were already
--       applied via Supabase MCP (migration applied 2026-03-30).
--       This file adds the remaining device provisioning schema.

BEGIN;

-- ============================================================
-- 1. Add status to devices
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'devices' AND column_name = 'status'
  ) THEN
    ALTER TABLE devices
      ADD COLUMN status TEXT NOT NULL DEFAULT 'unassigned'
        CHECK (status IN ('unassigned', 'active', 'inactive'));
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_devices_status ON devices(status);

-- ============================================================
-- 2. One device per vehicle constraint
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_devices_vehicle_id'
  ) THEN
    ALTER TABLE devices
      ADD CONSTRAINT uq_devices_vehicle_id UNIQUE (vehicle_id);
  END IF;
END;
$$;

-- ============================================================
-- 3. device_assignments — history table
-- ============================================================
CREATE TABLE IF NOT EXISTS device_assignments (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id     UUID        NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  vehicle_id    UUID        NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
  assigned_by   UUID        REFERENCES users(id) ON DELETE SET NULL,
  assigned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  unassigned_at TIMESTAMPTZ,
  notes         TEXT
);

CREATE INDEX IF NOT EXISTS idx_device_assignments_device_id   ON device_assignments(device_id);
CREATE INDEX IF NOT EXISTS idx_device_assignments_vehicle_id  ON device_assignments(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_device_assignments_assigned_at ON device_assignments(assigned_at DESC);

ALTER TABLE device_assignments ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 4. RLS — devices
-- Drop old broad policies from initial MCP migration, replace
-- with fleet-scoped, role-aware policies
-- ============================================================
DROP POLICY IF EXISTS "Users can read devices in their fleets"   ON devices;
DROP POLICY IF EXISTS "Service role full access"                 ON devices;
DROP POLICY IF EXISTS "Fleet members can read own fleet devices" ON devices;
DROP POLICY IF EXISTS "Fleet admins can insert devices"          ON devices;
DROP POLICY IF EXISTS "Fleet admins can update devices"          ON devices;
DROP POLICY IF EXISTS "Fleet admins can delete devices"          ON devices;

-- Any fleet member can read devices in their fleet
CREATE POLICY "Fleet members can read own fleet devices" ON devices
  FOR SELECT USING (
    fleet_id IN (
      SELECT fleet_id FROM fleet_members WHERE user_id = auth.uid()
    )
  );

-- Only fleet owner/admin can pre-provision (insert) a device
CREATE POLICY "Fleet admins can insert devices" ON devices
  FOR INSERT WITH CHECK (
    fleet_id IN (
      SELECT fleet_id FROM fleet_members
      WHERE user_id = auth.uid()
        AND role IN ('owner', 'admin')
    )
  );

-- Only fleet owner/admin can update devices (assign, deactivate, etc.)
CREATE POLICY "Fleet admins can update devices" ON devices
  FOR UPDATE USING (
    fleet_id IN (
      SELECT fleet_id FROM fleet_members
      WHERE user_id = auth.uid()
        AND role IN ('owner', 'admin')
    )
  );

-- Only fleet owner/admin can delete devices
CREATE POLICY "Fleet admins can delete devices" ON devices
  FOR DELETE USING (
    fleet_id IN (
      SELECT fleet_id FROM fleet_members
      WHERE user_id = auth.uid()
        AND role IN ('owner', 'admin')
    )
  );

-- ============================================================
-- 5. RLS — device_assignments
-- ============================================================

-- Any fleet member can read assignment history for their fleet's devices
CREATE POLICY "Fleet members can read device assignment history" ON device_assignments
  FOR SELECT USING (
    device_id IN (
      SELECT d.id FROM devices d
      JOIN fleet_members fm ON fm.fleet_id = d.fleet_id
      WHERE fm.user_id = auth.uid()
    )
  );

-- Fleet owner/admin can write assignment records
CREATE POLICY "Fleet admins can insert device assignments" ON device_assignments
  FOR INSERT WITH CHECK (
    device_id IN (
      SELECT d.id FROM devices d
      JOIN fleet_members fm ON fm.fleet_id = d.fleet_id
      WHERE fm.user_id = auth.uid()
        AND fm.role IN ('owner', 'admin')
    )
  );

-- Fleet owner/admin can close assignment records (set unassigned_at)
CREATE POLICY "Fleet admins can update device assignments" ON device_assignments
  FOR UPDATE USING (
    device_id IN (
      SELECT d.id FROM devices d
      JOIN fleet_members fm ON fm.fleet_id = d.fleet_id
      WHERE fm.user_id = auth.uid()
        AND fm.role IN ('owner', 'admin')
    )
  );

-- ============================================================
-- 6. assign_device_to_vehicle RPC
--    Returns JSONB with success/error and fleet mismatch details
--    so the dashboard can surface the right validation message.
-- ============================================================
CREATE OR REPLACE FUNCTION assign_device_to_vehicle(
  p_device_id   UUID,
  p_vehicle_id  UUID,
  p_assigned_by UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_device  RECORD;
  v_vehicle RECORD;
  v_caller_fleet_ids UUID[];
BEGIN
  -- Lock and fetch device
  SELECT * INTO v_device FROM devices WHERE id = p_device_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'device_not_found');
  END IF;

  -- Fetch vehicle
  SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'vehicle_not_found');
  END IF;

  -- Fleet mismatch check
  IF v_device.fleet_id != v_vehicle.fleet_id THEN
    -- Check if the vehicle's fleet belongs to the same client (caller's fleets)
    SELECT array_agg(fleet_id) INTO v_caller_fleet_ids
      FROM fleet_members WHERE user_id = p_assigned_by;

    IF v_vehicle.fleet_id = ANY(v_caller_fleet_ids) THEN
      -- Caller owns both fleets but they don't match — prompt to correct registration
      RETURN jsonb_build_object(
        'success',           false,
        'error',             'fleet_mismatch_same_client',
        'device_fleet_id',   v_device.fleet_id,
        'vehicle_fleet_id',  v_vehicle.fleet_id
      );
    ELSE
      -- Vehicle belongs to a completely different client — contact support
      RETURN jsonb_build_object(
        'success', false,
        'error',   'fleet_mismatch_different_client'
      );
    END IF;
  END IF;

  -- Verify caller has admin/owner role in this fleet
  IF NOT EXISTS (
    SELECT 1 FROM fleet_members
    WHERE user_id = p_assigned_by
      AND fleet_id = v_device.fleet_id
      AND role IN ('owner', 'admin')
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'insufficient_permissions');
  END IF;

  -- Close any open assignment for this device
  UPDATE device_assignments
    SET unassigned_at = now()
  WHERE device_id = p_device_id
    AND unassigned_at IS NULL;

  -- Update device record
  UPDATE devices
    SET vehicle_id = p_vehicle_id,
        status     = 'active',
        updated_at = now()
  WHERE id = p_device_id;

  -- Record new assignment
  INSERT INTO device_assignments (device_id, vehicle_id, assigned_by)
  VALUES (p_device_id, p_vehicle_id, p_assigned_by);

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ============================================================
-- 7. unassign_device RPC
-- ============================================================
CREATE OR REPLACE FUNCTION unassign_device(
  p_device_id   UUID,
  p_assigned_by UUID,
  p_notes       TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_device RECORD;
BEGIN
  SELECT * INTO v_device FROM devices WHERE id = p_device_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'device_not_found');
  END IF;

  -- Verify caller has admin/owner role in this fleet
  IF NOT EXISTS (
    SELECT 1 FROM fleet_members
    WHERE user_id = p_assigned_by
      AND fleet_id = v_device.fleet_id
      AND role IN ('owner', 'admin')
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'insufficient_permissions');
  END IF;

  -- Close open assignment, record notes
  UPDATE device_assignments
    SET unassigned_at = now(),
        notes         = COALESCE(p_notes, notes)
  WHERE device_id = p_device_id
    AND unassigned_at IS NULL;

  -- Clear vehicle link, revert to unassigned
  UPDATE devices
    SET vehicle_id = NULL,
        status     = 'unassigned',
        updated_at = now()
  WHERE id = p_device_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

COMMIT;
