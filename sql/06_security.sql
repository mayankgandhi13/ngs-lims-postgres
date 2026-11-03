-- 06_security.sql
-- Role separation for a clinical lab. Roles are NOLOGIN group roles; real
-- users would be LOGIN roles granted membership (GRANT pathologist TO dr_x).
--
--   lab_tech          reads samples, advances wet-lab status
--   bioinformatician  reads everything in lims, writes variants and QC
--   pathologist       reads everything including audit, the only role that signs out
--   report_reader     reporting schema only, and only signed-out samples (RLS)

create role lab_tech         nologin;
create role bioinformatician nologin;
create role pathologist      nologin;
create role report_reader    nologin;

-- ---------------------------------------------------------------------------
-- Start from nothing: PUBLIC gets no access to any of our schemas or functions
-- (functions are executable by PUBLIC by default, so revoke explicitly).
-- ---------------------------------------------------------------------------
revoke all on schema lims, audit, reporting from public;
revoke all on all tables in schema lims, audit, reporting from public;
revoke all on all functions in schema lims, audit from public;

-- ---------------------------------------------------------------------------
-- Schema usage
-- report_reader deliberately gets no USAGE on lims: it cannot name any lims
-- table directly and can only reach rows through reporting views.
-- ---------------------------------------------------------------------------
grant usage on schema lims      to lab_tech, bioinformatician, pathologist;
grant usage on schema reporting to lab_tech, bioinformatician, pathologist, report_reader;
grant usage on schema audit     to lab_tech, bioinformatician, pathologist;

-- Audit trigger runs as the invoking role, so writers need INSERT (only).
-- Nobody gets UPDATE/DELETE, and a trigger blocks them for the owner too.
grant insert on audit.change_log to lab_tech, bioinformatician, pathologist;
grant select on audit.change_log to pathologist;

-- Helpers called from triggers and views
grant execute on function lims.fn_clock()                                          to lab_tech, bioinformatician, pathologist;
grant execute on function lims.fn_is_legal_transition(lims.sample_status, lims.sample_status) to lab_tech, bioinformatician, pathologist;
grant execute on function lims.fn_qc_status(integer)                               to lab_tech, bioinformatician, pathologist, report_reader;
grant execute on function lims.fn_tat_days(integer)                                to lab_tech, bioinformatician, pathologist, report_reader;

-- ---------------------------------------------------------------------------
-- lab_tech
-- ---------------------------------------------------------------------------
grant select on lims.patients, lims.tests, lims.panel_genes, lims.runs,
                lims.samples, lims.qc_metrics, lims.qc_thresholds, lims.variants
  to lab_tech;
-- Column-level: status is the only column a tech can change. The status guard
-- trigger enforces legal transitions on every path, and fn_advance_status is
-- the supported entry point.
grant update (status) on lims.samples to lab_tech;
grant execute on function lims.fn_advance_status(integer, lims.sample_status) to lab_tech;

-- ---------------------------------------------------------------------------
-- bioinformatician
-- ---------------------------------------------------------------------------
grant select on all tables in schema lims to bioinformatician;
grant insert, update, delete on lims.variants   to bioinformatician;
grant insert, update         on lims.qc_metrics to bioinformatician;
grant update (status) on lims.samples to bioinformatician;   -- marks samples 'analyzed'
grant execute on function lims.fn_advance_status(integer, lims.sample_status) to bioinformatician;
grant execute on function lims.fn_concordance(text)                          to bioinformatician;

-- ---------------------------------------------------------------------------
-- pathologist
-- ---------------------------------------------------------------------------
grant select on all tables in schema lims to pathologist;
grant update (status) on lims.samples to pathologist;
grant execute on function lims.fn_advance_status(integer, lims.sample_status) to pathologist;
grant execute on function lims.fn_concordance(text)                          to pathologist;

-- ---------------------------------------------------------------------------
-- Reporting schema
-- The views are security_invoker, so the querying role also needs SELECT on
-- the base tables. report_reader gets that SELECT but no USAGE on lims, so
-- in practice the views are its only way in, and RLS filters what it sees.
-- ---------------------------------------------------------------------------
grant select on all tables in schema reporting
  to lab_tech, bioinformatician, pathologist, report_reader;

grant select on lims.samples, lims.variants, lims.patients, lims.tests, lims.runs
  to report_reader;

-- ---------------------------------------------------------------------------
-- Row-level security
-- The table owner (the admin that builds the database) bypasses RLS.
-- ---------------------------------------------------------------------------
alter table lims.samples enable row level security;

create policy samples_staff_read on lims.samples
  for select to lab_tech, bioinformatician, pathologist
  using (true);

-- Staff may update open samples only. A signed-out row is invisible to UPDATE.
create policy samples_staff_update on lims.samples
  for update to lab_tech, bioinformatician, pathologist
  using (status <> 'signed_out')
  with check (true);

create policy samples_reader_signed_out on lims.samples
  for select to report_reader
  using (status = 'signed_out');

-- Variants inherit visibility from their sample. The subquery on lims.samples
-- is itself filtered by the samples policies above.
alter table lims.variants enable row level security;

create policy variants_staff on lims.variants
  for all to lab_tech, bioinformatician, pathologist
  using (true)
  with check (true);

create policy variants_reader on lims.variants
  for select to report_reader
  using (exists (select 1 from lims.samples s where s.sample_id = variants.sample_id));
