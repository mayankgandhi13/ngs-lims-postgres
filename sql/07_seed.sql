-- 07_seed.sql
-- Generates ALL data in SQL. No CSVs, no external scripts.
-- setseed(0.42) makes random() reproducible for this session, so every
-- `make reset` produces the same patients, runs, QC values and calls.
--
-- The lab is replayed as of :anchor. Each sample's events (extraction,
-- library prep, sequencing, analysis, sign-out) are scheduled in time and
-- applied through lims.fn_advance_status(), with lims.clock set to the
-- event time, so the audit log reads like six months of real activity.
--
-- Hotspot coordinates named in the project brief are GRCh38. Other positions
-- (truth set extras, fusion breakpoints, background variants) are
-- illustrative and only need to fall inside the panel gene spans.

\set anchor '2026-11-01 18:00:00+00'

set timezone = 'UTC';
do $$ begin perform setseed(0.42); end $$;

-- ---------------------------------------------------------------------------
-- Tests, panels, QC thresholds
-- ---------------------------------------------------------------------------
insert into lims.tests (test_code, test_name, analyte, tat_target_days) values
  ('ONCO-DNA',   'Solid tumor DNA hotspot panel',  'DNA', 10),
  ('HEME-DNA',   'Myeloid neoplasm DNA panel',     'DNA', 14),
  ('FUSION-RNA', 'Solid tumor fusion RNA panel',   'RNA', 12);

insert into lims.panel_genes (test_code, gene, chrom, start_pos, end_pos, transcript) values
  ('ONCO-DNA', 'KRAS',   'chr12',  25205246,  25250929, 'NM_004985.5'),
  ('ONCO-DNA', 'NRAS',   'chr1',  114704469, 114716771, 'NM_002524.5'),
  ('ONCO-DNA', 'BRAF',   'chr7',  140719327, 140924929, 'NM_004333.6'),
  ('ONCO-DNA', 'EGFR',   'chr7',   55019017,  55211628, 'NM_005228.5'),
  ('ONCO-DNA', 'PIK3CA', 'chr3',  179148114, 179240093, 'NM_006218.4'),
  ('ONCO-DNA', 'TP53',   'chr17',   7661779,   7687538, 'NM_000546.6'),
  ('ONCO-DNA', 'KIT',    'chr4',   54657918,  54740715, 'NM_000222.3'),
  ('ONCO-DNA', 'PTEN',   'chr10',  87863113,  87971930, 'NM_000314.8'),
  ('ONCO-DNA', 'APC',    'chr5',  112707498, 112846239, 'NM_000038.6'),
  ('ONCO-DNA', 'ERBB2',  'chr17',  39687914,  39730426, 'NM_004448.4'),
  ('HEME-DNA', 'JAK2',   'chr9',    4985033,   5128183, 'NM_004972.4'),
  ('HEME-DNA', 'CALR',   'chr19',  12938578,  12944489, 'NM_004343.4'),
  ('HEME-DNA', 'MPL',    'chr1',   43337818,  43354466, 'NM_005373.3'),
  ('HEME-DNA', 'DNMT3A', 'chr2',   25227855,  25342590, 'NM_022552.5'),
  ('HEME-DNA', 'IDH1',   'chr2',  208236227, 208266074, 'NM_005896.4'),
  ('HEME-DNA', 'IDH2',   'chr15',  90083045,  90102477, 'NM_002168.4'),
  ('HEME-DNA', 'NPM1',   'chr5',  171387116, 171411810, 'NM_002520.7'),
  ('HEME-DNA', 'FLT3',   'chr13',  28003274,  28100592, 'NM_004119.3'),
  ('HEME-DNA', 'TET2',   'chr4',  105145875, 105279816, 'NM_001127208.3'),
  ('HEME-DNA', 'ASXL1',  'chr20',  32358062,  32439369, 'NM_015338.6'),
  ('HEME-DNA', 'RUNX1',  'chr21',  34787801,  36004667, 'NM_001754.5'),
  ('HEME-DNA', 'TP53',   'chr17',   7661779,   7687538, 'NM_000546.6'),
  ('FUSION-RNA', 'ALK',   'chr2',   29192774,  29921586, null),
  ('FUSION-RNA', 'RET',   'chr10',  43077069,  43130349, null),
  ('FUSION-RNA', 'ROS1',  'chr6',  117288300, 117425855, null),
  ('FUSION-RNA', 'NTRK1', 'chr1',  156815640, 156881850, null),
  ('FUSION-RNA', 'NTRK3', 'chr15',  87859751,  88256768, null),
  ('FUSION-RNA', 'FGFR3', 'chr4',    1793293,   1808872, null),
  ('FUSION-RNA', 'MET',   'chr7',  116672196, 116798377, null);

insert into lims.qc_thresholds (test_code, metric, min_value, max_value) values
  ('ONCO-DNA',   'total_reads',      5000000, null),
  ('ONCO-DNA',   'mean_coverage',        500, null),
  ('ONCO-DNA',   'pct_target_250x',     0.90, null),
  ('ONCO-DNA',   'dup_rate',            null, 0.50),
  ('ONCO-DNA',   'q30_rate',            0.85, null),
  ('HEME-DNA',   'total_reads',      6000000, null),
  ('HEME-DNA',   'mean_coverage',        800, null),
  ('HEME-DNA',   'pct_target_250x',     0.93, null),
  ('HEME-DNA',   'dup_rate',            null, 0.45),
  ('HEME-DNA',   'q30_rate',            0.85, null),
  ('FUSION-RNA', 'total_reads',      3000000, null),
  ('FUSION-RNA', 'mean_coverage',        150, null),
  ('FUSION-RNA', 'dup_rate',            null, 0.70),
  ('FUSION-RNA', 'q30_rate',            0.80, null);

-- ---------------------------------------------------------------------------
-- Validation truth set: reference material REFSTD-A on ONCO-DNA.
-- 20 variants, expected VAF 1% to 35%. Four sit below 5% to probe the LOD.
-- ---------------------------------------------------------------------------
insert into lims.truth_variants (test_code, material, gene, chrom, pos, ref, alt, var_type, hgvs_p, expected_vaf) values
  ('ONCO-DNA', 'REFSTD-A', 'TP53',   'chr17',   7673802, 'C', 'T', 'SNV', 'p.R273H',        0.350),
  ('ONCO-DNA', 'REFSTD-A', 'TP53',   'chr17',   7675088, 'C', 'T', 'SNV', 'p.R175H',        0.250),
  ('ONCO-DNA', 'REFSTD-A', 'KRAS',   'chr12',  25245350, 'C', 'T', 'SNV', 'p.G12D',         0.200),
  ('ONCO-DNA', 'REFSTD-A', 'PIK3CA', 'chr3',  179234297, 'A', 'G', 'SNV', 'p.H1047R',       0.175),
  ('ONCO-DNA', 'REFSTD-A', 'KRAS',   'chr12',  25245347, 'C', 'T', 'SNV', 'p.G13D',         0.150),
  ('ONCO-DNA', 'REFSTD-A', 'NRAS',   'chr1',  114713909, 'G', 'T', 'SNV', 'p.Q61K',         0.125),
  ('ONCO-DNA', 'REFSTD-A', 'BRAF',   'chr7',  140753336, 'A', 'T', 'SNV', 'p.V600E',        0.100),
  ('ONCO-DNA', 'REFSTD-A', 'KIT',    'chr4',   54733155, 'A', 'T', 'SNV', 'p.D816V',        0.100),
  ('ONCO-DNA', 'REFSTD-A', 'PIK3CA', 'chr3',  179218303, 'G', 'A', 'SNV', 'p.E545K',        0.090),
  ('ONCO-DNA', 'REFSTD-A', 'EGFR',   'chr7',   55174771, 'AGGAATTAAGAGAAGC', 'A', 'DEL', 'p.E746_A750del', 0.080),
  ('ONCO-DNA', 'REFSTD-A', 'APC',    'chr5',  112839942, 'C', 'T', 'SNV', 'p.R1450*',       0.075),
  ('ONCO-DNA', 'REFSTD-A', 'ERBB2',  'chr17',  39724734, 'G', 'GTATGTGATGGC', 'INS', 'p.A775_G776insYVMA', 0.060),
  ('ONCO-DNA', 'REFSTD-A', 'PTEN',   'chr10',  87933147, 'C', 'T', 'SNV', 'p.R130*',        0.060),
  ('ONCO-DNA', 'REFSTD-A', 'KRAS',   'chr12',  25227341, 'T', 'G', 'SNV', 'p.Q61H',         0.055),
  ('ONCO-DNA', 'REFSTD-A', 'EGFR',   'chr7',   55174014, 'G', 'A', 'SNV', 'p.G719S',        0.050),
  ('ONCO-DNA', 'REFSTD-A', 'APC',    'chr5',  112838934, 'AT', 'A', 'DEL', 'p.I1307fs',     0.050),
  ('ONCO-DNA', 'REFSTD-A', 'EGFR',   'chr7',   55181378, 'C', 'T', 'SNV', 'p.T790M',        0.040),
  ('ONCO-DNA', 'REFSTD-A', 'PIK3CA', 'chr3',  179218294, 'G', 'A', 'SNV', 'p.E542K',        0.030),
  ('ONCO-DNA', 'REFSTD-A', 'EGFR',   'chr7',   55191822, 'T', 'G', 'SNV', 'p.L858R',        0.020),
  ('ONCO-DNA', 'REFSTD-A', 'NRAS',   'chr1',  114716126, 'C', 'T', 'SNV', 'p.G12D',         0.010);

-- ---------------------------------------------------------------------------
-- Runs: 30 weekly runs from 2026-04-06, alternating instruments.
-- Run index 23 (2026-09-14, NextSeq 2000) is the deliberately degraded run.
-- ---------------------------------------------------------------------------
insert into lims.runs (run_name, instrument, flowcell_id, run_date, notes)
select format('RUN-%s-%s', to_char(d, 'YYYYMMDD'), case when k % 2 = 0 then 'NVX' else 'NS2K' end),
       case when k % 2 = 0 then 'NovaSeq X' else 'NextSeq 2000' end,
       case when k % 2 = 0 then '22' || upper(substr(md5('fc' || k), 1, 7)) || 'LT3'
            else 'AAH' || upper(substr(md5('fc' || k), 1, 6)) end,
       d,
       case when k = 23 then 'Reagent cartridge lot issue: low cluster PF, low Q30' end
  from generate_series(0, 29) k
  cross join lateral (select date '2026-04-06' + 7 * k as d) x
 order by k;

-- ---------------------------------------------------------------------------
-- Patients
-- ---------------------------------------------------------------------------
insert into lims.patients (mrn, sex, birth_year)
select format('SYN%s', lpad((100000 + i * 37)::text, 6, '0')),
       (array['F', 'M'])[1 + floor(random() * 2)::int],
       1935 + floor(random() * 70)::int
  from generate_series(1, 200) i;

-- ---------------------------------------------------------------------------
-- Sample plan. Each patient has one test. HEME patients are often monitored
-- serially (2 to 4 samples), ONCO occasionally (2 to 3), FUSION never.
-- ---------------------------------------------------------------------------
create temp table seed_plan as
with pat as materialized (
  select patient_id, random() as r_test, random() as r_serial, random() as r_n,
         random() as r_first, random() as r_gap
    from lims.patients
   order by patient_id
), p as (
  select pat.*,
         case when r_test < 0.45 then 'ONCO-DNA' when r_test < 0.80 then 'HEME-DNA' else 'FUSION-RNA' end as test_code
    from pat
)
select patient_id, test_code, n_samples, gap,
       floor(r_first * (30 - (n_samples - 1) * gap))::int as first_run
  from (
    select p.*,
           case when test_code = 'HEME-DNA' and r_serial < 0.50 then 2 + floor(r_n * 3)::int
                when test_code = 'ONCO-DNA' and r_serial < 0.15 then 2 + floor(r_n * 2)::int
                else 1 end as n_samples,
           3 + floor(r_gap * 4)::int as gap
      from p
  ) x;

create temp table seed_samples as
with base as materialized (
  select p.patient_id, p.test_code, g.seq_no,
         p.first_run + (g.seq_no - 1) * p.gap as run_idx,
         random() as r_spec, random() as r_purity, random() as r_recv
    from seed_plan p
    cross join lateral generate_series(1, p.n_samples) g(seq_no)
   order by p.patient_id, g.seq_no
)
select b.patient_id, b.test_code, r.run_id,
       case when b.test_code = 'HEME-DNA'
            then case when b.r_spec < 0.55 then 'blood' else 'bone_marrow' end
            else 'FFPE' end::lims.specimen_type                             as specimen,
       case when b.test_code <> 'HEME-DNA'
            then round((0.20 + b.r_purity * 0.70)::numeric * 20) / 20 end    as tumor_purity,
       date_trunc('minute', (r.run_date + time '10:00') at time zone 'UTC'
                            - make_interval(secs => (2.5 + b.r_recv * 2.5) * 86400)) as received_at,
       null::text                                                           as reference_material
  from base b
  join lims.runs r on r.run_date = date '2026-04-06' + 7 * b.run_idx;

-- Twelve new samples received this week and not yet batched onto a run.
insert into seed_samples
select p.patient_id, p.test_code, null,
       case when p.test_code = 'HEME-DNA' then 'bone_marrow' else 'FFPE' end::lims.specimen_type,
       case when p.test_code = 'ONCO-DNA' then 0.40 end,
       date_trunc('minute', timestamptz '2026-10-27 08:00+00' + make_interval(secs => random() * 5.35 * 86400)),
       null
  from (select * from seed_plan
         where n_samples = 1 and test_code <> 'FUSION-RNA'
         order by patient_id offset 10 limit 12) p;

-- Three validation replicates of REFSTD-A on three different runs (inter-run).
insert into seed_samples
select null, 'ONCO-DNA', r.run_id, 'reference_standard', null,
       (r.run_date + time '09:00') at time zone 'UTC' - interval '3 days', 'REFSTD-A'
  from lims.runs r
 where r.run_date in (date '2026-04-13', date '2026-04-20', date '2026-04-27')
 order by r.run_date;

-- Accession in time order; the audit INSERT row is stamped at receipt time.
do $$
declare
  rec    record;
  n_clin integer := 0;
  n_val  integer := 0;
  v_acc  text;
begin
  for rec in select * from seed_samples order by received_at, patient_id nulls first loop
    perform set_config('lims.clock', rec.received_at::text, true);
    if rec.specimen = 'reference_standard' then
      n_val := n_val + 1;
      v_acc := format('VAL26-%s', lpad(n_val::text, 4, '0'));
    else
      n_clin := n_clin + 1;
      v_acc := format('NGS26-%s', lpad(n_clin::text, 5, '0'));
    end if;
    insert into lims.samples (accession, patient_id, test_code, run_id, specimen,
                              reference_material, tumor_purity, received_at)
    values (v_acc, rec.patient_id, rec.test_code, rec.run_id, rec.specimen,
            rec.reference_material, rec.tumor_purity, rec.received_at);
  end loop;
  perform set_config('lims.clock', '', true);
end $$;

-- ---------------------------------------------------------------------------
-- Timeline: planned time of every step for every sample.
-- ---------------------------------------------------------------------------
create temp table seed_timeline as
with base as materialized (
  select s.sample_id, s.test_code, s.specimen, s.received_at, s.run_id, r.run_date, r.instrument,
         random() as r_ext, random() as r_seq, random() as r_ana, random() as r_sign,
         random() as r_delay, random() as r_delay_len, random() as r_xfail, random() as r_qcstop
    from lims.samples s
    left join lims.runs r using (run_id)
   order by s.sample_id
), t1 as (
  select b.*,
         -- batched samples are extracted within hours; unbatched ones wait for the
         -- next Monday or Thursday 09:00 extraction batch
         case when b.run_id is not null
              then b.received_at + make_interval(secs => (4 + b.r_ext * 8) * 3600)
              else (select min(d + interval '9 hours') at time zone 'UTC'
                      from generate_series(b.received_at::date::timestamp, b.received_at::date + 7, interval '1 day') d
                     where extract(isodow from d) in (1, 4)
                       and (d + interval '9 hours') at time zone 'UTC' > b.received_at) end      as t_ext,
         (b.run_date - 1 + time '08:00') at time zone 'UTC'                                   as t_lib,
         (b.run_date + time '10:00') at time zone 'UTC'
           + make_interval(secs => ((case when b.instrument = 'NovaSeq X' then 29 else 24 end)
                                    + b.r_seq * 3) * 3600)                                    as t_seq,
         b.specimen <> 'reference_standard'
           and b.r_xfail < case when b.specimen = 'FFPE' then 0.04 else 0.01 end              as extract_fail
    from base b
), t2 as (
  select t1.*,
         t1.t_seq + make_interval(secs => (case t1.test_code
                                              when 'HEME-DNA' then 48 + t1.r_ana * 72
                                              when 'ONCO-DNA' then 24 + t1.r_ana * 48
                                              else 36 + t1.r_ana * 48 end) * 3600)            as t_ana
    from t1
)
select t2.*,
       t2.t_ana + make_interval(secs => (6 + t2.r_sign * 54) * 3600)
                + case when t2.r_delay < 0.03                       -- stuck: send-out confirmation, lost block
                       then make_interval(days => 45 + floor(t2.r_delay_len * 75)::int)
                       when t2.r_delay < 0.15                       -- pathologist backlog / extra IHC
                       then make_interval(days => 4 + floor(t2.r_delay_len * 26)::int)
                       else interval '0' end                                                  as t_sign
  from t2;

-- ---------------------------------------------------------------------------
-- QC metrics for every sample whose run has finished.
--   FFPE: lower coverage (capture efficiency 0.85), higher duplication, short inserts
--   Degraded run: 35% of normal yield, +15% duplication, Q30 0.72 to 0.82
-- ---------------------------------------------------------------------------
with base as materialized (
  select t.sample_id, t.test_code, t.specimen, t.t_seq, r.instrument,
         (r.run_date = date '2026-09-14') as degraded,
         random() as r_reads, random() as r_dup, random() as r_q30, random() as r_ins, random() as r_250
    from seed_timeline t
    join lims.runs r using (run_id)
   where not t.extract_fail
     and t.t_seq <= :'anchor'::timestamptz
   order by t.sample_id
), m as (
  select b.*,
         (case test_code when 'ONCO-DNA' then 14 when 'HEME-DNA' then 16 else 8 end)
           * (case when instrument = 'NovaSeq X' then 1.1 else 0.9 end)
           * (0.7 + r_reads * 0.6)
           * (case when degraded then 0.35 else 1 end)                                  as reads_m,
         least(0.95,
               case when specimen = 'FFPE' and test_code = 'FUSION-RNA' then 0.35 + r_dup * 0.25
                    when specimen = 'FFPE'               then 0.22 + r_dup * 0.30
                    when specimen = 'reference_standard' then 0.12 + r_dup * 0.08
                    else 0.10 + r_dup * 0.15 end
               + case when degraded then 0.15 else 0 end)                               as dup,
         case when degraded                then 0.72 + r_q30 * 0.10
              when instrument = 'NovaSeq X' then 0.90 + r_q30 * 0.06
              else 0.86 + r_q30 * 0.07 end                                              as q30,
         case when specimen = 'FFPE' then 120 + r_ins * 60 else 250 + r_ins * 100 end   as ins
    from base b
), c as (
  select m.*,
         reads_m * (case test_code when 'ONCO-DNA' then 140 when 'HEME-DNA' then 150 else 90 end)
                 * (1 - dup)
                 * (case when specimen = 'FFPE' then 0.85 else 1 end)                   as cov
    from m
)
update lims.qc_metrics q
   set total_reads        = round(c.reads_m * 1e6),
       mean_coverage      = round(c.cov::numeric, 1),
       pct_target_250x    = round(greatest(0.05, least(0.999,
                              1 - 0.5 * power(250.0 / greatest(c.cov, 1), 1.5) - 0.02 * c.r_250))::numeric, 4),
       dup_rate           = round(c.dup::numeric, 4),
       q30_rate           = round(c.q30::numeric, 4),
       insert_size_median = round(c.ins),
       measured_at        = c.t_seq
  from c
 where q.sample_id = c.sample_id;

-- QC-failed clinical samples: 60% are failed (new specimen requested), the
-- rest go on and are signed out with a limitation comment.
alter table seed_timeline add column qc_stop boolean;
update seed_timeline t
   set qc_stop = t.specimen <> 'reference_standard'
                 and (lims.fn_qc_status(t.sample_id)).qc_status = 'FAIL'
                 and t.r_qcstop < 0.60;

-- Event list, cut off at the anchor time. Steps are increasing in time, so
-- the cut-off always leaves a legal prefix of the workflow.
create temp table seed_events as
select t.sample_id, e.ord, e.step, date_trunc('minute', e.ts) as ts
  from seed_timeline t
  cross join lateral (values
    (1, case when t.extract_fail then 'failed' else 'extracted' end, t.t_ext),
    (2, 'library_prep', case when not t.extract_fail then t.t_lib end),
    (3, 'sequenced',    case when not t.extract_fail then t.t_seq end),
    (4, case when t.qc_stop then 'failed' else 'analyzed' end,
        case when t.extract_fail then null
             when t.qc_stop then t.t_seq + interval '14 hours'
             else t.t_ana end),
    (5, 'signed_out',
        case when not t.extract_fail and not t.qc_stop and t.specimen <> 'reference_standard'
             then t.t_sign end)
  ) e(ord, step, ts)
 where e.ts is not null
   and e.ts <= :'anchor'::timestamptz;

-- ---------------------------------------------------------------------------
-- Variant generation helpers (session-only, in pg_temp)
-- ---------------------------------------------------------------------------
create function pg_temp.rnorm() returns double precision
language sql volatile as $$
  select sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random());
$$;

-- Driver hotspot catalog. grp = mutually exclusive group: a patient gets at
-- most one hotspot per group (e.g. KRAS / BRAF / EGFR do not co-occur, which
-- matches real tumors and shows up in the co-occurrence query).
create temp table seed_hotspots (
  hotspot_id int primary key, test_code text, grp text, gene text, chrom text, pos int,
  ref text, alt text, var_type text, hgvs_c text, hgvs_p text, tier lims.acmg_tier,
  clinvar text, cosmic_id text, oncokb text, prob numeric
);
insert into seed_hotspots values
  ( 1, 'ONCO-DNA', 'MAPK',   'KRAS',   'chr12',  25245350, 'C', 'T', 'SNV', 'c.35G>A',   'p.G12D',   'I',  'Pathogenic', 'COSM521',   '1',  0.14),
  ( 2, 'ONCO-DNA', 'MAPK',   'KRAS',   'chr12',  25245350, 'C', 'A', 'SNV', 'c.35G>T',   'p.G12V',   'I',  'Pathogenic', 'COSM520',   '3A', 0.10),
  ( 3, 'ONCO-DNA', 'MAPK',   'BRAF',   'chr7',  140753336, 'A', 'T', 'SNV', 'c.1799T>A', 'p.V600E',  'I',  'Pathogenic', 'COSM476',   '1',  0.10),
  ( 4, 'ONCO-DNA', 'MAPK',   'EGFR',   'chr7',   55191822, 'T', 'G', 'SNV', 'c.2573T>G', 'p.L858R',  'I',  'Pathogenic', 'COSM6224',  '1',  0.10),
  ( 5, 'ONCO-DNA', 'MAPK',   'EGFR',   'chr7',   55174771, 'AGGAATTAAGAGAAGC', 'A', 'DEL', 'c.2236_2250del', 'p.E746_A750del', 'I', 'Pathogenic', 'COSM6225', '1', 0.06),
  ( 6, 'ONCO-DNA', 'MAPK',   'NRAS',   'chr1',  114713908, 'T', 'C', 'SNV', 'c.182A>G',  'p.Q61R',   'I',  'Pathogenic', 'COSM584',   '3B', 0.04),
  ( 7, 'ONCO-DNA', 'TP53',   'TP53',   'chr17',   7675088, 'C', 'T', 'SNV', 'c.524G>A',  'p.R175H',  'II', 'Pathogenic', 'COSM10648', null, 0.20),
  ( 8, 'ONCO-DNA', 'TP53',   'TP53',   'chr17',   7673802, 'C', 'T', 'SNV', 'c.818G>A',  'p.R273H',  'II', 'Pathogenic/Likely pathogenic', 'COSM10660', null, 0.18),
  ( 9, 'ONCO-DNA', 'PIK3CA', 'PIK3CA', 'chr3',  179234297, 'A', 'G', 'SNV', 'c.3140A>G', 'p.H1047R', 'I',  'Pathogenic', 'COSM775',   '1',  0.12),
  (10, 'HEME-DNA', 'JAK2',   'JAK2',   'chr9',    5073770, 'G', 'T', 'SNV', 'c.1849G>T', 'p.V617F',  'I',  'Pathogenic', 'COSM12600', null, 0.25),
  (11, 'HEME-DNA', 'DNMT3A', 'DNMT3A', 'chr2',   25234373, 'C', 'T', 'SNV', 'c.2645G>A', 'p.R882H',  'II', 'Likely pathogenic', 'COSM52944', null, 0.22),
  (12, 'HEME-DNA', 'IDH1',   'IDH1',   'chr2',  208248388, 'C', 'T', 'SNV', 'c.395G>A',  'p.R132H',  'I',  'Pathogenic', 'COSM28746', '1',  0.12),
  (13, 'HEME-DNA', 'IDH2',   'IDH2',   'chr15',  90088702, 'C', 'T', 'SNV', 'c.419G>A',  'p.R140Q',  'I',  'Pathogenic', 'COSM41590', '1',  0.08),
  (14, 'HEME-DNA', 'NPM1',   'NPM1',   'chr5',  171410539, 'C', 'CTCTG', 'INS', 'c.860_863dup', 'p.W288Cfs*12', 'I', 'Pathogenic', 'COSM17559', null, 0.28),
  (15, 'HEME-DNA', 'FLT3',   'FLT3',   'chr13',  28034105, 'T', 'TGATTTCAGAGAATATGAATATGATCTCAAAT', 'ITD', 'c.1794_1823dup', 'p.ITD (30 bp)', 'I', null, null, '1', 0.18),
  (16, 'FUSION-RNA', 'FUS',  'ALK',    'chr2',   29223528, 'N', '<FUS>', 'FUSION', null, 'EML4::ALK',    'I', null, null, '1', 0.08),
  (17, 'FUSION-RNA', 'FUS',  'RET',    'chr10',  43114480, 'N', '<FUS>', 'FUSION', null, 'KIF5B::RET',   'I', null, null, '1', 0.05),
  (18, 'FUSION-RNA', 'FUS',  'ROS1',   'chr6',  117324415, 'N', '<FUS>', 'FUSION', null, 'CD74::ROS1',   'I', null, null, '1', 0.04),
  (19, 'FUSION-RNA', 'FUS',  'NTRK3',  'chr15',  87940000, 'N', '<FUS>', 'FUSION', null, 'ETV6::NTRK3',  'I', null, null, '1', 0.03),
  (20, 'FUSION-RNA', 'FUS',  'FGFR3',  'chr4',    1806000, 'N', '<FUS>', 'FUSION', null, 'FGFR3::TACC3', 'II', null, null, '3A', 0.04);

-- Per-patient drivers: cellular fraction and a trend across serial samples
-- (HEME: 80% respond to therapy and clear, 20% relapse with rising VAF).
create temp table seed_patient_drivers as
with g as (
  select hotspot_id, test_code, grp,
         sum(prob) over (partition by test_code, grp order by hotspot_id) - prob as lo,
         sum(prob) over (partition by test_code, grp order by hotspot_id)        as hi
    from seed_hotspots
), draws as materialized (
  select p.patient_id, p.test_code, gg.grp,
         random() as u, random() as u_frac, random() as u_trend, random() as u_dir
    from seed_plan p
    join (select distinct test_code, grp from seed_hotspots) gg using (test_code)
   order by p.patient_id, gg.grp
)
select d.patient_id, g.hotspot_id,
       case when d.test_code = 'ONCO-DNA' and d.grp = 'TP53'   then 0.80 + d.u_frac * 0.15   -- LOH
            when d.test_code = 'ONCO-DNA' and d.grp = 'PIK3CA' then 0.08 + d.u_frac * 0.35   -- often subclonal
            when d.test_code = 'ONCO-DNA'                      then 0.40 + d.u_frac * 0.10
            when d.test_code = 'HEME-DNA' and d.grp = 'JAK2'   then 0.10 + d.u_frac * 0.75   -- up to homozygous
            when d.test_code = 'HEME-DNA'                      then 0.06 + d.u_frac * 0.42
            else 0.15 + d.u_frac * 0.35 end                                             as frac,
       case when d.test_code = 'HEME-DNA'
            then case when d.u_dir < 0.80 then 0.25 + d.u_trend * 0.35 else 1.25 + d.u_trend * 0.35 end
            else 0.60 + d.u_trend * 0.70 end                                           as trend
  from draws d
  join g on g.test_code = d.test_code and g.grp = d.grp and d.u >= g.lo and d.u < g.hi;

-- Germline SNP pool per test (15 sites per panel gene) and each patient's genotypes.
create temp table seed_snp_pool as
with s as materialized (
  select pg.test_code, pg.gene, pg.chrom, pg.start_pos, pg.end_pos, g.i,
         random() as r_pos, random() as r_af, floor(random() * 4)::int as ri, 1 + floor(random() * 3)::int as sh
    from lims.panel_genes pg
    cross join generate_series(1, 15) g(i)
   order by pg.test_code, pg.gene, g.i
)
select row_number() over (order by test_code, gene, i) as snp_id,
       test_code, gene, chrom,
       start_pos + floor(r_pos * (end_pos - start_pos))::int                  as pos,
       (array['A', 'C', 'G', 'T'])[ri + 1]                                    as ref,
       (array['A', 'C', 'G', 'T'])[((ri + sh) % 4) + 1]                       as alt,
       round((0.01 + power(r_af, 1.5) * 0.55)::numeric, 3)                    as af
  from s;

create temp table seed_patient_germline as
with d as materialized (
  select p.patient_id, sp.snp_id, sp.af, random() as u
    from seed_plan p
    join seed_snp_pool sp using (test_code)
   order by p.patient_id, sp.snp_id
)
select patient_id, snp_id, case when u < af * af then 'hom' else 'het' end as zygosity
  from d
 where u < 2 * af - af * af;   -- carrier frequency under Hardy-Weinberg

-- Calls for one sample at its 'analyzed' step.
create function pg_temp.seed_variants(p_sample_id integer, p_at timestamptz)
returns integer
language plpgsql
as $$
declare
  s     record;
  n_vus integer;
  n     integer := 0;
  k     integer;
begin
  select sm.sample_id, sm.patient_id, sm.test_code, sm.specimen, sm.reference_material, sm.accession,
         coalesce(sm.tumor_purity, 1.0) as purity,
         q.mean_coverage as cov,
         (select count(*) from lims.samples s2
           where s2.patient_id = sm.patient_id and s2.received_at <= sm.received_at) as seq_no
    into s
    from lims.samples sm
    join lims.qc_metrics q using (sample_id)
   where sm.sample_id = p_sample_id;

  -- Reference standard: truth variants, with reduced detection below 5% VAF,
  -- plus one false positive in replicate 2.
  if s.specimen = 'reference_standard' then
    with x as materialized (
      select t.gene, t.chrom, t.pos, t.ref, t.alt, t.var_type, t.hgvs_p, t.expected_vaf,
             greatest(250, round(s.cov * (0.8 + random() * 0.4)))::int as depth,
             random() as u
        from lims.truth_variants t
       where t.material = s.reference_material
         and (t.expected_vaf >= 0.05
              or right(s.accession, 1)::int <= case when t.expected_vaf >= 0.03 then 2
                                                    when t.expected_vaf >= 0.02 then 1
                                                    else 0 end)
       order by t.truth_id
    ), y as (
      select x.*, greatest(3, round(depth * expected_vaf * (0.85 + u * 0.30)))::int as ar from x
    )
    insert into lims.variants (sample_id, gene, chrom, pos, ref, alt, var_type, hgvs_p,
                               depth, alt_reads, vaf, tier, annotations, called_at)
    select p_sample_id, gene, chrom, pos, ref, alt, var_type, hgvs_p, depth, ar,
           round(ar::numeric / depth, 4),
           case when gene in ('KRAS', 'NRAS', 'BRAF', 'EGFR', 'PIK3CA', 'KIT') then 'I' else 'II' end::lims.acmg_tier,
           jsonb_build_object('origin', 'validation', 'material', s.reference_material),
           p_at
      from y;
    get diagnostics n = row_count;

    if right(s.accession, 1) = '2' then
      insert into lims.variants (sample_id, gene, chrom, pos, ref, alt, var_type, hgvs_p,
                                 depth, alt_reads, vaf, tier, annotations, called_at)
      values (p_sample_id, 'PTEN', 'chr10', 87952140, 'G', 'A', 'SNV', null, 1612, 50, 0.0310, 'III',
              '{"origin": "validation", "note": "C>T artifact, absent from truth set"}', p_at);
      n := n + 1;
    end if;
    return n;
  end if;

  -- 1. Somatic drivers (consistent across a patient's serial samples)
  with x as materialized (
    select h.gene, h.chrom, h.pos, h.ref, h.alt, h.var_type, h.hgvs_c, h.hgvs_p, h.tier,
           h.clinvar, h.cosmic_id, h.oncokb,
           least(0.95, d.frac * case when s.specimen = 'FFPE' then s.purity else 1 end
                        * power(d.trend, s.seq_no - 1))                            as vtrue,
           greatest(0, round(s.cov * (0.7 + random() * 0.5)
                     * case when h.var_type in ('ITD', 'INS', 'DEL', 'FUSION') then 0.6 else 1 end))::int as depth,
           pg_temp.rnorm() as z
      from seed_patient_drivers d
      join seed_hotspots h using (hotspot_id)
     where d.patient_id = s.patient_id
     order by h.hotspot_id
  ), y as (
    select x.*,
           greatest(0, least(depth, round(depth * (vtrue + z * sqrt(vtrue * (1 - vtrue) / greatest(depth, 1))))))::int as ar
      from x
  )
  insert into lims.variants (sample_id, gene, chrom, pos, ref, alt, var_type, hgvs_c, hgvs_p,
                             depth, alt_reads, vaf, tier, annotations, called_at)
  select p_sample_id, gene, chrom, pos, ref, alt, var_type, hgvs_c, hgvs_p,
         depth, ar, round(ar::numeric / depth, 4), tier,
         jsonb_strip_nulls(jsonb_build_object('clinvar', clinvar, 'cosmic_id', cosmic_id,
                                              'oncokb_level', oncokb, 'gnomad_af', 0,
                                              'origin', 'somatic')),
         p_at
    from y
   where depth > 0 and ar >= 8 and ar::numeric / depth >= 0.02
  on conflict (sample_id, variant_key) do nothing;
  get diagnostics k = row_count;
  n := n + k;

  -- 2. Germline polymorphisms (Tier IV)
  with x as materialized (
    select p.gene, p.chrom, p.pos, p.ref, p.alt, p.af, g.zygosity,
           greatest(30, round(s.cov * (0.5 + random() * 0.8)))::int as depth,
           pg_temp.rnorm() as z
      from seed_patient_germline g
      join seed_snp_pool p using (snp_id)
     where g.patient_id = s.patient_id
     order by p.snp_id
  ), y as (
    select x.*,
           least(depth, greatest(1, round(depth * (case when zygosity = 'hom' then 0.995 else 0.5 end + z * 0.03))))::int as ar
      from x
  )
  insert into lims.variants (sample_id, gene, chrom, pos, ref, alt, var_type,
                             depth, alt_reads, vaf, tier, annotations, called_at)
  select p_sample_id, gene, chrom, pos, ref, alt, 'SNV', depth, ar, round(ar::numeric / depth, 4), 'IV',
         jsonb_build_object('clinvar', 'Benign', 'gnomad_af', af, 'origin', 'germline', 'zygosity', zygosity),
         p_at
    from y
  on conflict (sample_id, variant_key) do nothing;
  get diagnostics k = row_count;
  n := n + k;

  -- 3. A few somatic VUS (Tier III), random positions inside panel genes
  n_vus := case when s.test_code = 'FUSION-RNA' then floor(random() * 2)::int else 1 + floor(random() * 4)::int end;
  with x as materialized (
    select pg.gene, pg.chrom,
           pg.start_pos + floor(random() * (pg.end_pos - pg.start_pos))::int as pos,
           floor(random() * 4)::int as ri, 1 + floor(random() * 3)::int as sh,
           0.03 + random() * 0.42 as vtrue,
           greatest(50, round(s.cov * (0.6 + random() * 0.6)))::int as depth,
           random() as r_af
      from generate_series(1, n_vus) i
      cross join lateral (select * from lims.panel_genes pg0
                           where pg0.test_code = s.test_code and i is not null
                           order by random() limit 1) pg
  )
  insert into lims.variants (sample_id, gene, chrom, pos, ref, alt, var_type,
                             depth, alt_reads, vaf, tier, annotations, called_at)
  select p_sample_id, gene, chrom, pos,
         (array['A', 'C', 'G', 'T'])[ri + 1], (array['A', 'C', 'G', 'T'])[((ri + sh) % 4) + 1], 'SNV',
         depth, round(depth * vtrue)::int, round(round(depth * vtrue)::numeric / depth, 4), 'III',
         jsonb_build_object('clinvar', 'Uncertain significance',
                            'gnomad_af', round((r_af * 0.0005)::numeric, 6), 'origin', 'somatic'),
         p_at
    from x
  on conflict (sample_id, variant_key) do nothing;
  get diagnostics k = row_count;
  return n + k;
end;
$$;

-- ---------------------------------------------------------------------------
-- Replay the lab. Every status change goes through fn_advance_status, so the
-- transition rules, sign-out trigger and audit trail are all exercised.
-- ---------------------------------------------------------------------------
do $$
declare
  e record;
begin
  for e in select * from seed_events order by sample_id, ord loop
    perform set_config('lims.clock', e.ts::text, true);
    if e.step = 'analyzed' then
      perform pg_temp.seed_variants(e.sample_id, e.ts);
    end if;
    perform lims.fn_advance_status(e.sample_id, e.step::lims.sample_status);
  end loop;
  perform set_config('lims.clock', '', true);
end $$;

analyze;
refresh materialized view concurrently reporting.mv_run_qc;

drop function pg_temp.seed_variants(integer, timestamptz);
drop function pg_temp.rnorm();
drop table seed_plan, seed_samples, seed_timeline, seed_events, seed_hotspots,
           seed_patient_drivers, seed_snp_pool, seed_patient_germline;

\echo 'Seed summary:'
select (select count(*) from lims.patients)                               as patients,
       (select count(*) from lims.runs)                                   as runs,
       (select count(*) from lims.samples)                                as samples,
       (select count(*) from lims.samples where status = 'signed_out')    as signed_out,
       (select count(*) from lims.samples where status = 'failed')        as failed,
       (select count(*) from lims.variants)                               as variants,
       (select count(*) from lims.variants where tier in ('I', 'II'))     as tier_i_ii,
       (select count(*) from audit.change_log)                            as audit_rows;
