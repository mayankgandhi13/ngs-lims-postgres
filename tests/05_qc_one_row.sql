-- Every sample has exactly one qc_metrics row.

insert into test_results (test, passed, detail)
select 'every sample has exactly one qc_metrics row',
       count(*) filter (where n_qc <> 1) = 0,
       format('%s samples checked, %s with zero or multiple rows',
              count(*), count(*) filter (where n_qc <> 1))
  from (select s.sample_id,
               (select count(*) from lims.qc_metrics q where q.sample_id = s.sample_id) as n_qc
          from lims.samples s) x;
