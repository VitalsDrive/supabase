-- VitalsDrive Fleet Provisioning & Vehicle Management
-- Version: 1.1.0
-- Description: Add provisioning_code for device self-registration, pending vehicle status, and updated RLS

BEGIN;

-- ============================================
-- Add provisioning_code to fleets for device self-registration
-- ============================================
ALTER TABLE fleets ADD COLUMN provisioning_code VARCHAR(20) UNIQUE;

-- Generate a random provisioning code for existing fleets
UPDATE fleets SET provisioning_code = 
    substr(md5(random()::text), 1, 8)
WHERE provisioning_code IS NULL;

-- Make provisioning_code NOT NULL after populating
ALTER TABLE fleets ALTER COLUMN provisioning_code SET NOT NULL;

-- ============================================
-- Add status 'pending' to vehicles for device registration workflow
-- ============================================
ALTER TABLE vehicles DROP CONSTRAINT vehicles_status_check;
ALTER TABLE vehicles ADD CONSTRAINT vehicles_status_check 
    CHECK (status IN ('pending', 'active', 'inactive', 'maintenance'));

-- Update existing vehicles to 'active' (they're already registered)
UPDATE vehicles SET status = 'active' WHERE status IS NULL OR status NOT IN ('pending', 'active', 'inactive', 'maintenance');

-- ============================================
-- Add last_seen timestamp for device tracking
-- ============================================
ALTER TABLE vehicles ADD COLUMN last_seen TIMESTAMPTZ;

-- ============================================
-- Add device_id column for OBD2 device tracking
-- ============================================
ALTER TABLE vehicles ADD COLUMN device_id VARCHAR(100);

-- ============================================
-- Update RLS Policies for fleet-based access
-- ============================================

-- Enable RLS on all tables
ALTER TABLE fleets ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE fleet_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Drop existing policies and recreate with proper fleet-based access

-- Fleets: owners and admins can view their fleet
DROP POLICY IF EXISTS "Enable read access for all users" ON fleets;
DROP POLICY IF EXISTS "Users can view their own fleets" ON fleets;

CREATE POLICY "Fleet members can view their fleets"
    ON fleets FOR SELECT
    USING (
        id IN (
            SELECT fleet_id FROM fleet_members 
            WHERE user_id = auth.uid()
        )
    );

-- Fleet members with owner/admin role can update their fleet
CREATE POLICY "Fleet owners/admins can update fleets"
    ON fleets FOR UPDATE
    USING (
        id IN (
            SELECT fleet_id FROM fleet_members 
            WHERE user_id = auth.uid() 
            AND role IN ('owner', 'admin')
        )
    );

-- Only owners can delete fleets
CREATE POLICY "Fleet owners can delete fleets"
    ON fleets FOR DELETE
    USING (
        id IN (
            SELECT fleet_id FROM fleet_members 
            WHERE user_id = auth.uid() 
            AND role = 'owner'
        )
    );

-- Vehicles: fleet members can view vehicles in their fleet
DROP POLICY IF EXISTS "Enable read access for all users" ON vehicles;
DROP POLICY IF EXISTS "Users can view vehicles in their fleet" ON vehicles;

CREATE POLICY "Fleet members can view vehicles"
    ON vehicles FOR SELECT
    USING (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members 
            WHERE user_id = auth.uid()
        )
    );

-- Fleet owners/admins can insert/update/delete vehicles
DROP POLICY IF EXISTS "Service role can insert vehicles" ON vehicles;

CREATE POLICY "Fleet owners/admins can manage vehicles"
    ON vehicles FOR ALL
    USING (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members 
            WHERE user_id = auth.uid() 
            AND role IN ('owner', 'admin')
        )
    );

-- Fleet members: owners can view membership
DROP POLICY IF EXISTS "Enable read access for all users" ON fleet_members;

CREATE POLICY "Fleet owners/admins can view members"
    ON fleet_members FOR SELECT
    USING (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members 
            WHERE user_id = auth.uid() 
            AND role IN ('owner', 'admin')
        )
    );

-- Fleet owners can manage members (invite, remove, change role)
DROP POLICY IF EXISTS "Enable write access for all users" ON fleet_members;

CREATE POLICY "Fleet owners can manage members"
    ON fleet_members FOR ALL
    USING (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members 
            WHERE user_id = auth.uid() 
            AND role = 'owner'
        )
    );

-- Allow insert of new members (for invitation flow)
CREATE POLICY "Fleet owners can insert members"
    ON fleet_members FOR INSERT
    WITH CHECK (
        fleet_id IN (
            SELECT fleet_id FROM fleet_members 
            WHERE user_id = auth.uid() 
            AND role = 'owner'
        )
    );

-- Users: users can view their own profile
DROP POLICY IF EXISTS "Enable read access for all users" ON users;
DROP POLICY IF EXISTS "Users can update own profile" ON users;

CREATE POLICY "Users can view their own profile"
    ON users FOR SELECT
    USING (id = auth.uid());

CREATE POLICY "Users can update own profile"
    ON users FOR UPDATE
    USING (id = auth.uid());

-- ============================================
-- Create function to regenerate provisioning code
-- ============================================
CREATE OR REPLACE FUNCTION regenerate_provisioning_code(fleet_uuid UUID)
RETURNS VARCHAR(20) AS $$
DECLARE
    new_code VARCHAR(20);
BEGIN
    new_code := substr(md5(random()::text), 1, 8);
    
    UPDATE fleets 
    SET provisioning_code = new_code, updated_at = NOW()
    WHERE id = fleet_uuid;
    
    RETURN new_code;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- Create function to approve pending vehicle
-- ============================================
CREATE OR REPLACE FUNCTION approve_vehicle(vehicle_uuid UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE vehicles 
    SET status = 'active', updated_at = NOW()
    WHERE id = vehicle_uuid AND status = 'pending';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- Create function to register device and create pending vehicle
-- ============================================
CREATE OR REPLACE FUNCTION register_device_and_vehicle(
    p_fleet_code VARCHAR(20),
    p_vin VARCHAR(17),
    p_make VARCHAR(50),
    p_model VARCHAR(50),
    p_year INTEGER,
    p_device_id VARCHAR(100)
)
RETURNS UUID AS $$
DECLARE
    v_fleet_id UUID;
    v_vehicle_id UUID;
BEGIN
    -- Lookup fleet by provisioning code
    SELECT id INTO v_fleet_id 
    FROM fleets 
    WHERE provisioning_code = p_fleet_code;
    
    IF v_fleet_id IS NULL THEN
        RAISE EXCEPTION 'Invalid provisioning code';
    END IF;
    
    -- Check if vehicle with this VIN already exists
    SELECT id INTO v_vehicle_id 
    FROM vehicles 
    WHERE vin = p_vin;
    
    IF v_vehicle_id IS NOT NULL THEN
        -- Update existing vehicle
        UPDATE vehicles 
        SET fleet_id = v_fleet_id, 
            device_id = p_device_id, 
            last_seen = NOW(),
            updated_at = NOW()
        WHERE id = v_vehicle_id;
        RETURN v_vehicle_id;
    ELSE
        -- Create new pending vehicle
        INSERT INTO vehicles (fleet_id, vin, make, model, year, device_id, status)
        VALUES (v_fleet_id, p_vin, p_make, p_model, p_year, p_device_id, 'pending')
        RETURNING id INTO v_vehicle_id;
        RETURN v_vehicle_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- Update seed data with provisioning codes
-- ============================================
UPDATE fleets SET provisioning_code = 'DEMO001' WHERE name = 'Demo Fleet';

COMMIT;
