-- VitalsDrive RLS Policies
-- Version: 1.0.0
-- Description: Row Level Security policies for multi-tenant data isolation

BEGIN;

-- ============================================
-- ENABLE RLS ON ALL TABLES
-- ============================================
ALTER TABLE telemetry_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE fleets ENABLE ROW LEVEL SECURITY;
ALTER TABLE fleet_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE telemetry_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE scheduled_maintenance ENABLE ROW LEVEL SECURITY;

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Returns all fleet IDs the current user has access to
CREATE OR REPLACE FUNCTION get_user_fleet_ids()
RETURNS SETOF UUID AS $$
    SELECT fleet_id FROM fleet_members WHERE user_id = auth.uid();
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

COMMENT ON FUNCTION get_user_fleet_ids IS 'Returns all fleet IDs the current user has access to';

-- Returns TRUE if current user is owner or admin of the fleet
CREATE OR REPLACE FUNCTION is_fleet_admin(p_fleet_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM fleet_members
        WHERE fleet_id = p_fleet_id
        AND user_id = auth.uid()
        AND role IN ('owner', 'admin')
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION is_fleet_admin IS 'Checks if current user is owner or admin of a fleet';

-- ============================================
-- RLS POLICIES: users
-- ============================================

-- Users can read their own profile
CREATE POLICY "Users can read own profile"
    ON users FOR SELECT
    USING (id = auth.uid());

-- Users can update their own profile (except role)
CREATE POLICY "Users can update own profile"
    ON users FOR UPDATE
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());

-- ============================================
-- RLS POLICIES: fleets
-- ============================================

-- Users can read fleets they are members of
CREATE POLICY "Users can read own fleets"
    ON fleets FOR SELECT
    USING (id IN (SELECT get_user_fleet_ids()));

-- Fleet owners can insert new fleets
CREATE POLICY "Users can create fleets"
    ON fleets FOR INSERT
    WITH CHECK (owner_id = auth.uid());

-- Fleet owners and admins can update
CREATE POLICY "Owners and admins can update fleets"
    ON fleets FOR UPDATE
    USING (
        id IN (
            SELECT fleet_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- Only owners can delete fleets
CREATE POLICY "Owners can delete fleets"
    ON fleets FOR DELETE
    USING (owner_id = auth.uid());

-- ============================================
-- RLS POLICIES: fleet_members
-- ============================================

-- Users can read fleet members of their fleets
CREATE POLICY "Users can read fleet members"
    ON fleet_members FOR SELECT
    USING (fleet_id IN (SELECT get_user_fleet_ids()));

-- Fleet admins can add members
CREATE POLICY "Admins can add fleet members"
    ON fleet_members FOR INSERT
    WITH CHECK (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- Fleet admins can remove members
CREATE POLICY "Admins can remove fleet members"
    ON fleet_members FOR DELETE
    USING (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- ============================================
-- RLS POLICIES: vehicles
-- ============================================

-- Users can read vehicles in their fleets
CREATE POLICY "Users can read own fleet vehicles"
    ON vehicles FOR SELECT
    USING (fleet_id IN (SELECT get_user_fleet_ids()));

-- Fleet admins can create vehicles
CREATE POLICY "Admins can create vehicles"
    ON vehicles FOR INSERT
    WITH CHECK (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- Fleet admins can update vehicles
CREATE POLICY "Admins can update vehicles"
    ON vehicles FOR UPDATE
    USING (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- Fleet admins can delete vehicles
CREATE POLICY "Admins can delete vehicles"
    ON vehicles FOR DELETE
    USING (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- ============================================
-- RLS POLICIES: telemetry_logs
-- ============================================

-- Users can only read telemetry for vehicles in their fleets
CREATE POLICY "Users can read own fleet telemetry"
    ON telemetry_logs FOR SELECT
    USING (
        vehicle_id IN (
            SELECT v.id FROM vehicles v
            WHERE v.fleet_id IN (SELECT get_user_fleet_ids())
        )
    );

-- Service accounts (via service role key) can insert telemetry
-- Note: Service role bypasses RLS, so this is mainly for documentation
CREATE POLICY "Service accounts can insert telemetry"
    ON telemetry_logs FOR INSERT
    WITH CHECK (true);

-- ============================================
-- RLS POLICIES: alerts
-- ============================================

-- Users can read alerts for their fleets
CREATE POLICY "Users can read own fleet alerts"
    ON alerts FOR SELECT
    USING (fleet_id IN (SELECT get_user_fleet_ids()));

-- Fleet admins and owners can acknowledge alerts
CREATE POLICY "Admins can acknowledge alerts"
    ON alerts FOR UPDATE
    USING (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- System can create alerts (bypassed by service role)
CREATE POLICY "System can create alerts"
    ON alerts FOR INSERT
    WITH CHECK (true);

-- ============================================
-- RLS POLICIES: telemetry_rules
-- ============================================

-- Users can read rules for their fleets
CREATE POLICY "Users can read fleet rules"
    ON telemetry_rules FOR SELECT
    USING (fleet_id IN (SELECT get_user_fleet_ids()));

-- Fleet admins can manage rules
CREATE POLICY "Admins can manage fleet rules"
    ON telemetry_rules FOR ALL
    USING (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- ============================================
-- RLS POLICIES: scheduled_maintenance
-- ============================================

-- Users can read maintenance for vehicles in their fleets
CREATE POLICY "Users can read fleet maintenance"
    ON scheduled_maintenance FOR SELECT
    USING (
        vehicle_id IN (
            SELECT v.id FROM vehicles v
            WHERE v.fleet_id IN (SELECT get_user_fleet_ids())
        )
    );

-- Fleet admins can manage maintenance
CREATE POLICY "Admins can manage fleet maintenance"
    ON scheduled_maintenance FOR ALL
    USING (
        vehicle_id IN (
            SELECT v.id FROM vehicles v
            WHERE v.fleet_id IN (
                SELECT fleet_id FROM fleet_members
                WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
            )
        )
    );

COMMIT;