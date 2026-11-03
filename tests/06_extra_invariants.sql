-- Extra invariants: role checks, audit completeness, reported_at.

-- Only a pathologist can sign out (LIM03 for a lab tech).
do $$
declare
  v_id integer;
  v_ok boolean := false;
  v_msg text := 'no exception raised';
begin
  select sample_id into strict v_id
    from lims.samples
   where status = 'analyzed' and specimen <> 'reference_standard'
   order by sample_id limit 1;
  begin
    set local role lab_tech;
    perform lims.fn_advance_status(v_id, 'signed_out');
  exception when sqlstate 'LIM03' then
    v_ok := true; v_msg := sqlerrm;
  end;
  reset role;
  insert into test_results (test, passed, detail)
  values ('lab_tech cannot sign out (LIM03)', v_ok, v_msg);
end $$;

-- A pathologist can, and the audit row records the pathologist role.
do $$
declare
  v_id integer;
  v_by name;
  v_reported timestamptz;
begin
  select sample_id into strict v_id
    from lims.samples
   where status = 'analyzed' and specimen <> 'reference_standard'
   order by sample_id limit 1;
  set local role pathologist;
  perform lims.fn_advance_status(v_id, 'signed_out');
  reset role;
  select reported_at into v_reported from lims.samples where sample_id = v_id;
  select changed_by into v_by from audit.change_log
   where table_name = 'lims.samples' and row_pk = v_id::text
   order by log_id desc limit 1;
  insert into test_results (test, passed, detail)
  values ('pathologist signs out: reported_at set, audit changed_by = pathologist',
          v_reported is not null and v_by = 'pathologist',
          format('reported_at %s, changed_by %s', v_reported, v_by));
end $$;

-- The last audited status of every sample equals its current status.
insert into test_results (test, passed, detail)
select 'audit log reproduces every sample''s current status',
       count(*) filter (where last_status is distinct from s.status::text) = 0,
       format('%s samples, %s mismatches', count(*),
              count(*) filter (where last_status is distinct from s.status::text))
  from lims.samples s
  cross join lateral (select c.new_row ->> 'status' as last_status
                        from audit.change_log c
                       where c.table_name = 'lims.samples' and c.row_pk = s.sample_id::text
                       order by c.log_id desc limit 1) a;

-- reported_at is set if and only if the sample is signed out.
insert into test_results (test, passed, detail)
select 'reported_at present exactly for signed_out samples',
       count(*) filter (where (status = 'signed_out') <> (reported_at is not null)) = 0,
       format('%s violations', count(*) filter (where (status = 'signed_out') <> (reported_at is not null)))
  from lims.samples;

-- The audit log is append-only.
do $$
declare
  v_ok boolean := false;
begin
  begin
    delete from audit.change_log where log_id = (select min(log_id) from audit.change_log);
  exception when raise_exception then v_ok := true;
  end;
  insert into test_results (test, passed, detail)
  values ('audit.change_log rejects DELETE', v_ok, null);
end $$;
