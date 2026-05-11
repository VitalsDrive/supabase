-- Migration: 008_add_org_and_roles_to_users.sql
-- Adds organization_id and roles columns to users table
-- Also creates organizations table if not exists

-- Create organizations table if not exists
CREATE TABLE IF NOT EXISTS organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  owner_id UUID, -- References users.id
  settings JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add organization_id column to users if not exists
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'organization_id'
  ) THEN
    ALTER TABLE users ADD COLUMN organization_id UUID REFERENCES organizations(id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'roles'
  ) THEN
    ALTER TABLE users ADD COLUMN roles TEXT[] DEFAULT ARRAY['member'];
  END IF;
END
$$;

-- Index for organization lookups
CREATE INDEX IF NOT EXISTS idx_users_organization ON users(organization_id);

COMMENT ON COLUMN users.organization_id IS 'User''s primary organization';
COMMENT ON COLUMN users.roles IS 'User roles (owner, admin, member, viewer)';
