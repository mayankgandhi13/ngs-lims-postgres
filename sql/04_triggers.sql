-- 04_triggers.sql
-- Triggers on one table fire in name order, so they are prefixed t10/t20/t90.

-- ---------------------------------------------------------------------------
-- Generic audit trigger (CLIA: who changed what, when).
-- TG_ARGV holds the primary key column name(s) so one function serves any
-- table; composite keys are joined with a slash.
-- SECURITY INVOKER on purpose: current_user then records the real role.
-- ---------------------------------------------------------------------------
create or replace function audit.fn_log_change()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb;
  v_new jsonb;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;

  -- skip UPDATEs that changed nothing
  if tg_op = 'UPDATE' and v_old = v_new then
    return null;
  end if;

  insert into audit.change_log (table_name, op, row_pk, old_row, new_row,
                                changed_by, session_user_name, changed_at)
  values (tg_table_schema || '.' || tg_table_name,
          tg_op,
          (select string_agg(coalesce(v_new, v_old) ->> k, '/') from unnest(tg_argv) k),
          v_old, v_new,
          current_user, session_user, lims.fn_clock());
  return null;  -- AFTER trigger: return value ignored
end;
$$;

create trigger t90_audit
  after insert or update or delete on lims.samples
  for each row execute function audit.fn_log_change('sample_id');

create trigger t90_audit
  after insert or update or delete on lims.variants
  for each row execute function audit.fn_log_change('variant_id');

create trigger t90_audit
  after insert or update or delete on lims.qc_thresholds
  for each row execute function audit.fn_log_change('test_code', 'metric');

-- The audit log itself is append-only.
create or replace function audit.fn_block_edits()
returns trigger
language plpgsql
as $$
begin
  raise exception 'audit.change_log is append-only (% blocked)', tg_op;
end;
$$;

create trigger t10_append_only
  before update or delete on audit.change_log
  for each row execute function audit.fn_block_edits();

create trigger t11_no_truncate
  before truncate on audit.change_log
  for each statement execute function audit.fn_block_edits();

-- ---------------------------------------------------------------------------
-- Samples: status guard. Backstop for fn_advance_status so that even a direct
-- UPDATE ... SET status cannot skip steps, and only a pathologist signs out.
-- ---------------------------------------------------------------------------
create or replace function lims.fn_samples_status_guard()
returns trigger
language plpgsql
as $$
begin
  if not lims.fn_is_legal_transition(old.status, new.status) then
    raise exception using
      errcode = 'LIM01',
      message = format('illegal status transition for %s: %s -> %s', old.accession, old.status, new.status);
  end if;

  -- superusers count as members of every role, so the seed script passes
  if new.status = 'signed_out' and not pg_has_role(current_user, 'pathologist', 'MEMBER') then
    raise exception using
      errcode = 'LIM03',
      message = format('%s cannot sign out %s: pathologist role required', current_user, old.accession);
  end if;

  return new;
end;
$$;

create trigger t10_status_guard
  before update of status on lims.samples
  for each row
  when (old.status is distinct from new.status)
  execute function lims.fn_samples_status_guard();

-- ---------------------------------------------------------------------------
-- Samples: stamp reported_at at sign-out.
-- ---------------------------------------------------------------------------
create or replace function lims.fn_set_reported_at()
returns trigger
language plpgsql
as $$
begin
  new.reported_at := lims.fn_clock();
  return new;
end;
$$;

create trigger t20_set_reported_at
  before update of status on lims.samples
  for each row
  when (new.status = 'signed_out' and old.status is distinct from 'signed_out')
  execute function lims.fn_set_reported_at();

-- ---------------------------------------------------------------------------
-- Samples: create the one-and-only qc_metrics row at accession.
-- ---------------------------------------------------------------------------
create or replace function lims.fn_create_qc_stub()
returns trigger
language plpgsql
as $$
begin
  insert into lims.qc_metrics (sample_id) values (new.sample_id);
  return null;
end;
$$;

create trigger t30_qc_stub
  after insert on lims.samples
  for each row execute function lims.fn_create_qc_stub();

-- ---------------------------------------------------------------------------
-- Variants: sign-out lock. Once a sample is signed out its calls are part of
-- a released clinical report and may not be inserted, changed or deleted.
-- On UPDATE both the old and new sample are checked, so a call cannot be
-- moved off a signed-out sample either. Corrections go through an amended
-- report workflow, not an edit.
-- ---------------------------------------------------------------------------
create or replace function lims.fn_variants_signout_lock()
returns trigger
language plpgsql
as $$
declare
  v_ids    integer[];
  v_locked text;
begin
  v_ids := case tg_op
             when 'INSERT' then array[new.sample_id]
             when 'DELETE' then array[old.sample_id]
             else array[old.sample_id, new.sample_id]
           end;

  select s.accession into v_locked
    from lims.samples s
   where s.sample_id = any (v_ids) and s.status = 'signed_out'
   limit 1;

  if v_locked is not null then
    raise exception using
      errcode = 'LIM02',
      message = format('%s on lims.variants blocked: sample %s is signed out', tg_op, v_locked),
      hint    = 'Signed-out results are locked. Issue an amended report instead.';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger t10_signout_lock
  before insert or update or delete on lims.variants
  for each row execute function lims.fn_variants_signout_lock();
