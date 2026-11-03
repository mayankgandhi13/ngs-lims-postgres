-- 01_schema.sql
-- Core data model for a hospital molecular pathology NGS lab.
--   lims      core operational data (patients, samples, runs, QC, variant calls)
--   audit     append-only change log (CLIA record keeping)
--   reporting read-only views for dashboards and report consumers

create schema lims;
create schema audit;
create schema reporting;

comment on schema lims      is 'Core LIMS data: patients, tests, runs, samples, QC and variant calls';
comment on schema audit     is 'Append-only audit trail written by triggers';
comment on schema reporting is 'Views and materialized views for report consumers';

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type lims.specimen_type as enum ('FFPE', 'blood', 'bone_marrow', 'reference_standard');

-- Declaration order matters: fn_is_legal_transition() uses enum order to
-- define the happy path received -> ... -> signed_out. 'failed' is terminal.
create type lims.sample_status as enum (
  'received', 'extracted', 'library_prep', 'sequenced', 'analyzed', 'signed_out', 'failed'
);

-- Somatic variant tiers (AMP/ASCO/CAP 2017 style, named acmg_tier per lab convention):
-- I strong clinical significance, II potential, III unknown (VUS), IV benign/likely benign.
create type lims.acmg_tier as enum ('I', 'II', 'III', 'IV');

-- ---------------------------------------------------------------------------
-- Reference tables
-- ---------------------------------------------------------------------------
create table lims.patients (
  patient_id  integer generated always as identity primary key,
  mrn         text        not null unique check (mrn ~ '^SYN[0-9]{6}$'),  -- synthetic MRNs only
  sex         char(1)     not null check (sex in ('F', 'M', 'U')),
  birth_year  smallint    not null check (birth_year between 1900 and 2026),
  created_at  timestamptz not null default now()
);
comment on table lims.patients is 'Synthetic patients. No PHI: MRNs are prefixed SYN.';

create table lims.tests (
  test_code        text    primary key check (test_code ~ '^[A-Z]+-[A-Z]+$'),
  test_name        text    not null,
  analyte          text    not null check (analyte in ('DNA', 'RNA')),
  tat_target_days  integer not null check (tat_target_days between 1 and 60),
  active           boolean not null default true
);
comment on column lims.tests.tat_target_days is 'Turnaround target, receipt to sign-out, in calendar days';

create table lims.panel_genes (
  test_code   text    not null references lims.tests (test_code) on update cascade on delete cascade,
  gene        text    not null check (gene ~ '^[A-Z0-9]+$'),
  chrom       text    not null check (chrom ~ '^chr([1-9]|1[0-9]|2[0-2]|X|Y)$'),
  start_pos   integer not null check (start_pos > 0),
  end_pos     integer not null,
  transcript  text,
  primary key (test_code, gene),
  check (end_pos > start_pos)
);
comment on table lims.panel_genes is 'Genes covered by each test. Coordinates are approximate GRCh38 gene spans.';

create table lims.runs (
  run_id       integer generated always as identity primary key,
  run_name     text not null unique,
  instrument   text not null check (instrument in ('NovaSeq X', 'NextSeq 2000')),
  flowcell_id  text not null unique,
  run_date     date not null,
  notes        text
);

-- ---------------------------------------------------------------------------
-- Samples and QC
-- ---------------------------------------------------------------------------
create table lims.samples (
  sample_id           integer generated always as identity primary key,
  accession           text        not null unique,
  patient_id          integer     references lims.patients (patient_id) on delete restrict,
  test_code           text        not null references lims.tests (test_code) on update cascade on delete restrict,
  run_id              integer     references lims.runs (run_id) on delete set null,
  specimen            lims.specimen_type  not null,
  reference_material  text,
  tumor_purity        numeric(3,2) check (tumor_purity > 0 and tumor_purity <= 1),
  status              lims.sample_status  not null default 'received',
  received_at         timestamptz not null,
  reported_at         timestamptz,
  -- reference standards have no patient; every clinical sample must have one
  constraint ck_patient_unless_refstd  check ((specimen = 'reference_standard') = (patient_id is null)),
  constraint ck_refmaterial_for_refstd check ((specimen = 'reference_standard') = (reference_material is not null)),
  constraint ck_reported_after_received check (reported_at >= received_at),
  constraint ck_signed_out_has_reported_at check (status <> 'signed_out' or reported_at is not null)
);
comment on column lims.samples.reported_at is 'Set automatically by trigger when status becomes signed_out';
comment on column lims.samples.run_id      is 'NULL until the sample is batched onto a sequencing run';

-- Exactly one row per sample (PK on sample_id plus an AFTER INSERT trigger that
-- creates it). Sequencing metrics stay NULL until the run completes.
create table lims.qc_metrics (
  sample_id           integer primary key references lims.samples (sample_id) on delete cascade,
  total_reads         bigint       check (total_reads >= 0),
  mean_coverage       numeric(7,1) check (mean_coverage >= 0),
  pct_target_250x     numeric(5,4) check (pct_target_250x between 0 and 1),
  dup_rate            numeric(5,4) check (dup_rate between 0 and 1),
  q30_rate            numeric(5,4) check (q30_rate between 0 and 1),
  insert_size_median  integer      check (insert_size_median > 0),
  measured_at         timestamptz
);

create table lims.qc_thresholds (
  test_code  text    not null references lims.tests (test_code) on update cascade on delete cascade,
  metric     text    not null check (metric in ('total_reads', 'mean_coverage', 'pct_target_250x',
                                                'dup_rate', 'q30_rate', 'insert_size_median')),
  min_value  numeric,
  max_value  numeric,
  primary key (test_code, metric),
  check (min_value is not null or max_value is not null),
  check (min_value <= max_value)
);
comment on table lims.qc_thresholds is 'Per-test acceptance limits. metric must match a lims.qc_metrics column name.';

-- ---------------------------------------------------------------------------
-- Variant calls and validation truth set
-- ---------------------------------------------------------------------------
create table lims.variants (
  variant_id   bigint generated always as identity primary key,
  sample_id    integer      not null references lims.samples (sample_id) on delete cascade,
  gene         text         not null,
  chrom        text         not null check (chrom ~ '^chr([1-9]|1[0-9]|2[0-2]|X|Y|M)$'),
  pos          integer      not null check (pos > 0),
  ref          text         not null check (ref ~ '^[ACGTN]+$'),
  alt          text         not null check (alt ~ '^([ACGT]+|<FUS>)$'),
  var_type     text         not null check (var_type in ('SNV', 'MNV', 'INS', 'DEL', 'ITD', 'FUSION')),
  hgvs_c       text,
  hgvs_p       text,
  depth        integer      not null check (depth >= 0),
  alt_reads    integer      not null check (alt_reads >= 0 and alt_reads <= depth),
  vaf          numeric(5,4) not null check (vaf between 0 and 1),
  tier         lims.acmg_tier not null,
  annotations  jsonb        not null default '{}' check (jsonb_typeof(annotations) = 'object'),
  called_at    timestamptz  not null default now(),
  -- pos::text (not bare pos) because int || text is only STABLE and generated
  -- columns need an IMMUTABLE expression.
  variant_key  text generated always as (chrom || ':' || pos::text || ref || '>' || alt) stored,
  constraint uq_variant_per_sample unique (sample_id, variant_key)
);
comment on column lims.variants.annotations is 'Free-form annotation: clinvar, cosmic_id, gnomad_af, oncokb_level, origin';
comment on column lims.variants.variant_key is 'chrom:posREF>ALT, e.g. chr7:140753336A>T (BRAF V600E)';

create table lims.truth_variants (
  truth_id      integer generated always as identity primary key,
  test_code     text         not null references lims.tests (test_code) on update cascade on delete cascade,
  material      text         not null,
  gene          text         not null,
  chrom         text         not null check (chrom ~ '^chr([1-9]|1[0-9]|2[0-2]|X|Y|M)$'),
  pos           integer      not null check (pos > 0),
  ref           text         not null check (ref ~ '^[ACGTN]+$'),
  alt           text         not null check (alt ~ '^[ACGT]+$'),
  var_type      text         not null check (var_type in ('SNV', 'MNV', 'INS', 'DEL')),
  hgvs_p        text,
  expected_vaf  numeric(5,4) not null check (expected_vaf > 0 and expected_vaf <= 1),
  variant_key   text generated always as (chrom || ':' || pos::text || ref || '>' || alt) stored,
  unique (test_code, material, variant_key)
);
comment on table lims.truth_variants is 'Known variants in a reference material, used for assay validation (sensitivity, PPV, LOD)';

-- ---------------------------------------------------------------------------
-- Audit
-- ---------------------------------------------------------------------------
create table audit.change_log (
  log_id             bigint generated always as identity primary key,
  table_name         text        not null,
  op                 text        not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  row_pk             text        not null,
  old_row            jsonb,
  new_row            jsonb,
  changed_by         name        not null default current_user,
  session_user_name  name        not null default session_user,
  changed_at         timestamptz not null default now(),
  txid               bigint      not null default txid_current(),
  check ((op = 'INSERT' and old_row is null and new_row is not null)
      or (op = 'UPDATE' and old_row is not null and new_row is not null)
      or (op = 'DELETE' and old_row is not null and new_row is null))
);
comment on column audit.change_log.changed_by        is 'current_user (the effective role) at the time of change';
comment on column audit.change_log.session_user_name is 'login user, which differs from changed_by after SET ROLE';
