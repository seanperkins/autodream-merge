#!/bin/bash
# Combine the findings of two autodream installs — cc-autodream (Claude) and
# omp-autodream (OMP) — into ONE report for a date.
#
# Why this exists as a separate tool. Upstream split OMP support into its own repo
# (STRML/omp-autodream, ported 2026-08-17), which is the right call for the runners: each
# one's ingest, prompts and memory rules are harness-specific. But it costs the reader
# something real — a pattern with evidence in BOTH harnesses now lands in two reports, and
# neither of them can see it. Observed: a 2026-08-18 run ranked a `missed_skill` pattern
# whose evidence was one Claude session plus one OMP session; split across two reports,
# each half looks like a single-session curiosity.
#
# So this is a CONSUMER of both installs, not a third runner. It never reads a session
# store, never calls a model for triage, and neither repo needs to know it exists.
#
# Usage:
#   merge-reports.sh <date> <out-dir> <findings-dir>:<source> [<findings-dir>:<source> ...]
#   merge-reports.sh 2026-08-19 ~/.autodream-merged \
#       ~/.claude/autodream/findings/2026-08-19:claude \
#       ~/.omp/autodream/findings/2026-08-19:omp
#
# Phases:
#   merge      copy every findings record into one dir, stamp `source`, reconcile project
#              identity across harnesses, and sum the self-audit counters
#   aggregate  one L2 pass over the merged dir -> a single report (skip with --no-l2)
#
# The load-bearing part is project identity. cc-autodream and omp-autodream both derive
# `project` as basename(dirname(session_path)), which for Claude is the encoded cwd
# (`-Users-sean-sites`) and for OMP is the storage bucket (`-sites`). The same real
# directory therefore arrives under two different names, and a naive merge splits every
# project in half — the exact grouping failure this tool is supposed to remove. For OMP
# records we re-derive from the session file's own header `cwd`, encoded the way Claude
# encodes buckets, so both harnesses' work on one directory groups as one project.
#
# Memory is NOT written here, by design: `--tools Glob Read` only. An OMP-derived pin
# would land in a Claude memory store that OMP never reads, and the merged view is exactly
# where a cross-harness pattern is easiest to mis-attribute. The report is the deliverable.
set -uo pipefail

DATE="${1:-}"
OUT="${2:-}"
shift 2 2>/dev/null || true

[ -n "$DATE" ] && [ -n "$OUT" ] && [ "$#" -gt 0 ] || {
  echo "usage: $0 <date> <out-dir> <findings-dir>:<source> [...]" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || { echo "merge-reports: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "merge-reports: python3 required" >&2; exit 2; }

RUN_L2=1
CLI="${AUTODREAM_MERGE_BIN:-$HOME/.local/bin/claude}"
PROMPT="${AUTODREAM_MERGE_PROMPT:-$HOME/.claude/autodream/PROMPT.md}"
MODEL="${AUTODREAM_MERGE_MODEL:-claude-opus-4-7}"
ARGS=()
for a in "$@"; do
  case "$a" in
    --no-l2) RUN_L2=0 ;;
    *) ARGS+=("$a") ;;
  esac
done

MERGED="$OUT/findings/$DATE"
REPORT="$OUT/dreams/$DATE.md"
mkdir -p "$MERGED" "$OUT/dreams" "$OUT/logs" || exit 2
LOG="$OUT/logs/merge-$DATE.log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "merging into $MERGED"

# ---- Phase 1: collect ----
# Filenames are sha1-12 of the session path, so two installs reading different stores
# cannot collide. A collision would still be a silent overwrite, so it is checked rather
# than assumed: the count of copied records must equal the count of inputs.
copied=0; inputs=0; remerged=0; collisions=0; sources=""
for spec in "${ARGS[@]}"; do
  dir="${spec%:*}"; src="${spec##*:}"
  [ -d "$dir" ] || { log "SKIP (no such findings dir): $dir"; continue; }
  [ -n "$src" ] && [ "$src" != "$dir" ] || { log "SKIP (no :source suffix): $spec"; continue; }
  sources="${sources:+$sources,}$src"
  n=0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in *.stats.json) continue ;; esac
    inputs=$((inputs + 1))
    base="$(basename "$f")"
    dst="$MERGED/$base"
    # Filenames are sha1-12 of the session path, so a name already present is almost
    # always THIS session from an earlier run of this tool — re-running over an existing
    # merged dir must be idempotent, not 59 scary warnings with merged_records: 0 (the
    # first version did exactly that, and the aggregator noticed the zero before I did).
    # A genuine collision is two DIFFERENT session paths landing on one name; that must
    # never be silently overwritten, so it is kept, warned, and counted separately.
    if [ -e "$dst" ]; then
      prev_sp="$(jq -r '.session_path // ""' "$dst" 2>/dev/null)"
      cur_sp="$(jq -r '.session_path // ""' "$f" 2>/dev/null)"
      if [ -z "$cur_sp" ] || [ "$prev_sp" != "$cur_sp" ]; then
        collisions=$((collisions + 1))
        log "COLLISION: $base maps to two different sessions; keeping $prev_sp, skipping $cur_sp"
        continue
      fi
      remerged=$((remerged + 1))
    fi
    # Stamp the source from the directory it came from, never from the record: the
    # runners do not emit this field, and a merged record with no provenance is
    # unusable for the per-source rules the aggregator applies downstream.
    if jq --arg s "$src" '. + {source: $s}' "$f" > "$dst.tmp" 2>/dev/null && mv "$dst.tmp" "$dst"; then
      copied=$((copied + 1)); n=$((n + 1))
    else
      rm -f "$dst.tmp"
      log "WARNING: unparseable findings record skipped: $f"
    fi
    # Carry the stats sidecar when present; the aggregator treats its fields as
    # authoritative and recomputing them here would be a second source of truth.
    sc="${f%.json}.stats.json"
    [ -f "$sc" ] && cp "$sc" "$MERGED/" 2>/dev/null
  done
  log "collected $n record(s) from $dir (source=$src)"
done
log "merged $copied of $inputs record(s) ($remerged re-merged, $collisions collision(s)); sources: ${sources:-none}"

# ---- Phase 2: reconcile project identity ----
# Output is captured, not printed: the counts belong in the log next to everything else,
# and a bare "33 0" on stdout reads like a bug in a tool whose whole job is auditability.
RECON_OUT=$(python3 - "$MERGED" <<'PY'
import glob, json, os, sys

merged = sys.argv[1]
fixed = skipped = 0

def encode(cwd):
    # Claude's bucket encoding: every path separator becomes a dash, so /Users/sean/sites
    # -> -Users-sean-sites. Applied to an OMP session's header cwd it yields the same
    # name Claude would have used for that directory, which is what makes one project
    # out of two harnesses' work.
    return cwd.replace("/", "-")

def header_cwd(path):
    # Only the first lines are read: an OMP session header sits at the top, and these
    # files can be tens of MB.
    try:
        with open(path) as f:
            for _ in range(6):
                line = f.readline()
                if not line:
                    break
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if isinstance(e, dict):
                    if e.get("type") == "session" and e.get("cwd"):
                        return e["cwd"]
                    # A merged copy produced by an OMP ingest that normalizes first.
                    if e.get("type") == "autodream_meta" and e.get("cwd"):
                        return e["cwd"]
    except OSError:
        return None
    return None

for path in sorted(glob.glob(os.path.join(merged, "*.json"))):
    if path.endswith(".stats.json"):
        continue
    try:
        with open(path) as f:
            data = json.load(f)
    except (ValueError, OSError):
        continue
    if data.get("source") != "omp":
        continue  # Claude records already carry the encoded-cwd project name.
    sp = data.get("session_path")
    cwd = header_cwd(sp) if sp else None
    if not cwd:
        # Fail visibly rather than guessing: a wrong project name splits a group, and a
        # silent split is the failure this phase exists to prevent.
        data["project_unreconciled"] = True
        skipped += 1
    else:
        proj = encode(cwd)
        if data.get("project") != proj:
            data["project"] = proj
            fixed += 1
        else:
            continue
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)

print(f"{fixed} {skipped}")
PY
)
log "reconciled project from header cwd: $(printf '%s' "$RECON_OUT" | awk '{print $1" changed, "$2" unresolvable"}')"
read -r RECONCILED UNRECONCILED < <(
  python3 - "$MERGED" <<'PY'
import glob, json, os, sys
merged = sys.argv[1]
unrec = 0
projects = set()
for path in glob.glob(os.path.join(merged, "*.json")):
    if path.endswith(".stats.json"):
        continue
    try:
        d = json.load(open(path))
    except Exception:
        continue
    if d.get("project_unreconciled"):
        unrec += 1
    if d.get("project"):
        projects.add(d["project"])
print(len(projects), unrec)
PY
)
log "project identity: ${RECONCILED:-0} distinct project(s) after reconciliation, ${UNRECONCILED:-0} record(s) unreconciled"

# ---- Phase 3: combined self-audit ----
# Sum what sums, and keep each install's provenance line verbatim: a merged report whose
# self-audit hides which runner produced which half is not auditable.
{
  printf '# Autodream MERGED run self-audit — %s\n' "$DATE"
  printf 'merged_sources: %s\n' "${sources:-none}"
  printf 'merged_records: %s\n' "$copied"
  printf 'merged_remerged: %s\n' "$remerged"
  printf 'merged_collisions: %s\n' "$collisions"
  printf 'records_unreconciled_project: %s\n' "${UNRECONCILED:-0}"
  for spec in "${ARGS[@]}"; do
    dir="${spec%:*}"; src="${spec##*:}"
    rs="$dir/run-stats.txt"
    [ -f "$rs" ] || continue
    printf '\n## source: %s (%s)\n' "$src" "$dir"
    cat "$rs"
  done
} > "$MERGED/run-stats.txt"

if [ "$RUN_L2" = "0" ]; then
  log "--no-l2: merged findings ready at $MERGED"
  exit 0
fi

# ---- Phase 4: one aggregation over the union ----
[ -x "$CLI" ] || { log "FATAL: aggregator CLI not executable: $CLI"; exit 1; }
[ -s "$PROMPT" ] || { log "FATAL: no L2 prompt at $PROMPT"; exit 1; }

CAPTURE="$MERGED/l2-capture.md"
{
  printf "Findings directory to aggregate (literal absolute path): %s\n" "$MERGED"
  printf "Print the report to stdout as your entire response. Write no files.\n\n"
  cat "$PROMPT"
} | "$CLI" \
  --print \
  --permission-mode bypassPermissions \
  --model "$MODEL" \
  --no-session-persistence \
  --tools Glob Read \
  --disable-slash-commands \
  --strict-mcp-config \
  --settings '{"disableAllHooks":true}' \
  --append-system-prompt "Headless MERGED aggregator. These findings come from TWO harnesses; every record carries a \`source\` field (\`claude\` or \`omp\`). Judge each session by its own harness — an OMP session has no .claude/settings.json, no RETRY-BUDGET rules loaded, and its memory store is mnemopi, so all-zero compliance_markers there is descriptive, never drift. Rank a pattern higher when its evidence spans BOTH sources: that is the signal neither single-harness report can see, and the reason this merged pass exists. You have no Write or Edit tool: print the complete report, including the autodream:open-questions marker, to stdout and make no memory edits." \
  > "$CAPTURE" 2> "$MERGED/l2.err"
L2_RC=$?

if [ -s "$CAPTURE" ] && grep -q 'autodream:open-questions=' "$CAPTURE"; then
  mv "$CAPTURE" "$REPORT"
  log "merged report: $REPORT ($(wc -c < "$REPORT" | tr -d ' ') bytes)"
else
  log "WARNING: aggregation produced no complete report (exit $L2_RC); capture kept at $CAPTURE"
  exit 1
fi
exit 0
