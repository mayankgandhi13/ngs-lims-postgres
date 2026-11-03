-- 00_run_all.sql
-- Drops and rebuilds the whole LIMS from scratch. Run with:
--   psql -v ON_ERROR_STOP=1 -f sql/00_run_all.sql      (or: make reset)
-- 08_analysis.sql is read-only and runs separately (make analysis).

\set ON_ERROR_STOP on
set client_min_messages = warning;
set timezone = 'UTC';

\echo '== ngs-lims-postgres: dropping schemas and roles =='
drop schema if exists reporting cascade;
drop schema if exists audit cascade;
drop schema if exists lims cascade;

-- Roles are cluster-wide, so drop them explicitly to make reset idempotent.
do $$
declare
  r text;
begin
  foreach r in array array['report_reader', 'pathologist', 'bioinformatician', 'lab_tech'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('drop owned by %I', r);
      execute format('drop role %I', r);
    end if;
  end loop;
end $$;

\echo '== 01 schema =='
\ir 01_schema.sql
\echo '== 02 indexes =='
\ir 02_indexes.sql
\echo '== 03 functions =='
\ir 03_functions.sql
\echo '== 04 triggers =='
\ir 04_triggers.sql
\echo '== 05 views =='
\ir 05_views.sql
\echo '== 06 security =='
\ir 06_security.sql
\echo '== 07 seed =='
\ir 07_seed.sql
\echo '== rebuild complete =='
