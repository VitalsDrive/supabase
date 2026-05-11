-- Migration: 007_create_users_clerk.sql
-- Creates users table with external auth provider support (Clerk, Auth0, etc.)
-- Adds device authentication (SMS login/password) for Teltonika devices

-- Create users table
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_auth_id TEXT NOT NULL,
  external_auth_provider TEXT NOT NULL DEFAULT 'clerk',
  email TEXT NOT NULL UNIQUE,
  display_name VARCHAR(100),
  preferences JSONB DEFAULT '{"theme": "dark", "notifications": true}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for external auth lookups
CREATE INDEX idx_users_external_auth ON users(external_auth_id, external_auth_provider);

-- RLS
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Users can read their own record
CREATE POLICY "Users can read own record" ON users
  FOR SELECT USING (true);

-- Service role can manage all
CREATE POLICY "Service role can manage users" ON users
  FOR ALL USING (auth.jwt()->>'role' = 'service_role');

COMMENT ON TABLE users IS 'Application users linked to external auth providers (Clerk, Auth0, etc.)';

-- ============================================
-- Device Authentication (Teltonika)
-- ============================================

-- Add authentication columns to devices table (if not exists)
DO $$
BEGIN
  -- Add sms_login column if not exists
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'devices' AND column_name = 'sms_login'
  ) THEN
    ALTER TABLE devices ADD COLUMN sms_login TEXT;
  END IF;

  -- Add sms_password column if not exists
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'devices' AND column_name = 'sms_password'
  ) THEN
    ALTER TABLE devices ADD COLUMN sms_password TEXT;
  END IF;

  -- Add index for faster lookups by credentials
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_devices_sms_credentials'
  ) THEN
    CREATE INDEX idx_devices_sms_credentials ON devices(sms_login, sms_password) WHERE sms_login IS NOT NULL;
  END IF;
END
$$;

COMMENT ON COLUMN devices.sms_login IS 'SMS/GPRS login for device authentication (Teltonika)';
COMMENT ON COLUMN devices.sms_password IS 'SMS/GPRS password for device authentication (Teltonika)';