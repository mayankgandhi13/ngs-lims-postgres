-- 08_analysis.sql
-- Questions a lab director, QA lead or bioinformatician asks every week.
-- Read-only. Run with: make analysis

\pset footer on
\pset null '-'

-- ===========================================================================
-- Q1. Work queue: which samples are overdue right now, and which test line is behind?
-- ===========================================================================
\echo '\n== Q1a. Open samples and overdue count by test =='
select test_code,
       count(*)                                  as open_samples,
       count(*) filter (where overdue)           as overdue,
       max(days_in_lab)                          as oldest_days,
       min(days_remaining)                       as worst_days_remaining
  from reporting.v_work_queue
 group by test_code
 order by overdue desc, test_code;

\echo '\n== Q1b. Overdue samples, oldest first =='
select accession, test_code, status, days_in_lab, tat_target_days, days_remaining
  from reporting.v_work_queue
 where overdue
 order by days_in_lab desc;

-- ===========================================================================
-- Q2. Bad run detection: is any run's coverage well below the recent trend?
-- Compares each run with the rolling average of the 4 runs before it.
-- coverage_index normalizes for test mix (1.0 = typical for that test).
-- ===========================================================================
\echo '\n== Q2. Runs vs 4-run rolling average coverage =='
with r as (
  select run_name, instrument, run_date, n_samples, avg_coverage, coverage_index, avg_q30, pct_fail,
         round(avg(coverage_index) over w, 3) as rolling4_index,
         round(avg(avg_coverage)   over w, 1) as rolling4_coverage
    from reporting.mv_run_qc
  window w as (order by run_date rows between 4 preceding and 1 preceding)
)
select run_name, instrument, n_samples, avg_coverage, rolling4_coverage,
       coverage_index, rolling4_index,
       round(100 * (coverage_index - rolling4_index) / rolling4_index, 1) as pct_vs_rolling,
       avg_q30, pct_fail,
       case when coverage_index < 0.7 * rolling4_index or pct_fail >= 50 then 'INVESTIGATE' else 'ok' end as flag
  from r
 order by run_date;

-- ===========================================================================
-- Q3. TAT: are we meeting the target? Median and 90th percentile per test per month.
-- ===========================================================================
\echo '\n== Q3. TAT percentiles by test and month (signed-out samples) =='
select s.test_code,
       to_char(date_trunc('month', s.reported_at), 'YYYY-MM')                                           as month,
       count(*)                                                                                      as signed_out,
       round(percentile_cont(0.5) within group (order by lims.fn_tat_days(s.sample_id)::float8)::numeric, 1) as p50_days,
       round(percentile_cont(0.9) within group (order by lims.fn_tat_days(s.sample_id)::float8)::numeric, 1) as p90_days,
       t.tat_target_days                                                                             as target,
       round(100.0 * count(*) filter (where lims.fn_tat_days(s.sample_id) <= t.tat_target_days) / count(*), 1) as pct_on_time
  from lims.samples s
  join lims.tests t using (test_code)
 where s.status = 'signed_out'
   and s.specimen <> 'reference_standard'
 group by s.test_code, date_trunc('month', s.reported_at), t.tat_target_days
 order by s.test_code, month;

-- ===========================================================================
-- Q4. Recurrent hotspots: top 5 Tier I/II variants per test, by number of patients.
-- RANK() so ties share a rank.
-- ===========================================================================
\echo '\n== Q4. Top recurrent hotspots per test =='
with counts as (
  select s.test_code, v.gene, v.hgvs_p, v.variant_key,
         count(distinct s.patient_id) as patients,
         count(*)                     as calls
    from lims.variants v
    join lims.samples s using (sample_id)
   where v.tier in ('I', 'II')
     and s.specimen <> 'reference_standard'
   group by s.test_code, v.gene, v.hgvs_p, v.variant_key
), ranked as (
  select counts.*, rank() over (partition by test_code order by patients desc) as rnk
    from counts
)
select test_code, rnk, gene, hgvs_p, variant_key, patients, calls
  from ranked
 where rnk <= 5
 order by test_code, rnk, gene;

-- ===========================================================================
-- Q5. Co-occurring mutations: which Tier I/II genes show up together in one sample?
-- Self-join on sample_id, a.gene < b.gene so each pair counts once.
-- ===========================================================================
\echo '\n== Q5a. Most common co-occurring gene pairs =='
select a.gene || ' + ' || b.gene        as gene_pair,
       count(distinct a.sample_id)      as samples,
       count(distinct s.patient_id)     as patients
  from lims.variants a
  join lims.variants b on b.sample_id = a.sample_id and a.gene < b.gene
  join lims.samples s  on s.sample_id = a.sample_id
 where a.tier in ('I', 'II') and b.tier in ('I', 'II')
   and s.specimen <> 'reference_standard'
 group by a.gene, b.gene
 order by samples desc, gene_pair
 limit 10;

\echo '\n== Q5b. Co-occurring vs mutually exclusive pairs (KRAS+TP53 common, KRAS+BRAF never) =='
select p.g1 || ' + ' || p.g2 as gene_pair,
       (select count(distinct a.sample_id)
          from lims.variants a
          join lims.variants b on b.sample_id = a.sample_id
          join lims.samples s  on s.sample_id = a.sample_id
         where a.gene = p.g1 and b.gene = p.g2
           and a.tier in ('I', 'II') and b.tier in ('I', 'II')
           and s.specimen <> 'reference_standard') as samples_with_both
  from (values ('KRAS', 'TP53'), ('PIK3CA', 'TP53'), ('BRAF', 'KRAS'), ('EGFR', 'KRAS'), ('BRAF', 'EGFR')) p(g1, g2)
 order by samples_with_both desc, gene_pair;

-- ===========================================================================
-- Q6. Serial monitoring: how is each tracked variant's VAF changing over time?
-- Every driver seen in a patient is followed across all their analyzed
-- samples; a timepoint without the call counts as VAF 0 (not detected).
-- ===========================================================================
\echo '\n== Q6. Serial VAF change per patient per variant (LAG) =='
with done as (
  select s.* from lims.samples s
   where s.status in ('analyzed', 'signed_out') and s.specimen <> 'reference_standard'
), serial as (
  select patient_id from done group by patient_id having count(*) >= 2
), tracked as (
  select distinct d.patient_id, v.gene, v.hgvs_p, v.variant_key
    from lims.variants v
    join done d using (sample_id)
    join serial using (patient_id)
   where v.tier in ('I', 'II')
), timeline as (
  select t.patient_id, t.gene, t.hgvs_p, t.variant_key, d.accession, d.received_at,
         coalesce(v.vaf, 0) as vaf
    from tracked t
    join done d on d.patient_id = t.patient_id
    left join lims.variants v on v.sample_id = d.sample_id and v.variant_key = t.variant_key
)
select p.mrn, tl.gene, tl.hgvs_p, tl.accession, tl.received_at::date as collected,
       tl.vaf,
       lag(tl.vaf) over w                         as prev_vaf,
       round(tl.vaf - lag(tl.vaf) over w, 4)      as delta,
       case when lag(tl.vaf) over w is null           then 'baseline'
            when tl.vaf = 0                           then 'not detected'
            when tl.vaf < 0.5 * lag(tl.vaf) over w    then 'falling'
            when tl.vaf > 1.5 * lag(tl.vaf) over w    then 'RISING'
            else 'stable' end                     as trend
  from timeline tl
  join lims.patients p using (patient_id)
window w as (partition by tl.patient_id, tl.variant_key order by tl.received_at)
 order by p.mrn, tl.gene, tl.received_at;

-- ===========================================================================
-- Q7. Validation: does the assay meet sensitivity/PPV, and where is the LOD?
-- ===========================================================================
\echo '\n== Q7a. Concordance vs REFSTD-A truth set =='
select * from lims.fn_concordance('ONCO-DNA');

\echo '\n== Q7b. Detection rate by expected VAF bin (width_bucket) =='
with reps as (
  select sample_id, reference_material from lims.samples
   where specimen = 'reference_standard' and test_code = 'ONCO-DNA'
), expected as (
  select r.sample_id, t.variant_key, t.expected_vaf,
         width_bucket(t.expected_vaf, array[0.01, 0.025, 0.05, 0.10, 0.20]::numeric[]) as bin
    from reps r
    join lims.truth_variants t on t.material = r.reference_material and t.test_code = 'ONCO-DNA'
)
select bin,
       (array['1-2.5%', '2.5-5%', '5-10%', '10-20%', '20-40%'])[bin]               as expected_vaf_bin,
       count(*)                                                                     as expected_calls,
       count(v.variant_id)                                                          as detected,
       round(100.0 * count(v.variant_id) / count(*), 1)                             as detection_pct,
       round(avg(e.expected_vaf), 4)                                                as mean_expected_vaf,
       round(avg(v.vaf), 4)                                                         as mean_observed_vaf
  from expected e
  left join lims.variants v on v.sample_id = e.sample_id and v.variant_key = e.variant_key
 group by bin
 order by bin;

-- ===========================================================================
-- Q8. JSONB: which Tier I/II calls are ClinVar Pathogenic?
-- Containment (@>) is the GIN-indexable form of annotations->>'clinvar' = 'Pathogenic'.
-- ===========================================================================
\echo '\n== Q8a. Tier I/II calls with ClinVar = Pathogenic =='
select v.gene, v.hgvs_p, v.annotations ->> 'cosmic_id' as cosmic_id,
       v.annotations ->> 'oncokb_level'                as oncokb_level,
       count(*)                                        as calls,
       count(distinct s.patient_id)                    as patients
  from lims.variants v
  join lims.samples s using (sample_id)
 where v.tier in ('I', 'II')
   and v.annotations @> '{"clinvar": "Pathogenic"}'
 group by 1, 2, 3, 4
 order by calls desc;

\echo '\n== Q8b. Same filter with ->> (same rows, cannot use the GIN index), and Tier I/II calls with no ClinVar key at all =='
select count(*) filter (where annotations ->> 'clinvar' = 'Pathogenic')  as pathogenic_via_arrow,
       count(*) filter (where annotations @> '{"clinvar": "Pathogenic"}') as pathogenic_via_containment,
       count(*) filter (where not annotations ? 'clinvar')               as no_clinvar_key
  from lims.variants
 where tier in ('I', 'II');

-- ===========================================================================
-- Q9. Recursive CTE: reconstruct one sample's full status history from the audit log.
-- Starts at the INSERT row, then repeatedly follows "the next change whose
-- old status equals my new status".
-- ===========================================================================
select s.sample_id as demo_sample_id, s.accession as demo_accession
  from lims.samples s
 where s.status = 'signed_out' and s.patient_id is not null
 order by s.sample_id
 limit 1 \gset
\echo '\n== Q9. Status history for' :demo_accession '=='
with recursive changes as (
  select log_id, op, changed_at, changed_by,
         old_row ->> 'status' as from_status,
         new_row ->> 'status' as to_status
    from audit.change_log
   where table_name = 'lims.samples'
     and row_pk = :'demo_sample_id'
     and (op = 'INSERT' or old_row ->> 'status' is distinct from new_row ->> 'status')
), history as (
  select 1 as step, log_id, changed_at, changed_by, from_status, to_status
    from changes
   where op = 'INSERT'
  union all
  select h.step + 1, c.log_id, c.changed_at, c.changed_by, c.from_status, c.to_status
    from history h
    join changes c on c.from_status = h.to_status and c.log_id > h.log_id
)
select step,
       coalesce(from_status, '(accessioned)')                                              as from_status,
       to_status,
       changed_at,
       changed_by,
       round(extract(epoch from changed_at - lag(changed_at) over (order by step)) / 3600, 1) as hours_in_prev_status
  from history
 order by step;

-- ===========================================================================
-- Q10. FILTER aggregation: per-run QC pass/fail and FFPE breakdown in one pass.
-- ===========================================================================
\echo '\n== Q10. Per-run QC outcome counts =='
select r.run_name,
       r.instrument,
       count(*)                                                                  as sequenced,
       count(*) filter (where qs.qc_status = 'PASS')                             as pass,
       count(*) filter (where qs.qc_status = 'FAIL')                             as fail,
       count(*) filter (where qs.qc_status = 'FAIL' and s.specimen = 'FFPE')     as ffpe_fail,
       round(avg(q.mean_coverage) filter (where s.specimen = 'FFPE'))            as ffpe_mean_cov,
       round(avg(q.mean_coverage) filter (where s.specimen <> 'FFPE'))           as non_ffpe_mean_cov,
       round(avg(q.dup_rate) filter (where s.specimen = 'FFPE'), 3)              as ffpe_dup,
       round(avg(q.dup_rate) filter (where s.specimen <> 'FFPE'), 3)             as non_ffpe_dup
  from lims.samples s
  join lims.runs r using (run_id)
  join lims.qc_metrics q using (sample_id)
  cross join lateral lims.fn_qc_status(s.sample_id) qs
 where q.measured_at is not null
 group by r.run_id, r.run_name, r.instrument, r.run_date
 order by r.run_date;

-- ===========================================================================
-- Q11. Does the reportable-variants view use the partial index?
-- Look for "ix_variants_reportable" in the plan. Tier I/II is about 2% of
-- calls, so the planner scans the small partial index instead of the table.
-- ===========================================================================
\echo '\n== Q11. EXPLAIN ANALYZE of reporting.v_reportable_variants =='
explain (analyze, buffers, costs off, timing off)
select * from reporting.v_reportable_variants;
