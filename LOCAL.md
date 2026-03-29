# VitalsDrive Supabase - Local Development

This directory contains the Supabase configuration for local development.

## Setup

### 1. Install Supabase CLI (if not already)

```bash
npm install -g supabase
```

### 2. Initialize Local Supabase

```bash
cd supabase
supabase init
```

This creates:
- `config.toml` - Local project configuration
- `volumes/` - PostgreSQL data volume

### 3. Start Local Supabase

```bash
supabase start
```

This starts:
- PostgreSQL on port 54322
- Supabase Studio on http://localhost:54323
- API on port 54321

### 4. Apply Migrations Locally

```bash
supabase db reset
```

This resets the local DB and applies all migrations.

### 5. Load Seed Data (Optional)

```sql
-- In Supabase Studio (http://localhost:54323) or via psql:
\i supabase/seed/001_seed_data.sql
```

## Environment URLs

| Environment | URL |
|-------------|-----|
| Local Studio | http://localhost:54323 |
| Local PostgreSQL | postgresql://postgres:postgres@localhost:54322/postgres |
| Local API | http://localhost:54321 |

## Local vs Production

| Operation | Local | Production |
|-----------|-------|------------|
| Apply migrations | `supabase db push` | Use GitHub Actions CI/CD |
| Reset DB | `supabase db reset` | Manual migration via Dashboard |
| View data | http://localhost:54323 | app.supabase.com |
| Branch | `git checkout -b feature/xyz` | N/A |

## Useful Commands

```bash
supabase status      # Check if local instance is running
supabase stop        # Stop local instance
supabase db reset    # Reset local DB (WARNING: deletes data)
supabase db push     # Push migrations to linked project
supabase link        # Link to production project
```