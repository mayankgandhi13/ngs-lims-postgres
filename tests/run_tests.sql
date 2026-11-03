-- run_tests.sql: plain SQL assertions. Run with: make test
-- Everything runs inside one transaction that is rolled back, so tests never
-- change the seeded data. Exits non-zero if any test fails.

\set ON_ERROR_STOP on
\pset footer off
set client_min_messages = warning;

begin;

create temp table test_results (
  n       serial primary key,
  test    text    not null,
  passed  boolean not null,
  detail  text
) on commit drop;

\ir 01_illegal_transition.sql
\ir 02_signout_lock.sql
\ir 03_rls_report_reader.sql
\ir 04_concordance.sql
\ir 05_qc_one_row.sql
\ir 06_extra_invariants.sql

\echo
select n as "#", case when passed then 'PASS' else 'FAIL' end as result, test, detail
  from test_results
 order by n;

select count(*) filter (where not passed) > 0 as any_failed,
       count(*) filter (where passed)         as n_pass,
       count(*)                               as n_total
  from test_results \gset

rollback;

\echo :n_pass '/' :n_total 'tests passed'
\if :any_failed
  do $$ begin raise exception 'one or more tests FAILED'; end $$;
\endif
