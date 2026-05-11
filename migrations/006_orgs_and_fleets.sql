-- VitalsDrive Organizations and Fleets Evolution
-- Version: 1.4.0
-- Description:
--   - Replace organizations table with plan/billing support (starter, professional, enterprise)
--   - Add device limits per plan (BYOH - bring your own hardware - future pricing phase)
--   - Rename org_id to organization_id for consistency
--   - Add timestamps to fleets for tracking
--   - Add organization_id to fleet_members for org-wide membership
--   - Create indexes for performance
--   - Evolve RLS policies for organization-scoped access
--   - Add invitations table for invite-only access control

BEGIN;

-- ============================================================
-- 1. Create new organizations table with plan/billing support
-- ============================================================

CREATE TABLE IF NOT EXISTS organizations (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT        NOT NULL,
    plan          TEXT        NOT NULL DEFAULT 'starter'
                    CHECK (plan IN ('starter', 'professional', 'enterprise')),
    can_add_devices BOOLEAN   NOT NULL DEFAULT true,
    max_devices   INTEGER     NULLABLE,
    owner_id      UUID        NOT NULL REFERENCES auth.users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE organizations IS 'Organization (tenant) root entity owning fleets';
COMMENT ON COLUMN organizations.plan IS 'Pricing plan: starter, professional, or enterprise';
COMMENT ON COLUMN organizations.can_add_devices IS 'Whether this org can add more devices (false if at plan limit)';
COMMENT ON COLUMN organizations.max_devices IS 'Maximum devices allowed (NULL = unlimited for enterprise)';
COMMENT ON COLUMN organizations.owner_id IS 'Owner of this organization (auth.users FK)';

-- ============================================================
-- 2. Migrate existing organizations to new schema
-- ============================================================

-- Migrate data from old organizations (name, created_at) to new
INSERT INTO organizations (id, name, plan, can_add_devices, max_devices, owner_id, created_at, updated_at)
SELECT
    o.id,
    o.name,
    CASE
        WHEN o.allowlisted = true THEN 'professional'  -- allowlisted = higher tier
        ELSE 'starter'
    END,
    true,  -- can_add_devices
    CASE
        WHEN o.allowlisted = true THEN 50  -- allowlisted = more devices
        ELSE 10
    END,
    COALESCE(
        (SELECT fm.user_id FROM fleet_members fm WHERE fm.org_id = o.id AND fm.role = 'owner' LIMIT 1),
        auth.uid()  -- fallback to current user if no owner found
    ),
    o.created_at,
    now()
FROM organizations o
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    plan = EXCLUDED.plan,
    can_add_devices = EXCLUDED.can_add_devices,
    max_devices = EXCLUDED.max_devices,
    owner_id = EXCLUDED.owner_id,
    updated_at = now();

-- ============================================================
-- 3. Drop old organizations table (replaced by new one)
-- ============================================================

DROP TABLE IF EXISTS organizations CASCADE;

-- Recreate organizations with new schema (it was dropped)
CREATE TABLE organizations (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT        NOT NULL,
    plan          TEXT        NOT NULL DEFAULT 'starter'
                    CHECK (plan IN ('starter', 'professional', 'enterprise')),
    can_add_devices BOOLEAN   NOT NULL DEFAULT true,
    max_devices   INTEGER     NULLABLE,
    owner_id      UUID        NOT NULL REFERENCES auth.users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Migrate data back
INSERT INTO organizations (id, name, plan, can_add_devices, max_devices, owner_id, created_at, updated_at)
SELECT
    o.id,
    o.name,
    CASE
        WHEN o.allowlisted = true THEN 'professional'
        ELSE 'starter'
    END,
    true,
    CASE
        WHEN o.allowlisted = true THEN 50
        ELSE 10
    END,
    COALESCE(
        (SELECT fm.user_id FROM fleet_members fm WHERE fm.org_id = o.id AND fm.role = 'owner' LIMIT 1),
        (SELECT auth.uid())
    ),
    o.created_at,
    now()
FROM organizations o
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    plan = EXCLUDED.plan,
    can_add_devices = EXCLUDED.can_add_devices,
    max_devices = EXCLUDED.max_devices,
    owner_id = EXCLUDED.owner_id,
    updated_at = now();

-- ============================================================
-- 4. Rename org_id to organization_id in fleets
-- ============================================================

ALTER TABLE fleets ADD COLUMN IF NOT EXISTS organization_id UUID;

-- Copy org_id to organization_id for existing fleets
UPDATE fleets f SET organization_id = f.org_id
WHERE f.organization_id IS NULL AND f.org_id IS NOT NULL;

-- Create default organization for fleets without org_id
INSERT INTO organizations (id, name, plan, can_add_devices, max_devices, owner_id, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000001', 'Default Organization', 'starter', true, 10,
        COALESCE((SELECT owner_id FROM fleets WHERE org_id IS NULL LIMIT 1), auth.uid()), now(), now())
ON CONFLICT (id) DO NOTHING;

-- Assign orphan fleets to default organization
UPDATE fleets SET organization_id = '00000000-0000-0000-0000-000000000001'
WHERE organization_id IS NULL;

-- Drop old org_id column and FK constraint
ALTER TABLE fleets DROP CONSTRAINT IF EXISTS fleets_org_id_fkey;
ALTER TABLE fleets DROP COLUMN IF EXISTS org_id;

-- Add FK constraint for organization_id
ALTER TABLE fleets
    ADD CONSTRAINT fleets_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;

-- Add timestamps to fleets if not present
ALTER TABLE fleets ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE fleets ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- ============================================================
-- 5. Rename org_id to organization_id in fleet_members
-- ============================================================

ALTER TABLE fleet_members ADD COLUMN IF NOT EXISTS organization_id UUID;

-- Copy org_id to organization_id for existing fleet_members
UPDATE fleet_members fm SET organization_id = fm.org_id
WHERE fm.organization_id IS NULL AND fm.org_id IS NOT NULL;

-- Assign orphan fleet_members to default organization
UPDATE fleet_members fm
SET organization_id = '00000000-0000-0000-0000-000000000001'
WHERE fm.organization_id IS NULL;

-- Drop old org_id column and FK constraint
ALTER TABLE fleet_members DROP CONSTRAINT IF EXISTS fleet_members_org_id_fkey;
ALTER TABLE fleet_members DROP COLUMN IF EXISTS org_id;

-- Add FK constraint for organization_id
ALTER TABLE fleet_members
    ADD CONSTRAINT fleet_members_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;

-- ============================================================
-- 6. Create indexes for performance
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_organizations_owner_id ON organizations(owner_id);
CREATE INDEX IF NOT EXISTS idx_organizations_plan ON organizations(plan);
CREATE INDEX IF NOT EXISTS idx_fleets_organization_id ON fleets(organization_id);
CREATE INDEX IF NOT EXISTS idx_fleet_members_organization_id ON fleet_members(organization_id);
CREATE INDEX IF NOT EXISTS idx_fleet_members_user_id ON fleet_members(user_id);
CREATE INDEX IF NOT EXISTS idx_fleet_members_org_user ON fleet_members(organization_id, user_id);

-- ============================================================
-- 7. RLS on organizations
-- ============================================================

ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;

-- Users can read organizations they are members of
CREATE POLICY "Users can read their organizations" ON organizations
    FOR SELECT USING (
        id IN (
            SELECT DISTINCT organization_id FROM fleet_members
            WHERE user_id = auth.uid()
        )
    );

-- Org owners can update their organization
CREATE POLICY "Org owners can update their organization" ON organizations
    FOR UPDATE USING (
        owner_id = auth.uid()
    );

-- Service role has full access
CREATE POLICY "Service role can manage organizations" ON organizations
    FOR ALL USING (auth.jwt()->>'role' = 'service_role');

-- ============================================================
-- 8. RLS on fleets (ensure organization context)
-- ============================================================

-- Drop existing fleet policies
DROP POLICY IF EXISTS "Org members can view fleets" ON fleets;
DROP POLICY IF EXISTS "Org admins can manage fleets" ON fleets;

-- Users can read fleets in their organization
CREATE POLICY "Org members can view fleets" ON fleets
    FOR SELECT USING (
        organization_id IN (
            SELECT organization_id FROM fleet_members WHERE user_id = auth.uid()
        )
    );

-- Org owners/admins can manage fleets
CREATE POLICY "Org admins can manage fleets" ON fleets
    FOR ALL USING (
        organization_id IN (
            SELECT organization_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- ============================================================
-- 9. RLS on fleet_members (ensure organization context)
-- ============================================================

-- Drop existing fleet_member policies
DROP POLICY IF EXISTS "Org members can view members" ON fleet_members;
DROP POLICY IF EXISTS "Org admins can manage members" ON fleet_members;

-- Members can view all members in their organization
-- Fixed: Use EXISTS to avoid infinite recursion
CREATE POLICY "Org members can view members" ON fleet_members
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM fleet_members fm
            WHERE fm.user_id = auth.uid()
            AND fm.organization_id = fleet_members.organization_id
        )
    );

-- Org owners/admins can manage members
-- Fixed: Use EXISTS to avoid infinite recursion
CREATE POLICY "Org admins can manage members" ON fleet_members
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM fleet_members fm
            WHERE fm.user_id = auth.uid()
            AND fm.organization_id = fleet_members.organization_id
            AND fm.role IN ('owner', 'admin')
        )
    );

-- ============================================================
-- 10a. Fix other RLS policies referencing fleet_members
-- ============================================================

DROP POLICY IF EXISTS "Users can read their organizations" ON organizations;
CREATE POLICY "Users can read their organizations" ON organizations
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM fleet_members fm
            WHERE fm.user_id = auth.uid()
            AND fm.organization_id = organizations.id
        )
    );

DROP POLICY IF EXISTS "Org members can view fleets" ON fleets;
DROP POLICY IF EXISTS "Org admins can manage fleets" ON fleets;
DROP POLICY IF EXISTS "Owners and admins can update fleets" ON fleets;

CREATE POLICY "Org members can view fleets" ON fleets
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM fleet_members fm
            WHERE fm.user_id = auth.uid()
            AND fm.organization_id = fleets.organization_id
        )
    );

CREATE POLICY "Org admins can manage fleets" ON fleets
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM fleet_members fm
            WHERE fm.user_id = auth.uid()
            AND fm.organization_id = fleets.organization_id
            AND fm.role IN ('owner', 'admin')
        )
    );

CREATE POLICY "Owners and admins can update fleets" ON fleets
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM fleet_members fm
            WHERE fm.user_id = auth.uid()
            AND fm.fleet_id = fleets.id
            AND fm.role IN ('owner', 'admin')
        )
    );

-- ============================================================
-- 10. Create invitations table for invite-only access
-- ============================================================

CREATE TABLE invitations (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    email           TEXT        NOT NULL,
    role            TEXT        NOT NULL CHECK (role IN ('admin', 'member', 'viewer')),
    invited_by      UUID        NOT NULL REFERENCES auth.users(id),
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE invitations IS 'Pending invitations for organization membership (invite-only access)';
COMMENT ON COLUMN invitations.role IS 'Role to assign when invitation is accepted';

-- Index for checking pending invitations
CREATE INDEX IF NOT EXISTS idx_invitations_org_email ON invitations(organization_id, email);
CREATE INDEX IF NOT EXISTS idx_invitations_expires ON invitations(expires_at);

-- ============================================================
-- 11. RLS on invitations
-- ============================================================

ALTER TABLE invitations ENABLE ROW LEVEL SECURITY;

-- Anyone can insert an invitation (for invite flow - org admins should enforce this in app logic)
CREATE POLICY "Anyone can create invitations" ON invitations
    FOR INSERT WITH CHECK (
        organization_id IN (
            SELECT organization_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- Org admins can view invitations for their org
CREATE POLICY "Org admins can view invitations" ON invitations
    FOR SELECT USING (
        organization_id IN (
            SELECT organization_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- Org admins can delete (revoke) invitations
CREATE POLICY "Org admins can delete invitations" ON invitations
    FOR DELETE USING (
        organization_id IN (
            SELECT organization_id FROM fleet_members
            WHERE user_id = auth.uid() AND role IN ('owner', 'admin')
        )
    );

-- Service role has full access
CREATE POLICY "Service role can manage invitations" ON invitations
    FOR ALL USING (auth.jwt()->>'role' = 'service_role');

-- ============================================================
-- 12. Helper functions
-- ============================================================

-- Check if user belongs to an allowlisted org
CREATE OR REPLACE FUNCTION is_user_org_allowlisted()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM fleet_members fm
        JOIN organizations o ON o.id = fm.organization_id
        WHERE fm.user_id = auth.uid()
          AND o.plan IN ('professional', 'enterprise')
        LIMIT 1
    );
END;
$$;

-- Get user's organization ID
CREATE OR REPLACE FUNCTION get_user_org_id()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
BEGIN
    RETURN (
        SELECT DISTINCT organization_id FROM fleet_members
        WHERE user_id = auth.uid()
        LIMIT 1
    );
END;
$$;

-- Get user's role in org
CREATE OR REPLACE FUNCTION get_user_org_role()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
BEGIN
    RETURN (
        SELECT fm.role FROM fleet_members fm
        WHERE fm.user_id = auth.uid()
        LIMIT 1
    );
END;
$$;

-- Check if org can add more devices (respects plan limits)
CREATE OR REPLACE FUNCTION org_can_add_device(p_org_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_can_add   BOOLEAN;
    v_max       INTEGER;
    v_current   INTEGER;
BEGIN
    SELECT o.can_add_devices, o.max_devices INTO v_can_add, v_max
    FROM organizations o
    WHERE o.id = p_org_id;

    IF NOT v_can_add THEN
        RETURN false;
    END IF;

    IF v_max IS NULL THEN
        RETURN true;  -- NULL = unlimited
    END IF;

    SELECT COUNT(*) INTO v_current
    FROM vehicles v
    JOIN fleets f ON f.id = v.fleet_id
    WHERE f.organization_id = p_org_id;

    RETURN v_current < v_max;
END;
$$;

-- Check if user's org can add more devices
CREATE OR REPLACE FUNCTION user_org_can_add_device()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
BEGIN
    RETURN org_can_add_device(get_user_org_id());
END;
$$;

-- Get device count for org
CREATE OR REPLACE FUNCTION get_org_device_count(p_org_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
BEGIN
    RETURN (
        SELECT COUNT(*)
        FROM vehicles v
        JOIN fleets f ON f.id = v.fleet_id
        WHERE f.organization_id = p_org_id
    );
END;
$$;

-- Create invitation function
CREATE OR REPLACE FUNCTION create_invitation(
    p_org_id     UUID,
    p_email      TEXT,
    p_role       TEXT,
    p_invited_by UUID,
    p_days_valid INTEGER DEFAULT 7
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_invite_id UUID;
BEGIN
    -- Check if user is org admin
    IF NOT EXISTS (
        SELECT 1 FROM fleet_members
        WHERE organization_id = p_org_id
        AND user_id = p_invited_by
        AND role IN ('owner', 'admin')
    ) THEN
        RAISE EXCEPTION 'Only org admins can create invitations';
    END IF;

    -- Check if email already has pending invitation
    IF EXISTS (
        SELECT 1 FROM invitations
        WHERE organization_id = p_org_id
        AND email = p_email
        AND expires_at > now()
    ) THEN
        RAISE EXCEPTION 'Pending invitation already exists for this email';
    END IF;

    INSERT INTO invitations (organization_id, email, role, invited_by, expires_at)
    VALUES (p_org_id, p_email, p_role, p_invited_by, now() + (p_days_valid || ' days')::interval)
    RETURNING id INTO v_invite_id;

    RETURN v_invite_id;
END;
$$;

-- Accept invitation function
CREATE OR REPLACE FUNCTION accept_invitation(
    p_invite_id UUID,
    p_user_id   UUID,
    p_fleet_id  UUID  -- Fleet to join (optional, for multi-fleet orgs)
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_invite    RECORD;
    v_fleet_id  UUID;
BEGIN
    -- Get invitation details
    SELECT * INTO v_invite FROM invitations
    WHERE id = p_invite_id AND expires_at > now();

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid or expired invitation';
    END IF;

    -- Use provided fleet_id or find first fleet in org
    v_fleet_id := p_fleet_id;
    IF v_fleet_id IS NULL THEN
        SELECT id INTO v_fleet_id FROM fleets
        WHERE organization_id = v_invite.organization_id
        LIMIT 1;
    END IF;

    IF v_fleet_id IS NULL THEN
        RAISE EXCEPTION 'No fleet found in organization';
    END IF;

    -- Check device limit
    IF NOT org_can_add_device(v_invite.organization_id) THEN
        RAISE EXCEPTION 'Organization has reached device limit';
    END IF;

    -- Add user to organization
    INSERT INTO fleet_members (organization_id, fleet_id, user_id, role)
    VALUES (v_invite.organization_id, v_fleet_id, p_user_id, v_invite.role)
    ON CONFLICT (fleet_id, user_id) DO UPDATE SET role = v_invite.role;

    -- Delete the invitation
    DELETE FROM invitations WHERE id = p_invite_id;

    RETURN true;
END;
$$;

-- Update organization function (for plan/name changes)
CREATE OR REPLACE FUNCTION update_organization(
    p_org_id UUID,
    p_name TEXT DEFAULT NULL,
    p_plan TEXT DEFAULT NULL,
    p_can_add_devices BOOLEAN DEFAULT NULL,
    p_max_devices INTEGER DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Only org owner can update
    IF NOT EXISTS (
        SELECT 1 FROM organizations
        WHERE id = p_org_id AND owner_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'Only organization owner can update organization';
    END IF;

    UPDATE organizations SET
        name = COALESCE(p_name, name),
        plan = COALESCE(p_plan, plan),
        can_add_devices = COALESCE(p_can_add_devices, can_add_devices),
        max_devices = COALESCE(p_max_devices, max_devices),
        updated_at = now()
    WHERE id = p_org_id;

    RETURN true;
END;
$$;

-- ============================================================
-- 13. Update existing functions to use organization_id
-- ============================================================

CREATE OR REPLACE FUNCTION create_organization_and_first_fleet(
    p_org_name   TEXT,
    p_fleet_name TEXT,
    p_user_id    UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_org_id   UUID;
    v_fleet_id UUID;
    v_result   JSONB;
BEGIN
    -- Create organization
    INSERT INTO organizations (name, owner_id)
    VALUES (p_org_name, p_user_id)
    RETURNING id INTO v_org_id;

    -- Create first fleet
    INSERT INTO fleets (name, organization_id, owner_id, provisioning_code)
    VALUES (
        COALESCE(NULLIF(p_fleet_name, ''), p_org_name || ' Fleet'),
        v_org_id,
        p_user_id,
        substr(md5(random()::text), 1, 8)
    )
    RETURNING id INTO v_fleet_id;

    -- Add user as owner of the org (org-wide membership)
    INSERT INTO fleet_members (organization_id, fleet_id, user_id, role)
    VALUES (v_org_id, v_fleet_id, p_user_id, 'owner');

    RETURN jsonb_build_object(
        'success',   true,
        'org_id',    v_org_id,
        'fleet_id',  v_fleet_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION check_user_login_status(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_org_id       UUID;
    v_plan         TEXT;
    v_has_org      BOOLEAN;
    v_role         TEXT;
BEGIN
    -- Check if user has any org membership
    SELECT fm.organization_id, fm.role INTO v_org_id, v_role
    FROM fleet_members fm
    WHERE fm.user_id = p_user_id
    LIMIT 1;

    v_has_org := (v_org_id IS NOT NULL);

    IF NOT v_has_org THEN
        RETURN jsonb_build_object(
            'can_login', false,
            'reason',    'no_organization',
            'org_id',    NULL
        );
    END IF;

    -- Check plan (starter orgs have limited access for MVP)
    SELECT o.plan INTO v_plan
    FROM organizations o
    WHERE o.id = v_org_id;

    -- For MVP: all logged-in users can access
    RETURN jsonb_build_object(
        'can_login', true,
        'reason',    'ok',
        'org_id',    v_org_id,
        'role',      v_role,
        'plan',      v_plan
    );
END;
$$;

CREATE OR REPLACE FUNCTION get_user_primary_org(p_user_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
BEGIN
    RETURN (
        SELECT organization_id FROM fleet_members
        WHERE user_id = p_user_id
        LIMIT 1
    );
END;
$$;

COMMIT;
