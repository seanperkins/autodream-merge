# autodream-merge

Combine the findings of two [autodream](https://github.com/STRML/cc-autodream) installs —
[cc-autodream](https://github.com/STRML/cc-autodream) (Claude Code) and
[omp-autodream](https://github.com/STRML/omp-autodream) (Oh My Pi) — into **one** report per date.

## Why

Upstream split OMP support into its own repo, which is right for the runners: each one's
session ingest, prompts and memory rules are genuinely harness-specific. But it costs the
reader something real — **a pattern with evidence in both harnesses lands in two reports,
and neither of them can see it.**

Observed on a real 2026-08-18 corpus (21 Claude sessions + 33 OMP sessions). One merged
aggregation ranked a pattern that neither single-harness report contained:

```
### missed_skill (cross-source: skill invoked once, then agent went manual)
**Count**: 2 findings across 2 sessions — 1 claude + 1 omp   <- the merged-only signal
```

Split across two reports, each half is a single-session curiosity that ranks nowhere.

## What it is not

A **consumer** of both installs, not a third runner. It never reads a session store, never
calls a model for triage, and **neither repo needs to know it exists**. Both stay
independently useful; this only adds a view.

## Usage

```sh
merge-reports.sh <date> <out-dir> <findings-dir>:<source> [<findings-dir>:<source> ...]

merge-reports.sh 2026-08-19 ~/.autodream-merged \
    ~/.claude/autodream/findings/2026-08-19:claude \
    ~/.omp/autodream/findings/2026-08-19:omp
```

Writes `<out-dir>/dreams/<date>.md`, the merged findings dir at
`<out-dir>/findings/<date>/`, and a log at `<out-dir>/logs/merge-<date>.log`.

`--no-l2` runs the merge phases and stops — artifacts only, no model call. This is what the
test suite uses.

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `AUTODREAM_MERGE_BIN` | `$HOME/.local/bin/claude` | CLI that runs the single aggregation |
| `AUTODREAM_MERGE_PROMPT` | `$HOME/.claude/autodream/PROMPT.md` | L2 prompt to reuse |
| `AUTODREAM_MERGE_MODEL` | `claude-opus-4-7` | aggregator model |

## The load-bearing part: project identity

Both runners derive `project` as `basename(dirname(session_path))`. For Claude that is the
encoded cwd (`-Users-sean-sites`); for OMP it is the storage bucket (`-sites`). **The same
real directory therefore arrives under two different names**, and a naive merge splits
every shared project in half — precisely the grouping failure this tool exists to remove.

For OMP records the project is re-derived from the session file's own header `cwd`, encoded
the way Claude encodes buckets, so both harnesses' work on one directory groups as one
project. Measured on the real corpus: **17 apparent projects reconcile to 8 real ones**,
byte-identical to the ground truth from a single dual-source run.

### Source precedence

A record's own `source` field wins; the `:source` suffix is only a default for records
that lack one. cc-autodream stamps `source` itself as of its per-source triage work, so a
findings dir is **not** guaranteed to be single-source — the pilot dir that triaged both
harnesses in one run is exactly that. Blanket-stamping such a dir sent 26 Claude records
through OMP reconciliation, where they had no OMP session header to read: they landed
flagged *and* attributed to the wrong harness in the report. `records_source_self_declared`
and `records_source_overridden` in the merged self-audit make a mixed dir visible.

Records that cannot be reconciled (session file since deleted, unreadable header) are
counted as `records_unreconciled` in the merged self-audit rather than silently guessed. A
split group stays visible.

## Deliberate non-goals

**No memory writes.** The aggregator runs with `--tools Glob Read` — no `Write`, no `Edit`.
An OMP-derived pin would otherwise land in a Claude memory store that OMP never reads, and
a merged view is exactly where a cross-harness pattern is easiest to mis-attribute. Each
install still owns its own memory. The report is the deliverable here.

**No session reading.** Session stores belong to the runners. The one exception is
read-only: an OMP session file's header `cwd`, needed for the reconciliation above.

## Recommended wiring

Set `AUTODREAM_L1_ONLY=1` on both nightlies so each install triages its own sessions and
skips its own aggregation, then run this once afterwards. That is one opus pass instead of
three, and the only pass that can see across both harnesses.

The flag ships in [cc-autodream#49](https://github.com/STRML/cc-autodream/pull/49) and
[omp-autodream#15](https://github.com/STRML/omp-autodream/pull/15). Until those land, both
installs write their own report and this tool is additive — worth a third opus pass only if
you want the cross-source ranking today.

Schedule it after both installs have finished, not on a fixed offset you hope is enough:
each findings dir carries a `l1-only` marker file once its L1 is complete.

## Requirements

`bash`, `jq`, `python3`. Tests need nothing else — no network, no model calls.

## Tests

```sh
tests/run-all.sh
```

31 assertions covering source stamping and precedence, cwd reconciliation, re-run stability (cross-dir overlap vs. idempotency, reported separately), genuine
filename collisions (kept, warned, counted separately from a re-merge), and unreconcilable
records. Every test runs with `--no-l2` and asserts on artifacts.

## License

MIT
