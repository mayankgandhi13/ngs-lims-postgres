-- Validation: overall sensitivity on the reference standard is at least 85%.

insert into test_results (test, passed, detail)
select 'concordance sensitivity on REFSTD-A >= 85%',
       coalesce(sensitivity >= 0.85, false),
       format('TP %s, FP %s, FN %s, sensitivity %s, PPV %s', tp, fp, fn, sensitivity, ppv)
  from lims.fn_concordance('ONCO-DNA')
 where var_type = 'ALL';
