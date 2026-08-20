#!/bin/bash
# Integration tests for merge-reports.sh. No network, no model calls: every test runs the
# merge phases with --no-l2 and asserts on the artifacts.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"
MERGE="$REPO/bin/merge-reports.sh"
DATE=2026-08-18
pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){     [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
assert_grep(){   grep -q "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){ grep -q "$2" "$1" 2>/dev/null && no "$3 (/$2/ unexpectedly in $1)" || ok "$3"; }

# An OMP session file: the header carries the real cwd, which is the only thing that can
# reconcile project identity across harnesses.
mk_omp_session(){ # $1=path $2=cwd
  mkdir -p "$(dirname "$1")"
  {
    printf '{"type":"title","v":1,"title":"fixture"}\n'
    printf '{"type":"session","version":3,"id":"s1","cwd":"%s"}\n' "$2"
    printf '{"type":"message","id":"e1","parentId":null,"message":{"role":"user","attribution":"user","content":[{"type":"text","text":"hi"}]}}\n'
  } > "$1"
}
mk_finding(){ # $1=dir $2=hash $3=session_path $4=project
  mkdir -p "$1"
  printf '{"session_path":"%s","project":"%s","findings":[{"category":"tool_loop","severity":"low"}]}\n' \
    "$3" "$4" > "$1/$2.json"
}
setup(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/adm.XXXXXX")
  # Claude side: project is the encoded cwd, which is what cc-autodream derives.
  mk_finding "$root/cc/findings/$DATE" aaaaaaaaaaaa "/store/claude/-Users-x-sites/s.jsonl" "-Users-x-sites"
  printf 'runner_commit: cccccc\n' > "$root/cc/findings/$DATE/run-stats.txt"
  # OMP side: omp-autodream derives basename(dirname(path)), i.e. the storage BUCKET, so
  # the same real directory arrives under a different name and would split the project.
  mk_omp_session "$root/store/omp/-sites/o.jsonl" "/Users/x/sites"
  mk_finding "$root/omp/findings/$DATE" bbbbbbbbbbbb "$root/store/omp/-sites/o.jsonl" "-sites"
  printf 'runner_commit: oooooo\n' > "$root/omp/findings/$DATE/run-stats.txt"
  printf '%s' "$root"
}
run_merge(){ # $1=root ; extra args passed through
  local root="$1"; shift
  "$MERGE" "$DATE" "$root/out" \
    "$root/cc/findings/$DATE:claude" "$root/omp/findings/$DATE:omp" --no-l2 "$@" \
    > "$root/merge.out" 2>&1
}
mdir(){ printf '%s' "$1/out/findings/$DATE"; }

test_merges_both_sources(){
  echo "# merge: both installs' records land in one dir, stamped with their source"
  local root; root=$(setup)
  run_merge "$root" || no "merge exited non-zero"
  assert_eq "$(ls "$(mdir "$root")"/*.json 2>/dev/null | grep -vc stats)" "2" "both records merged"
  assert_eq "$(jq -r .source "$(mdir "$root")/aaaaaaaaaaaa.json")" "claude" "claude record stamped"
  assert_eq "$(jq -r .source "$(mdir "$root")/bbbbbbbbbbbb.json")" "omp"    "omp record stamped"
  assert_grep "$(mdir "$root")/run-stats.txt" 'merged_records: 2' "self-audit counts the merge"
  assert_grep "$(mdir "$root")/run-stats.txt" 'cccccc' "keeps each install's provenance"
  assert_grep "$(mdir "$root")/run-stats.txt" 'oooooo' "keeps the other install's provenance"
  rm -rf "$root"
}

test_reconciles_project_identity(){
  echo "# merge: an omp bucket name becomes the encoded cwd, so one project not two"
  local root; root=$(setup)
  run_merge "$root" || no "merge exited non-zero"
  # This is the whole point: -sites (bucket) and -Users-x-sites (claude) are the same dir.
  assert_eq "$(jq -r .project "$(mdir "$root")/bbbbbbbbbbbb.json")" "-Users-x-sites" \
    "omp project re-derived from the session header cwd"
  assert_eq "$(jq -r .project "$(mdir "$root")/aaaaaaaaaaaa.json")" "-Users-x-sites" \
    "claude project untouched"
  assert_eq "$(jq -r -s '[.[]|.project]|unique|length' "$(mdir "$root")"/[ab]*.json)" "1" \
    "both harnesses group into ONE project"
  assert_grep "$root/merge.out" '1 changed, 0 unresolvable' "the log reports what it reconciled"
  rm -rf "$root"
}

test_rerun_is_idempotent(){
  echo "# merge: re-running over an existing merged dir is idempotent, not 2 collisions"
  local root; root=$(setup)
  run_merge "$root" || no "first merge exited non-zero"
  run_merge "$root" || no "second merge exited non-zero"
  # The first version treated every already-present file as a collision and reported
  # merged_records: 0 — the aggregator caught that zero in the report before I did.
  assert_nogrep "$root/merge.out" 'COLLISION' "no false collision on re-run"
  assert_grep "$(mdir "$root")/run-stats.txt" 'merged_records: 2' "re-run still counts the records"
  assert_grep "$(mdir "$root")/run-stats.txt" 'merged_remerged: 2' "and reports them as re-merged"
  assert_grep "$(mdir "$root")/run-stats.txt" 'merged_collisions: 0' "with no collisions"
  rm -rf "$root"
}

test_real_collision_is_kept_and_counted(){
  echo "# merge: two DIFFERENT sessions on one filename keep the first and are counted"
  local root; root=$(setup)
  run_merge "$root" || no "first merge exited non-zero"
  # Same hash, different session: a real (astronomically unlikely) collision, or a bug in
  # a caller. Either way the second must not silently overwrite the first.
  mk_finding "$root/omp/findings/$DATE" aaaaaaaaaaaa "/store/omp/-other/zz.jsonl" "-other"
  run_merge "$root" || no "second merge exited non-zero"
  assert_grep "$root/merge.out" 'COLLISION' "a genuine collision is reported"
  assert_grep "$(mdir "$root")/run-stats.txt" 'merged_collisions: 1' "and counted"
  assert_eq "$(jq -r .session_path "$(mdir "$root")/aaaaaaaaaaaa.json")" "/store/claude/-Users-x-sites/s.jsonl" \
    "the first record survives"
  rm -rf "$root"
}

test_unreconcilable_project_is_flagged(){
  echo "# merge: an omp record whose session file is gone is flagged, never guessed"
  local root; root=$(setup)
  rm -f "$root/store/omp/-sites/o.jsonl"   # session pruned since the run
  run_merge "$root" || no "merge exited non-zero"
  assert_eq "$(jq -r '.project_unreconciled' "$(mdir "$root")/bbbbbbbbbbbb.json")" "true" \
    "the record is marked unreconciled"
  assert_grep "$(mdir "$root")/run-stats.txt" 'records_unreconciled_project: 1' \
    "the self-audit counts it, so a split group is visible"
  rm -rf "$root"
}

# A findings record written by a SOURCE-AWARE runner: cc-autodream stamps `source` itself
# as of its per-source triage work, so a findings dir is no longer guaranteed to be
# single-source. The pilot dir that triaged both harnesses in one run is exactly this.
mk_finding_src(){ # $1=dir $2=hash $3=session_path $4=project $5=source
  mkdir -p "$1"
  printf '{"session_path":"%s","project":"%s","source":"%s","findings":[{"category":"tool_loop","severity":"low"}]}\n' \
    "$3" "$4" "$5" > "$1/$2.json"
}

test_record_source_wins_over_dir_label(){
  echo "# collect: a record that declares its own source keeps it"
  local root; root=$(setup)
  # A Claude-sourced record sitting in a dir passed as :omp. Blanket-stamping it `omp`
  # would then send it through omp reconciliation, which reads an OMP session header it
  # does not have - so it lands flagged, and the report attributes Claude work to OMP.
  mk_finding_src "$root/omp/findings/$DATE" cccccccccccc "/store/claude/-Users-x-sites/m.jsonl" "-Users-x-sites" claude
  run_merge "$root" || no "merge exited non-zero"
  assert_eq "$(jq -r .source "$(mdir "$root")/cccccccccccc.json")" "claude" \
    "the record's own source is kept, not the directory's label"
  assert_nogrep "$(mdir "$root")/cccccccccccc.json" 'project_unreconciled' \
    "and it is not run through omp reconciliation"
  rm -rf "$root"
}

test_mixed_dir_is_reported(){
  echo "# collect: a mixed findings dir is auditable, not silent"
  local root; root=$(setup)
  mk_finding_src "$root/omp/findings/$DATE" cccccccccccc "/store/claude/-Users-x-sites/m.jsonl" "-Users-x-sites" claude
  run_merge "$root" || no "merge exited non-zero"
  assert_grep "$root/merge.out" 'carried their own source' "the log names the self-declared records"
  assert_grep "$(mdir "$root")/run-stats.txt" 'records_source_self_declared: 1' \
    "the self-audit counts them"
  assert_grep "$(mdir "$root")/run-stats.txt" 'records_source_mismatch: 1' \
    "and counts the ones that disagreed with the :source given"
  rm -rf "$root"
}

[ -x "$MERGE" ] || { echo "FATAL: $MERGE not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
echo "autodream-merge tests"
test_merges_both_sources
test_reconciles_project_identity
test_rerun_is_idempotent
test_real_collision_is_kept_and_counted
test_unreconcilable_project_is_flagged
test_record_source_wins_over_dir_label
test_mixed_dir_is_reported
echo "----------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
