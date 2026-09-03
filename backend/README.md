# Backend deployment assets

Files here are published so the production server can `git pull` them instead
of having them copied over by hand.

## `migrations.sql`

The full schema of record. **Idempotent** — every `CREATE TABLE`, `ADD COLUMN`
and `CREATE INDEX` uses `IF NOT EXISTS`, every seed `INSERT` has
`ON CONFLICT ... DO NOTHING`, and the question seed is wrapped in a
`NOT EXISTS` guard. Safe to re-run in full at any time, which means you never
have to work out which migrations were already applied.

Apply it:

```bash
cd /var/www/cydo_serve && git pull origin main
sudo -u postgres psql -d cyberdojo -f /var/www/cydo_serve/backend/migrations.sql
```

Then restart the API so the ORM models match the schema:

```bash
source /root/cyberdojo/backend/venv/bin/activate
pkill -9 gunicorn && sleep 2
cd /root/cyberdojo/backend
gunicorn main:app -w 4 -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000 --timeout 300 --daemon
```

### Verifying what's applied

```sql
SELECT item, CASE WHEN present THEN 'yes' ELSE 'NO  <-- missing' END AS status FROM (
  SELECT 'table  assessments'              AS item, to_regclass('public.assessments')          IS NOT NULL AS present
  UNION ALL SELECT 'table  assessment_questions',   to_regclass('public.assessment_questions') IS NOT NULL
  UNION ALL SELECT 'table  assessment_attempts',    to_regclass('public.assessment_attempts')  IS NOT NULL
  UNION ALL SELECT 'table  assessment_violations',  to_regclass('public.assessment_violations') IS NOT NULL
  UNION ALL SELECT 'col    universities.enforce_domain',          EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='universities'         AND column_name='enforce_domain')
  UNION ALL SELECT 'col    university_programs.stat_duration',    EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='university_programs'  AND column_name='stat_duration')
  UNION ALL SELECT 'col    university_semesters.links_total',     EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='university_semesters' AND column_name='links_total')
  UNION ALL SELECT 'col    university_semesters.links_checked_at',EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='university_semesters' AND column_name='links_checked_at')
) t ORDER BY item;
```

## Not published here

`main_all_in_one.py` is **not** in this repo. It currently carries hardcoded
AWS credentials and a lab password in source, and this repository is public.
It has to be moved onto environment variables before it can be published here.
Until then it is still copied to the server by hand.
