-- Editing, deleting or adding a variant on a signed-out sample is blocked (LIM02).

do $$
declare
  v_vid bigint;
  v_sid integer;
  n_ok  integer := 0;
  v_msg text;
begin
  select v.variant_id, v.sample_id into strict v_vid, v_sid
    from lims.variants v join lims.samples s using (sample_id)
   where s.status = 'signed_out'
   order by v.variant_id limit 1;

  begin
    update lims.variants set tier = 'III' where variant_id = v_vid;
  exception when sqlstate 'LIM02' then n_ok := n_ok + 1; v_msg := sqlerrm;
  end;

  begin
    delete from lims.variants where variant_id = v_vid;
  exception when sqlstate 'LIM02' then n_ok := n_ok + 1;
  end;

  begin
    insert into lims.variants (sample_id, gene, chrom, pos, ref, alt, var_type, depth, alt_reads, vaf, tier)
    values (v_sid, 'TP53', 'chr17', 7674220, 'C', 'T', 'SNV', 500, 50, 0.1, 'II');
  exception when sqlstate 'LIM02' then n_ok := n_ok + 1;
  end;

  insert into test_results (test, passed, detail)
  values ('UPDATE / DELETE / INSERT of variants on a signed-out sample blocked',
          n_ok = 3, format('%s of 3 blocked; %s', n_ok, v_msg));
end $$;

-- Control: the lock only applies to signed-out samples.
do $$
declare
  v_vid bigint;
  v_ok  boolean := true;
  v_msg text := 'update allowed';
begin
  select v.variant_id into strict v_vid
    from lims.variants v join lims.samples s using (sample_id)
   where s.status = 'analyzed' and s.specimen <> 'reference_standard'
   order by v.variant_id limit 1;
  begin
    update lims.variants set tier = 'III' where variant_id = v_vid;
  exception when others then v_ok := false; v_msg := sqlerrm;
  end;
  insert into test_results (test, passed, detail)
  values ('control: variant on an analyzed (unsigned) sample can still be edited', v_ok, v_msg);
end $$;
