-- VitalsDrive Seed Data
-- Version: 1.0.0
-- Description: Development seed data for testing and local development
-- Note: This should only be used in development environments

BEGIN;

-- ============================================
-- Create test user (auth.users)
-- Note: This requires authentication to be handled properly
-- The user record is created automatically by Supabase Auth
-- This script assumes the user already exists in auth.users
-- ============================================

-- Insert a test user profile (after auth.users entry exists)
-- Replace 'test-user-uuid' with actual auth.users id after signup

-- ============================================
-- Create demo fleet
-- ============================================
INSERT INTO fleets (id, name, owner_id, settings) VALUES
    ('00000000-0000-0000-0000-000000000001', 'Demo Fleet', '00000000-0000-0000-0000-000000000001', 
     '{"timezone": "America/Los_Angeles", "data_retention_days": 90}');

-- ============================================
-- Create demo vehicles
-- ============================================
INSERT INTO vehicles (id, fleet_id, vin, make, model, year, license_plate, status) VALUES
    ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 
     '1HGBH41JXMN109186', 'Honda', 'Civic', 2022, 'ABC-1234', 'active'),
    ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', 
     '2T1BURHE5JC075897', 'Toyota', 'Camry', 2021, 'XYZ-5678', 'active'),
    ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000001', 
     '3FA6P0LU8JR145678', 'Ford', 'F-150', 2023, 'DEF-9012', 'active');

-- ============================================
-- Create demo fleet membership
-- ============================================
INSERT INTO fleet_members (fleet_id, user_id, role) VALUES
    ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'owner');

-- ============================================
-- Create telemetry rules (default alert thresholds)
-- ============================================
INSERT INTO telemetry_rules (fleet_id, name, metric, operator, threshold, severity, cooldown_seconds) VALUES
    -- Critical: Engine overheating
    ('00000000-0000-0000-0000-000000000001', 'ENGINE_OVERTEMP', 'temp', 'gt', 105, 'critical', 300),
    -- Warning: High coolant temp
    ('00000000-0000-0000-0000-000000000001', 'COOLANT_HOT', 'temp', 'gt', 95, 'warning', 300),
    -- Critical: Low battery voltage
    ('00000000-0000-0000-0000-000000000001', 'LOW_VOLTAGE', 'voltage', 'lt', 12.0, 'critical', 600),
    -- Warning: Battery voltage dropping
    ('00000000-0000-0000-0000-000000000001', 'BATTERY_LOW', 'voltage', 'lt', 12.4, 'warning', 600),
    -- Warning: High RPM
    ('00000000-0000-0000-0000-000000000001', 'HIGH_RPM', 'rpm', 'gt', 6000, 'warning', 60);

-- ============================================
-- Create sample telemetry data (last 24 hours)
-- ============================================
-- Generate realistic telemetry for vehicle 1 (Honda Civic)
INSERT INTO telemetry_logs (vehicle_id, lat, lng, temp, voltage, rpm, dtc_codes, timestamp)
SELECT 
    '00000000-0000-0000-0000-000000000011',
    37.7749 + (random() - 0.5) * 0.01,  -- ~SF Bay Area
    -122.4194 + (random() - 0.5) * 0.01,
    85 + random() * 10,  -- Normal operating temp 85-95°C
    12.4 + random() * 0.8,  -- Voltage 12.4-13.2V
    1000 + random() * 2000,  -- RPM 1000-3000
    ARRAY[]::TEXT[],
    NOW() - (n || ' hours')::INTERVAL
FROM generate_series(1, 24) AS n;

-- Generate telemetry for vehicle 2 (Toyota Camry)
INSERT INTO telemetry_logs (vehicle_id, lat, lng, temp, voltage, rpm, dtc_codes, timestamp)
SELECT 
    '00000000-0000-0000-0000-000000000012',
    37.7849 + (random() - 0.5) * 0.01,
    -122.4094 + (random() - 0.5) * 0.01,
    88 + random() * 8,
    12.5 + random() * 0.7,
    1200 + random() * 1800,
    ARRAY[]::TEXT[],
    NOW() - (n || ' hours')::INTERVAL
FROM generate_series(1, 24) AS n;

-- Generate telemetry for vehicle 3 (Ford F-150)
INSERT INTO telemetry_logs (vehicle_id, lat, lng, temp, voltage, rpm, dtc_codes, timestamp)
SELECT 
    '00000000-0000-0000-0000-000000000013',
    37.7649 + (random() - 0.5) * 0.01,
    -122.4294 + (random() - 0.5) * 0.01,
    82 + random() * 12,
    12.3 + random() * 0.9,
    900 + random() * 2200,
    ARRAY[]::TEXT[],
    NOW() - (n || ' hours')::INTERVAL
FROM generate_series(1, 24) AS n;

-- ============================================
-- Create a sample DTC alert (Check Engine)
-- ============================================
INSERT INTO alerts (vehicle_id, fleet_id, severity, code, message, dtc_codes, lat, lng, created_at) VALUES
    ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 
     'warning', 'P0420', 
     'Catalyst System Efficiency Below Threshold - The catalytic converter may be failing',
     ARRAY['P0420'], 37.7749, -122.4194, NOW() - '2 hours'::INTERVAL);

-- ============================================
-- Create sample maintenance records
-- ============================================
INSERT INTO scheduled_maintenance (vehicle_id, type, description, due_date, due_mileage) VALUES
    ('00000000-0000-0000-0000-000000000011', 'oil_change', 'Synthetic oil change', CURRENT_DATE + 30, 55000),
    ('00000000-0000-0000-0000-000000000011', 'tire_rotation', 'Rotate tires and check pressure', CURRENT_DATE + 15, NULL),
    ('00000000-0000-0000-0000-000000000012', 'oil_change', 'Conventional oil change', CURRENT_DATE + 45, 48000),
    ('00000000-0000-0000-0000-000000000013', 'inspection', 'Annual safety inspection', CURRENT_DATE + 60, NULL);

COMMIT;

-- ============================================
-- Verify data
-- ============================================
SELECT 'Fleets:' as table_name, COUNT(*) as count FROM fleets
UNION ALL
SELECT 'Vehicles:', COUNT(*) FROM vehicles
UNION ALL
SELECT 'Telemetry Logs:', COUNT(*) FROM telemetry_logs
UNION ALL
SELECT 'Alerts:', COUNT(*) FROM alerts
UNION ALL
SELECT 'Telemetry Rules:', COUNT(*) FROM telemetry_rules
UNION ALL
SELECT 'Scheduled Maintenance:', COUNT(*) FROM scheduled_maintenance;