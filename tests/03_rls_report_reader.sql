-- report_reader only sees signed-out samples (row-level security), and cannot
-- touch the lims schema directly.

select count(*) filter (where status <> 'signed_out') as admin_unsigned,
       count(*)                                     as admin_total
  from reporting.v_sample_summary \gset

set role report_reader;
select count(*) filter (where status <> 'signed_out') as rr_unsigned,
       count(*) filter (where status = 'signed_out')  as rr_signed
  from reporting.v_sample_summary \gset
select count(*) as rr_queue from reporting.v_work_queue \gset
select count(*) filter (where status <> 'signed_out') as rr_unsigned_variants
  from reporting.v_reportable_variants \gset
reset role;

insert into test_results (test, passed, detail)
select 'report_reader sees only signed-out samples (RLS via SET ROLE)',
       :rr_unsigned = 0 and :rr_signed > 0 and :admin_unsigned > 0,
       format('admin sees %s unsigned of %s; report_reader sees %s unsigned, %s signed out',
              :admin_unsigned, :admin_total, :rr_unsigned, :rr_signed);

insert into test_results (test, passed, detail)
select 'report_reader: work queue empty, no unsigned reportable variants',
       :rr_queue = 0 and :rr_unsigned_variants = 0,
       format('work queue rows %s, unsigned reportable variants %s', :rr_queue, :rr_unsigned_variants);

do $$
declare
  v_denied boolean := false;
  v_msg    text := 'query succeeded';
begin
  begin
    set local role report_reader;
    perform count(*) from lims.samples;
  exception when insufficient_privilege then
    v_denied := true; v_msg := sqlerrm;
  end;
  reset role;
  insert into test_results (test, passed, detail)
  values ('report_reader cannot query lims.samples directly', v_denied, v_msg);
end $$;
