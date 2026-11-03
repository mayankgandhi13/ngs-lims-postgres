-- An illegal status transition raises LIM01, through the function and through a direct UPDATE.

do $$
declare
  v_id integer;
  v_ok boolean := false;
  v_msg text := 'no exception raised';
begin
  select sample_id into strict v_id
    from lims.samples where status = 'received' order by sample_id limit 1;
  begin
    perform lims.fn_advance_status(v_id, 'signed_out');
  exception when sqlstate 'LIM01' then
    v_ok := true; v_msg := sqlerrm;
  end;
  insert into test_results (test, passed, detail)
  values ('fn_advance_status: received -> signed_out raises LIM01', v_ok, v_msg);
end $$;

do $$
declare
  v_id integer;
  v_ok boolean := false;
  v_msg text := 'no exception raised';
begin
  select sample_id into strict v_id
    from lims.samples where status = 'extracted' order by sample_id limit 1;
  begin
    update lims.samples set status = 'analyzed' where sample_id = v_id;   -- skips 2 steps
  exception when sqlstate 'LIM01' then
    v_ok := true; v_msg := sqlerrm;
  end;
  insert into test_results (test, passed, detail)
  values ('direct UPDATE extracted -> analyzed blocked by trigger', v_ok, v_msg);
end $$;

do $$
declare
  v_id integer;
  v_ok boolean := false;
  v_msg text := 'no exception raised';
begin
  select sample_id into strict v_id
    from lims.samples where status = 'failed' order by sample_id limit 1;
  begin
    perform lims.fn_advance_status(v_id, 'analyzed');
  exception when sqlstate 'LIM01' then
    v_ok := true; v_msg := sqlerrm;
  end;
  insert into test_results (test, passed, detail)
  values ('failed is terminal (failed -> analyzed raises)', v_ok, v_msg);
end $$;
