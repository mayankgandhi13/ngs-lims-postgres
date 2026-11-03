-- 05_views.sql
-- Reporting views use security_invoker = true (PG15+), so row-level security
-- on lims.samples applies to whoever queries the view. That is how
-- report_reader ends up seeing only signed-out samples through the same views
-- the lab staff use.

-- ---------------------------------------------------------------------------
-- Work queue: every open clinical sample, how long it has been in the lab,
-- and whether it is past its TAT target. failed is terminal (a new specimen
-- is requested), so failed samples leave the queue. Reference standards are
-- validation material and have no TAT.
-- ---------------------------------------------------------------------------
create view reporting.v_work_queue
with (security_invoker = true) as
select s.sample_id,
       s.accession,
       s.test_code,
       s.specimen,
       s.status,
       r.run_name,
       s.received_at,
       round(extract(epoch from now() - s.received_at) / 86400.0, 1)                       as days_in_lab,
       t.tat_target_days,
       round(t.tat_target_days - extract(epoch from now() - s.received_at) / 86400.0, 1)   as days_remaining,
       (now() - s.received_at) > make_interval(days => t.tat_target_days)                  as overdue
  from lims.samples s
  join lims.tests t using (test_code)
  left join lims.runs r using (run_id)
 where s.status not in ('signed_out', 'failed')
   and s.specimen <> 'reference_standard';

-- ---------------------------------------------------------------------------
-- Reportable variants: what can go on a clinical report.
-- Tier I/II, VAF >= 5%, depth >= 250x, and the sample passed QC.
-- tier IN ('I','II') matches the partial index ix_variants_reportable.
-- ---------------------------------------------------------------------------
create view reporting.v_reportable_variants
with (security_invoker = true) as
select s.accession,
       p.mrn,
       s.test_code,
       s.specimen,
       s.status,
       v.gene,
       v.hgvs_c,
       v.hgvs_p,
       v.variant_key,
       v.var_type,
       v.vaf,
       v.depth,
       v.tier,
       v.annotations ->> 'clinvar'   as clinvar,
       v.annotations ->> 'cosmic_id' as cosmic_id
  from lims.variants v
  join lims.samples s  on s.sample_id = v.sample_id
  join lims.patients p on p.patient_id = s.patient_id
  cross join lateral lims.fn_qc_status(s.sample_id) q
 where v.tier in ('I', 'II')
   and v.vaf >= 0.05
   and v.depth >= 250
   and q.qc_status = 'PASS'
   and s.specimen <> 'reference_standard';

-- ---------------------------------------------------------------------------
-- One row per sample with status, QC and TAT. Used by tests and the report.
-- ---------------------------------------------------------------------------
create view reporting.v_sample_summary
with (security_invoker = true) as
select s.sample_id,
       s.accession,
       p.mrn,
       s.test_code,
       s.specimen,
       s.status,
       r.run_name,
       s.received_at,
       s.reported_at,
       lims.fn_tat_days(s.sample_id) as tat_days,
       q.qc_status,
       q.fail_reasons
  from lims.samples s
  left join lims.patients p using (patient_id)
  left join lims.runs r using (run_id)
  cross join lateral lims.fn_qc_status(s.sample_id) q;

-- ---------------------------------------------------------------------------
-- Per-run QC snapshot. Materialized because it calls fn_qc_status for every
-- sequenced sample; refreshed after each run is loaded. The unique index on
-- run_id is what allows REFRESH MATERIALIZED VIEW CONCURRENTLY (readers are
-- not blocked during the refresh).
-- coverage_index = sample coverage / that test's median coverage, so runs
-- with a different test mix can still be compared fairly.
-- ---------------------------------------------------------------------------
create materialized view reporting.mv_run_qc as
with seq as (
  select s.run_id, s.sample_id, s.test_code, s.specimen,
         q.mean_coverage, q.q30_rate, q.dup_rate, qs.qc_status
    from lims.samples s
    join lims.qc_metrics q using (sample_id)
    cross join lateral lims.fn_qc_status(s.sample_id) qs
   where q.measured_at is not null
),
test_median as (
  select test_code, percentile_cont(0.5) within group (order by mean_coverage) as med
    from seq
   group by test_code
)
select r.run_id,
       r.run_name,
       r.instrument,
       r.run_date,
       count(*)                                                                         as n_samples,
       round(avg(seq.mean_coverage), 1)                                                 as avg_coverage,
       min(seq.mean_coverage)                                                           as min_coverage,
       round(percentile_cont(0.5) within group (order by seq.mean_coverage)::numeric, 1) as median_coverage,
       round(avg(seq.mean_coverage / tm.med::numeric), 3)                               as coverage_index,
       round(avg(seq.q30_rate), 4)                                                      as avg_q30,
       round(avg(seq.dup_rate), 4)                                                      as avg_dup,
       round(100.0 * count(*) filter (where seq.qc_status = 'FAIL') / count(*), 1)      as pct_fail
  from seq
  join lims.runs r using (run_id)
  join test_median tm using (test_code)
 group by r.run_id, r.run_name, r.instrument, r.run_date
with data;

create unique index ux_mv_run_qc_run on reporting.mv_run_qc (run_id);
