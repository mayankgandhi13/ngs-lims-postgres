-- 02_indexes.sql
-- Every index here supports a specific lab workflow or query. Foreign keys that
-- are already the leading column of a PK/UNIQUE index are not indexed twice
-- (variants.sample_id is covered by uq_variant_per_sample, qc_metrics by its PK).

-- "Have we seen chr7:140753336 before?" and region lookups when a new
-- hotspot is reported. Leading chrom then pos supports both equality and
-- range scans (pos between start and end of an exon).
create index ix_variants_chrom_pos on lims.variants (chrom, pos);

-- Reportable-variant queries only ever look at Tier I/II calls, which are a
-- small fraction of all calls (most calls are Tier IV germline polymorphisms).
-- A partial index stays tiny and is used whenever the query repeats the
-- predicate tier IN ('I','II'). INCLUDE lets the vaf/depth filters run
-- without visiting the heap for rows that fail them.
create index ix_variants_reportable on lims.variants (sample_id)
  include (vaf, depth)
  where tier in ('I', 'II');

-- JSONB annotation search: containment (@>) such as
-- annotations @> '{"clinvar":"Pathogenic"}' and key existence (? 'cosmic_id').
-- Default jsonb_ops (not jsonb_path_ops) so the ? operator is supported too.
create index ix_variants_annotations_gin on lims.variants using gin (annotations);

-- Work queue: "what is sitting at library_prep right now?". Status has few
-- distinct values, but open statuses are a minority once most samples are
-- signed out, so the planner uses this for the open-status filters.
create index ix_samples_status on lims.samples (status);

-- FK lookups: a patient's serial samples, and everything on a run.
create index ix_samples_patient on lims.samples (patient_id, received_at);
create index ix_samples_run on lims.samples (run_id);

-- Audit history of one row, in order (used by the recursive status-history CTE).
create index ix_change_log_row on audit.change_log (table_name, row_pk, log_id);
