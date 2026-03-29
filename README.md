# VitalsDrive Supabase

Database schema, migrations, and seed data for the VitalsDrive platform.

## Project Reference

```
Production: odwctmlawibhaclptsew
```

## Structure

```
supabase/
├── migrations/
│   ├── 001_initial_schema.sql    # Core tables + indexes
│   ├── 002_rls_policies.sql      # Row Level Security policies
│   └── 003_functions_triggers.sql # Functions, triggers, realtime
├── seed/
│   └── 001_seed_data.sql          # Development seed data
├── LOCAL.md                       # Local development guide
├── .env.example                   # Environment template
└── PROJECT_REF                    # Supabase project reference
```

## Quick Start (Local Development)

```bash
# Install Supabase CLI
npm install -g supabase

# Initialize local Supabase (first time only)
supabase init

# Start local instance
supabase start

# Apply migrations
supabase db reset

# Access local Studio
# http://localhost:54323
```

## Environment Variables

```bash
# Get from Dashboard > Settings > API
SUPABASE_URL=https://odwctmlawibhaclptsew.supabase.co
SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
```

## Database Schema

See [docs/PRD-Layer2-Data-Storage.md](../../docs/PRD-Layer2-Data-Storage.md) for full documentation.

### Core Tables

| Table | Purpose |
|-------|---------|
| `telemetry_logs` | Vehicle telemetry data |
| `vehicles` | Registered vehicles |
| `fleets` | Fleet groupings |
| `users` | Application users |
| `fleet_members` | User-fleet relationships |
| `alerts` | Threshold-based alerts |
| `telemetry_rules` | Configurable alert rules |
| `scheduled_maintenance` | Maintenance tracking |

### Key Features

- **RLS**: Multi-tenant isolation via Row Level Security
- **Realtime**: WebSocket subscriptions on telemetry_logs and alerts
- **Auto-Alerts**: Trigger function generates alerts on threshold violations

## Migrations

```bash
# Push migrations to production
supabase db push

# Create new migration
supabase migration new add_new_table

# Reset local database (WARNING: deletes local data)
supabase db reset
```

## Seed Data

Load development seed data:

```sql
-- In psql or Supabase Studio
\i supabase/seed/001_seed_data.sql
```

This creates:
- 1 demo fleet
- 3 demo vehicles
- Default telemetry rules
- 24 hours of sample telemetry
- Sample alerts and maintenance records

## Production Notes

- Free tier: 500MB DB, 2GB bandwidth
- Point-in-time recovery enabled
- Daily automated backups
- Connection limit: 60 concurrent

## Troubleshooting

### Local migrations fail

```bash
supabase stop
supabase start
supabase db reset
```

### Can't connect to production

```bash
supabase link --project-ref odwctmlawibhaclptsew
```

### View migration status

```bash
supabase migration list
```