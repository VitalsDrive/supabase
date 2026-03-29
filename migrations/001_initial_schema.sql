-- VitalsDrive Initial Schema
-- Version: 1.0.0
-- Description: Core tables for telemetry, vehicles, fleets, users, and alerts

BEGIN;

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- TABLE: telemetry_logs
-- Description: Vehicle telemetry data points ingested from IoT sensors
-- ============================================
CREATE TABLE telemetry_logs (
    id          BIGSERIAL PRIMARY KEY,
    vehicle_id  UUID NOT NULL,
    lat         DECIMAL(10, 7) CHECK (lat >= -90 AND lat <= 90),
    lng         DECIMAL(10, 7) CHECK (lng >= -180 AND lng <= 180),
    temp        FLOAT,           -- Coolant temperature (°C)
    voltage     FLOAT,           -- Battery voltage (V)
    rpm         INTEGER CHECK (rpm >= 0),
    dtc_codes   TEXT[],          -- Array of active diagnostic trouble codes
    timestamp   TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE telemetry_logs IS 'Vehicle telemetry data points ingested from IoT sensors';
COMMENT ON COLUMN telemetry_logs.dtc_codes IS 'Array of active diagnostic trouble codes, empty array means no faults';

-- ============================================
-- TABLE: fleets
-- Description: Fleet groupings for organizing vehicles
-- ============================================
CREATE TABLE fleets (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(100) NOT NULL,
    owner_id    UUID NOT NULL,  -- References auth.users
    settings    JSONB DEFAULT '{"timezone": "UTC", "data_retention_days": 90}',
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE fleets IS 'Fleet groupings for organizing vehicles';

-- ============================================
-- TABLE: users
-- Description: Application users with role-based access
-- ============================================
CREATE TABLE users (
    id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email         VARCHAR(255) NOT NULL,
    display_name  VARCHAR(100),
    role          VARCHAR(20) DEFAULT 'viewer' CHECK (role IN ('admin', 'editor', 'viewer')),
    preferences   JSONB DEFAULT '{"theme": "dark", "notifications": true}',
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    last_login    TIMESTAMPTZ
);

COMMENT ON TABLE users IS 'Application users with role-based access';

-- ============================================
-- TABLE: vehicles
-- Description: Registered vehicles belonging to fleets
-- ============================================
CREATE TABLE vehicles (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fleet_id      UUID NOT NULL,
    vin           VARCHAR(17) UNIQUE NOT NULL,  -- Vehicle Identification Number
    make          VARCHAR(50) NOT NULL,
    model         VARCHAR(50) NOT NULL,
    year          INTEGER,
    license_plate VARCHAR(20),
    status        VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'maintenance')),
    metadata      JSONB DEFAULT '{}',
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE vehicles IS 'Registered vehicles belonging to fleets';

-- Add foreign key for vehicles.fleet_id after fleets table exists
ALTER TABLE vehicles ADD CONSTRAINT fk_vehicles_fleet
    FOREIGN KEY (fleet_id) REFERENCES fleets(id) ON DELETE CASCADE;

-- ============================================
-- TABLE: fleet_members
-- Description: Junction table for user-fleet many-to-many relationship
-- ============================================
CREATE TABLE fleet_members (
    fleet_id    UUID REFERENCES fleets(id) ON DELETE CASCADE,
    user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
    role        VARCHAR(20) DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
    joined_at   TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (fleet_id, user_id)
);

COMMENT ON TABLE fleet_members IS 'Junction table for user-fleet many-to-many relationship';

-- ============================================
-- TABLE: alerts
-- Description: Generated alerts from telemetry threshold violations
-- ============================================
CREATE TABLE alerts (
    id            BIGSERIAL PRIMARY KEY,
    vehicle_id    UUID NOT NULL,
    fleet_id      UUID NOT NULL,
    severity      VARCHAR(10) NOT NULL CHECK (severity IN ('critical', 'warning', 'info')),
    code          VARCHAR(50) NOT NULL,  -- e.g., 'ENGINE_OVERTEMP', 'LOW_VOLTAGE'
    message       TEXT NOT NULL,
    dtc_codes     TEXT[],               -- Related diagnostic codes
    lat           DECIMAL(10, 7),
    lng           DECIMAL(10, 7),
    acknowledged  BOOLEAN DEFAULT FALSE,
    acknowledged_by UUID REFERENCES users(id),
    acknowledged_at TIMESTAMPTZ,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    resolved_at   TIMESTAMPTZ
);

-- Add foreign keys for alerts
ALTER TABLE alerts ADD CONSTRAINT fk_alerts_vehicle
    FOREIGN KEY (vehicle_id) REFERENCES vehicles(id) ON DELETE CASCADE;
ALTER TABLE alerts ADD CONSTRAINT fk_alerts_fleet
    FOREIGN KEY (fleet_id) REFERENCES fleets(id) ON DELETE CASCADE;

COMMENT ON TABLE alerts IS 'Generated alerts from telemetry threshold violations';

-- ============================================
-- TABLE: telemetry_rules
-- Description: User-defined threshold rules for generating alerts
-- ============================================
CREATE TABLE telemetry_rules (
    id          BIGSERIAL PRIMARY KEY,
    fleet_id    UUID NOT NULL REFERENCES fleets(id) ON DELETE CASCADE,
    name        VARCHAR(100) NOT NULL,
    metric      VARCHAR(20) NOT NULL CHECK (metric IN ('temp', 'voltage', 'rpm')),
    operator    VARCHAR(5) NOT NULL CHECK (operator IN ('gt', 'lt', 'gte', 'lte', 'eq')),
    threshold   FLOAT NOT NULL,
    severity    VARCHAR(10) NOT NULL CHECK (severity IN ('critical', 'warning', 'info')),
    enabled     BOOLEAN DEFAULT TRUE,
    cooldown_seconds INTEGER DEFAULT 300,  -- Minimum time between repeated alerts
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE telemetry_rules IS 'User-defined threshold rules for generating alerts';

-- ============================================
-- TABLE: scheduled_maintenance
-- Description: Vehicle maintenance schedule tracking
-- ============================================
CREATE TABLE scheduled_maintenance (
    id            BIGSERIAL PRIMARY KEY,
    vehicle_id    UUID NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
    type          VARCHAR(50) NOT NULL,  -- e.g., 'oil_change', 'tire_rotation', 'inspection'
    description   TEXT,
    due_date      DATE NOT NULL,
    due_mileage   INTEGER,
    completed     BOOLEAN DEFAULT FALSE,
    completed_at  TIMESTAMPTZ,
    cost          DECIMAL(10, 2),
    notes         TEXT,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE scheduled_maintenance IS 'Vehicle maintenance schedule tracking';

-- ============================================
-- INDEXES
-- ============================================

-- telemetry_logs indexes for common query patterns
CREATE INDEX idx_telemetry_logs_vehicle_timestamp 
    ON telemetry_logs(vehicle_id, timestamp DESC);
CREATE INDEX idx_telemetry_logs_timestamp 
    ON telemetry_logs(timestamp DESC);
CREATE INDEX idx_telemetry_logs_dtc_codes 
    ON telemetry_logs USING GIN(dtc_codes);

-- alerts indexes
CREATE INDEX idx_alerts_fleet_acknowledged 
    ON alerts(fleet_id, acknowledged) WHERE acknowledged = FALSE;
CREATE INDEX idx_alerts_vehicle_created 
    ON alerts(vehicle_id, created_at DESC);

-- vehicles indexes
CREATE INDEX idx_vehicles_fleet_id 
    ON vehicles(fleet_id);
CREATE INDEX idx_vehicles_vin 
    ON vehicles(vin);

-- fleet_members index (critical for RLS performance)
CREATE INDEX idx_fleet_members_user_id 
    ON fleet_members(user_id);

-- telemetry_rules index
CREATE INDEX idx_telemetry_rules_fleet_enabled 
    ON telemetry_rules(fleet_id, enabled) WHERE enabled = TRUE;

COMMIT;