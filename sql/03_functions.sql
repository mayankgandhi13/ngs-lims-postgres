-- 03_functions.sql
-- PL/pgSQL business logic. Custom SQLSTATEs make errors easy to catch in tests:
--   LIM00 sample not found
--   LIM01 illegal status transition
--   LIM02 edit blocked on a signed-out sample
--   LIM03 only a pathologist may sign out

-- ---------------------------------------------------------------------------
-- fn_clock: the timestamp used for audit and reported_at.
-- Normally now(). The seed script backfills six months of history, so a
-- superuser may set the session variable lims.clock to replay events at their
-- historical time. The setting is ignored for everyone else, so ordinary roles
-- cannot backdate audit records.
-- ---------------------------------------------------------------------------
create or replace function lims.fn_clock()
returns timestamptz
language plpgsql
stable
as $$
declare
  v_clock text := current_setting('lims.clock', true);
begin
  if v_clock is not null and v_clock <> ''
     and coalesce((select rolsuper from pg_roles where rolname = current_user), false) then
    return v_clock::timestamptz;
  end if;
  return now();
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_is_legal_transition: the status state machine in one place.
-- Happy path follows enum order one step at a time. Any open status may move
-- to 'failed'. signed_out and failed are terminal.
-- ---------------------------------------------------------------------------
create or replace function lims.fn_is_legal_transition(p_from lims.sample_status, p_to lims.sample_status)
returns boolean
language sql
stable
as $$
  select case
    when p_from in ('signed_out', 'failed') then false
    when p_to = 'failed' then true
    else array_position(enum_range(null::lims.sample_status), p_to)
       = array_position(enum_range(null::lims.sample_status), p_from) + 1
  end;
$$;

-- ---------------------------------------------------------------------------
-- fn_advance_status: the supported way to move a sample through the lab.
-- Locks the row, validates the move and raises LIM01 on an illegal one.
-- (The same rule is enforced again by a BEFORE UPDATE trigger, so a direct
-- UPDATE cannot skip steps either.)
-- ---------------------------------------------------------------------------
create or replace function lims.fn_advance_status(p_sample_id integer, p_new_status lims.sample_status)
returns lims.sample_status
language plpgsql
as $$
declare
  v_old lims.sample_status;
  v_acc text;
begin
  select s.status, s.accession into v_old, v_acc
    from lims.samples s
   where s.sample_id = p_sample_id
     for update;

  if not found then
    raise exception using errcode = 'LIM00', message = format('sample %s not found', p_sample_id);
  end if;

  if not lims.fn_is_legal_transition(v_old, p_new_status) then
    raise exception using
      errcode = 'LIM01',
      message = format('illegal status transition for %s: %s -> %s', v_acc, v_old, p_new_status),
      hint    = 'Allowed: received > extracted > library_prep > sequenced > analyzed > signed_out, '
             || 'or any open status > failed.';
  end if;

  update lims.samples set status = p_new_status where sample_id = p_sample_id;
  return p_new_status;
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_tat_days: turnaround in days, receipt to sign-out. For a sample that is
-- not signed out yet it returns elapsed days so far.
-- SECURITY DEFINER so report_reader can use it inside reporting views without
-- needing USAGE on the lims schema.
-- ---------------------------------------------------------------------------
create or replace function lims.fn_tat_days(p_sample_id integer)
returns numeric
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_days numeric;
begin
  select round(extract(epoch from coalesce(s.reported_at, now()) - s.received_at) / 86400.0, 1)
    into v_days
    from lims.samples s
   where s.sample_id = p_sample_id;

  if not found then
    raise exception using errcode = 'LIM00', message = format('sample %s not found', p_sample_id);
  end if;
  return v_days;
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_qc_status: compares a sample's qc_metrics row to lims.qc_thresholds.
-- The metrics row is turned into JSONB so thresholds can be data-driven:
-- adding a threshold row for an existing column needs no code change.
-- Returns PASS or FAIL plus the reasons, or PENDING if not sequenced yet.
-- ---------------------------------------------------------------------------
create or replace function lims.fn_qc_status(p_sample_id integer,
                                             out qc_status text,
                                             out fail_reasons text[])
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_test text;
  v_row  jsonb;
begin
  select s.test_code into v_test from lims.samples s where s.sample_id = p_sample_id;
  if not found then
    raise exception using errcode = 'LIM00', message = format('sample %s not found', p_sample_id);
  end if;

  select to_jsonb(q) into v_row from lims.qc_metrics q where q.sample_id = p_sample_id;

  if v_row is null then
    qc_status := 'FAIL';
    fail_reasons := array['no qc_metrics row'];
    return;
  end if;

  if v_row ->> 'measured_at' is null then
    qc_status := 'PENDING';
    fail_reasons := '{}';
    return;
  end if;

  select coalesce(array_agg(
           case
             when x.val is null          then format('%s missing', t.metric)
             when x.val < t.min_value    then format('%s %s < %s', t.metric, x.val, t.min_value)
             else                             format('%s %s > %s', t.metric, x.val, t.max_value)
           end order by t.metric), '{}')
    into fail_reasons
    from lims.qc_thresholds t
    cross join lateral (select (v_row ->> t.metric)::numeric as val) x
   where t.test_code = v_test
     and (x.val is null or x.val < t.min_value or x.val > t.max_value);

  qc_status := case when cardinality(fail_reasons) = 0 then 'PASS' else 'FAIL' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_concordance: validation metrics for a test against its truth set.
-- Every reference-standard replicate is expected to contain every truth
-- variant. A FULL OUTER JOIN of expected vs called gives:
--   both sides -> TP, truth only -> FN, call only -> FP
-- Output is per var_type plus an ALL row (GROUPING SETS).
-- ---------------------------------------------------------------------------
create or replace function lims.fn_concordance(p_test_code text)
returns table (var_type text, tp bigint, fp bigint, fn bigint, sensitivity numeric, ppv numeric)
language plpgsql
stable
as $$
#variable_conflict use_column
begin
  return query
  with reps as (
    select s.sample_id, s.reference_material
      from lims.samples s
     where s.test_code = p_test_code
       and s.specimen = 'reference_standard'
       and s.status in ('analyzed', 'signed_out')
  ),
  expected as (
    select r.sample_id, t.variant_key, t.var_type
      from reps r
      join lims.truth_variants t
        on t.test_code = p_test_code and t.material = r.reference_material
  ),
  called as (
    select v.sample_id, v.variant_key, v.var_type
      from lims.variants v
      join reps r on r.sample_id = v.sample_id
  ),
  cmp as (
    select coalesce(e.var_type, c.var_type) as vt,
           e.variant_key is not null        as in_truth,
           c.variant_key is not null        as in_calls
      from expected e
      full outer join called c
        on c.sample_id = e.sample_id and c.variant_key = e.variant_key
  )
  select coalesce(cmp.vt, 'ALL'),
         count(*) filter (where in_truth and in_calls),
         count(*) filter (where in_calls and not in_truth),
         count(*) filter (where in_truth and not in_calls),
         round(count(*) filter (where in_truth and in_calls)::numeric
               / nullif(count(*) filter (where in_truth), 0), 4),
         round(count(*) filter (where in_truth and in_calls)::numeric
               / nullif(count(*) filter (where in_calls), 0), 4)
    from cmp
   group by grouping sets ((cmp.vt), ())
   order by grouping(cmp.vt), cmp.vt;
end;
$$;
