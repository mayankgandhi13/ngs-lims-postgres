-- report.sql: emits the body of report.html (header/footer are static files).
-- psql's HTML output mode escapes cell values; \echo writes the layout tags.

\set ON_ERROR_STOP on
\pset footer off
\pset null '-'

-- generated-at line (plain text mode for one row)
\pset format unaligned
\pset tuples_only on
select format('<p class="meta">Generated %s &middot; database %s &middot; PostgreSQL %s</p>',
              to_char(now(), 'YYYY-MM-DD HH24:MI TZ'), current_database(),
              current_setting('server_version'));
\pset tuples_only off
\echo '</header>'
\echo '<main>'

\pset format html
\pset border 0
\pset tableattr 'class="grid"'

\echo '<section><h2>At a glance</h2><p class="q">Volume, status and QC across the whole period.</p><div class="tbl">'
select (select count(*) from lims.patients)                                          as patients,
       (select count(*) from lims.samples where specimen <> 'reference_standard')    as clinical_samples,
       (select count(*) from lims.samples where status = 'signed_out')               as signed_out,
       (select count(*) from reporting.v_work_queue)                                 as open_in_lab,
       (select count(*) from reporting.v_work_queue where overdue)                   as overdue,
       (select count(*) from lims.samples where status = 'failed')                   as failed,
       (select count(*) from reporting.v_reportable_variants)                        as reportable_variants,
       (select count(*) from audit.change_log)                                       as audit_rows;
\echo '</div></section>'

\echo '<section><h2>Work queue: overdue by test</h2><p class="q">Which test lines are behind their TAT target right now?</p><div class="tbl">'
select test_code, count(*) as open_samples, count(*) filter (where overdue) as overdue,
       max(days_in_lab) as oldest_days, min(days_remaining) as worst_days_remaining
  from reporting.v_work_queue group by test_code order by overdue desc, test_code;
\echo '</div><p class="q" style="margin-top:12px">Overdue samples</p><div class="tbl">'
select accession, test_code, status, days_in_lab, tat_target_days as target_days, days_remaining
  from reporting.v_work_queue where overdue order by days_in_lab desc;
\echo '</div></section>'

\echo '<section><h2>Run QC vs 4-run rolling average</h2><p class="q">Is any run well below recent performance? Coverage index normalizes for test mix (1.0 is typical).</p><div class="tbl">'
with r as (
  select run_name, instrument, run_date, n_samples, avg_coverage, coverage_index, avg_q30, pct_fail,
         round(avg(coverage_index) over w, 3) as rolling4_index
    from reporting.mv_run_qc
  window w as (order by run_date rows between 4 preceding and 1 preceding)
)
select run_name, instrument, n_samples, avg_coverage, coverage_index, rolling4_index,
       round(100 * (coverage_index - rolling4_index) / rolling4_index, 1) as pct_vs_rolling,
       avg_q30, pct_fail,
       case when coverage_index < 0.7 * rolling4_index or pct_fail >= 50 then 'INVESTIGATE' else 'ok' end as flag
  from r order by run_date;
\echo '</div></section>'

\echo '<section><h2>Per-run QC outcome</h2><p class="q">Pass/fail counts and FFPE vs non-FFPE quality, computed in one pass with FILTER.</p><div class="tbl">'
select r.run_name, count(*) as sequenced,
       count(*) filter (where qs.qc_status = 'PASS') as pass,
       count(*) filter (where qs.qc_status = 'FAIL') as fail,
       count(*) filter (where qs.qc_status = 'FAIL' and s.specimen = 'FFPE') as ffpe_fail,
       round(avg(q.mean_coverage) filter (where s.specimen = 'FFPE'))  as ffpe_mean_cov,
       round(avg(q.mean_coverage) filter (where s.specimen <> 'FFPE')) as other_mean_cov,
       round(avg(q.dup_rate) filter (where s.specimen = 'FFPE'), 3)    as ffpe_dup,
       round(avg(q.dup_rate) filter (where s.specimen <> 'FFPE'), 3)   as other_dup
  from lims.samples s
  join lims.runs r using (run_id)
  join lims.qc_metrics q using (sample_id)
  cross join lateral lims.fn_qc_status(s.sample_id) qs
 where q.measured_at is not null
 group by r.run_id, r.run_name, r.run_date order by r.run_date;
\echo '</div></section>'

\echo '<section><h2>Turnaround time</h2><p class="q">Median and 90th percentile days from receipt to sign-out, per test per month.</p><div class="tbl">'
select s.test_code, to_char(date_trunc('month', s.reported_at), 'YYYY-MM') as month, count(*) as signed_out,
       round(percentile_cont(0.5) within group (order by lims.fn_tat_days(s.sample_id)::float8)::numeric, 1) as p50_days,
       round(percentile_cont(0.9) within group (order by lims.fn_tat_days(s.sample_id)::float8)::numeric, 1) as p90_days,
       t.tat_target_days as target,
       round(100.0 * count(*) filter (where lims.fn_tat_days(s.sample_id) <= t.tat_target_days) / count(*), 1) as pct_on_time
  from lims.samples s join lims.tests t using (test_code)
 where s.status = 'signed_out' and s.specimen <> 'reference_standard'
 group by s.test_code, date_trunc('month', s.reported_at), t.tat_target_days
 order by s.test_code, month;
\echo '</div></section>'

\echo '<section><h2>Recurrent hotspots</h2><p class="q">Top 5 Tier I/II variants per test by number of patients.</p><div class="tbl">'
with counts as (
  select s.test_code, v.gene, v.hgvs_p, v.variant_key,
         count(distinct s.patient_id) as patients, count(*) as calls
    from lims.variants v join lims.samples s using (sample_id)
   where v.tier in ('I', 'II') and s.specimen <> 'reference_standard'
   group by 1, 2, 3, 4
), ranked as (
  select counts.*, rank() over (partition by test_code order by patients desc) as rnk from counts
)
select test_code, rnk as rank, gene, hgvs_p, variant_key, patients, calls
  from ranked where rnk <= 5 order by test_code, rnk, gene;
\echo '</div></section>'

\echo '<section><h2>Co-occurring mutations</h2><p class="q">Tier I/II gene pairs found in the same sample.</p><div class="tbl">'
select a.gene || ' + ' || b.gene as gene_pair, count(distinct a.sample_id) as samples,
       count(distinct s.patient_id) as patients
  from lims.variants a
  join lims.variants b on b.sample_id = a.sample_id and a.gene < b.gene
  join lims.samples s on s.sample_id = a.sample_id
 where a.tier in ('I', 'II') and b.tier in ('I', 'II') and s.specimen <> 'reference_standard'
 group by a.gene, b.gene order by samples desc, gene_pair limit 10;
\echo '</div></section>'

\echo '<section><h2>Serial monitoring</h2><p class="q">VAF change between consecutive samples for patients whose tracked variant rose or cleared.</p><div class="tbl">'
with done as (
  select s.* from lims.samples s
   where s.status in ('analyzed', 'signed_out') and s.specimen <> 'reference_standard'
), serial as (
  select patient_id from done group by patient_id having count(*) >= 2
), tracked as (
  select distinct d.patient_id, v.gene, v.hgvs_p, v.variant_key
    from lims.variants v join done d using (sample_id) join serial using (patient_id)
   where v.tier in ('I', 'II')
), timeline as (
  select t.*, d.accession, d.received_at, coalesce(v.vaf, 0) as vaf
    from tracked t
    join done d on d.patient_id = t.patient_id
    left join lims.variants v on v.sample_id = d.sample_id and v.variant_key = t.variant_key
), lagged as (
  select tl.*, lag(tl.vaf) over (partition by tl.patient_id, tl.variant_key order by tl.received_at) as prev_vaf
    from timeline tl
), labeled as (
  select l.*, case when prev_vaf is null then 'baseline'
                   when vaf = 0 then 'not detected'
                   when vaf < 0.5 * prev_vaf then 'falling'
                   when vaf > 1.5 * prev_vaf then 'RISING'
                   else 'stable' end as trend
    from lagged l
), interesting as (
  select distinct patient_id, variant_key from labeled where trend in ('RISING', 'not detected')
)
select p.mrn, l.gene, l.hgvs_p, l.accession, l.received_at::date as collected, l.vaf, l.prev_vaf,
       round(l.vaf - l.prev_vaf, 4) as delta, l.trend
  from labeled l
  join interesting i using (patient_id, variant_key)
  join lims.patients p using (patient_id)
 order by p.mrn, l.gene, l.received_at;
\echo '</div></section>'

\echo '<section><h2>Assay validation (REFSTD-A, 3 replicates)</h2><p class="q">Concordance with the truth set (FULL OUTER JOIN), then detection by expected VAF bin.</p><div class="tbl">'
select * from lims.fn_concordance('ONCO-DNA');
\echo '</div><p class="q" style="margin-top:12px">Limit of detection</p><div class="tbl">'
with reps as (
  select sample_id, reference_material from lims.samples
   where specimen = 'reference_standard' and test_code = 'ONCO-DNA'
), expected as (
  select r.sample_id, t.variant_key, t.expected_vaf,
         width_bucket(t.expected_vaf, array[0.01, 0.025, 0.05, 0.10, 0.20]::numeric[]) as bin
    from reps r join lims.truth_variants t on t.material = r.reference_material and t.test_code = 'ONCO-DNA'
)
select (array['1-2.5%', '2.5-5%', '5-10%', '10-20%', '20-40%'])[bin] as expected_vaf_bin,
       count(*) as expected_calls, count(v.variant_id) as detected,
       round(100.0 * count(v.variant_id) / count(*), 1) as detection_pct,
       round(avg(e.expected_vaf), 4) as mean_expected_vaf, round(avg(v.vaf), 4) as mean_observed_vaf
  from expected e
  left join lims.variants v on v.sample_id = e.sample_id and v.variant_key = e.variant_key
 group by bin order by bin;
\echo '</div></section>'

\echo '<section><h2>ClinVar Pathogenic Tier I/II calls</h2><p class="q">JSONB containment query on annotations (GIN indexed).</p><div class="tbl">'
select v.gene, v.hgvs_p, v.annotations ->> 'cosmic_id' as cosmic_id,
       v.annotations ->> 'oncokb_level' as oncokb_level,
       count(*) as calls, count(distinct s.patient_id) as patients
  from lims.variants v join lims.samples s using (sample_id)
 where v.tier in ('I', 'II') and v.annotations @> '{"clinvar": "Pathogenic"}'
 group by 1, 2, 3, 4 order by calls desc;
\echo '</div></section>'

select s.sample_id as demo_sample_id, s.accession as demo_accession
  from lims.samples s
 where s.status = 'signed_out' and s.patient_id is not null
 order by s.sample_id limit 1 \gset
\echo '<section><h2>Status history:' :demo_accession '</h2><p class="q">Rebuilt from audit.change_log with a recursive CTE.</p><div class="tbl">'
with recursive changes as (
  select log_id, op, changed_at, changed_by,
         old_row ->> 'status' as from_status, new_row ->> 'status' as to_status
    from audit.change_log
   where table_name = 'lims.samples' and row_pk = :'demo_sample_id'
     and (op = 'INSERT' or old_row ->> 'status' is distinct from new_row ->> 'status')
), history as (
  select 1 as step, log_id, changed_at, changed_by, from_status, to_status from changes where op = 'INSERT'
  union all
  select h.step + 1, c.log_id, c.changed_at, c.changed_by, c.from_status, c.to_status
    from history h join changes c on c.from_status = h.to_status and c.log_id > h.log_id
)
select step, coalesce(from_status, '(accessioned)') as from_status, to_status,
       to_char(changed_at, 'YYYY-MM-DD HH24:MI') as changed_at, changed_by,
       round(extract(epoch from changed_at - lag(changed_at) over (order by step)) / 3600, 1) as hours_in_prev_status
  from history order by step;
\echo '</div></section>'
