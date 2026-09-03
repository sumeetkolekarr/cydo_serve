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

## `main_all_in_one.py`

The production API — the only backend file that ships. Deploy it with:

```bash
cd /var/www/cydo_serve && git pull origin main
cp /var/www/cydo_serve/backend/main_all_in_one.py /root/cyberdojo/backend/main.py

source /root/cyberdojo/backend/venv/bin/activate
pkill -9 gunicorn && sleep 2
cd /root/cyberdojo/backend
gunicorn main:app -w 4 -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000 --timeout 300 --daemon
```

### Required environment

This repository is public, so the file carries **no credentials**. Every secret
is read from `/root/cyberdojo/backend/.env`, and these must all be present
before you deploy:

| Variable | Used for |
|---|---|
| `DATABASE_URL` | Postgres connection. The app raises at startup if unset. |
| `SECRET_KEY` | JWT signing |
| `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET` | Payments |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | EC2 lab provisioning |
| `SMTP_USER`, `SMTP_PASSWORD` | Outbound email |
| `GUI_LAB_VNC_PASSWORD` | Credential baked into the lab AMI; returned to students and set by the Ubuntu lab user-data |

Missing values fail differently: `DATABASE_URL` stops the process at import,
while the others fail at the point of use — labs won't launch without the AWS
pair, email silently fails without the SMTP pair.
