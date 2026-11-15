#!/usr/bin/env bash
# Executes action.yml's run script the way GitHub does (bash -e -o pipefail),
# with a stub `mutineer` that writes a fixture JSON report and exits as told.
# Run via test/action_harness_test.rb, which asserts the scenario outcomes.
# Needs: bash, git, jq, ruby (the wrapper skips when a tool is missing).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

ruby -ryaml -e 'puts YAML.load_file("'"$ROOT"'/action.yml").dig("runs","steps",1,"run")' > "$SCRATCH/step.sh"

# Fixture: newline token, comma+colon in a path (escaping checks).
cat > "$SCRATCH/report.json" <<'JSON'
{"schema_version":"1.2","summary":{"total":10,"killed":6,"survived":2,"no_coverage":1,"uncapturable":0,"skipped_invalid":0,"errored":0,"timeout":0,"ignored":1,"attempted":8,"no_verdict":0,"score":75.0,"scoped":false},"survivors":[{"subject":"Calc#add","file":"lib/we,ird:name.rb","line":12,"operator":"arithmetic","id":"abc123def456","token":"+","diff":"d"},{"subject":"Calc#sub","file":"lib/calc.rb","line":20,"operator":"comparison","id":"fff000111222","token":"<\n100%","diff":"d"}],"baseline":{"regressed":true,"score_before":80.0,"score_after":75.0,"score_dropped":true,"score_comparable":true,"new_survivors":[{"subject":"Calc#add","file":"lib/calc.rb","line":12,"operator":"arithmetic","id":"abc123def456","token":"+"}],"fixed_survivors":[]}}
JSON
sed 's/"scoped":false/"scoped":true/; s/"score_comparable":true/"score_comparable":false/' "$SCRATCH/report.json" > "$SCRATCH/report-scoped.json"
sed 's/"scoped":false/"scoped":false,"id_format":2,"legacy_id_matches":{"ignore":2,"baseline":3}/' "$SCRATCH/report.json" > "$SCRATCH/report-legacy.json"

mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/mutineer" <<STUB
#!/usr/bin/env bash
# The action's version-floor check asks for --version before running.
if [ "\${1:-}" = "--version" ]; then echo "1.0.0"; exit 0; fi
# The action asks \`mutineer config KEY\` for resolved settings (#394).
# STUB_CONFIG unset: answer with this checkout's real CLI. "old": act as a
# release without the command. Any other value: print that value.
if [ "\${1:-}" = "config" ]; then
  case "\${STUB_CONFIG:-}" in
    "") exec ruby -I"$ROOT/lib" "$ROOT/bin/mutineer" "\$@" ;;
    old) echo "mutineer: unknown command 'config'" >&2; exit 2 ;;
    *) echo "\$STUB_CONFIG"; exit 0 ;;
  esac
fi
echo "STUB-ARGS: \$*" >> "$SCRATCH/stub-args.txt"
out=""
prev=""
for a in "\$@"; do [ "\$prev" = "--output" ] && out="\$a"; prev="\$a"; done
if [ "\${STUB_WRITE:-1}" = "1" ] && [ -n "\$out" ]; then cp "\${STUB_REPORT:-$SCRATCH/report.json}" "\$out"; fi
exit "\${STUB_EXIT:-1}"
STUB
chmod +x "$SCRATCH/bin/mutineer"
export PATH="$SCRATCH/bin:$PATH"

git init -q --bare -b main "$SCRATCH/upstream.git"
# Both repos set maintenance.auto in their own config (#174): a push runs it
# in upstream.git, and run_step's `env -i` drops the caller's GIT_CONFIG_* env.
git -C "$SCRATCH/upstream.git" config maintenance.auto false
mkdir -p "$SCRATCH/repo" && cd "$SCRATCH/repo"
git init -q -b main
git config maintenance.auto false
git config user.email "harness@test" && git config user.name "harness"
git commit -q --allow-empty -m x
git remote add origin "$SCRATCH/upstream.git" && git push -q origin main

run_step() { # name, then env overrides as KEY=VAL...
  local name=$1; shift
  local out="$SCRATCH/$name"
  mkdir -p "$out"
  : > "$SCRATCH/stub-args.txt"
  # env -i drops the suite's trace2 overrides (#174), so pass them on.
  env -i PATH="$PATH" HOME="$HOME" GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 \
    SOURCES="lib/calc.rb" TESTS="" THRESHOLD="90" BASELINE="" BASELINE_EPSILON="" \
    OPERATORS="" FRAMEWORK="" STRATEGY="" JOBS="" RAILS="false" FORMAT="json" \
    OUTPUT="" EXTRA_ARGS="" USE_BUNDLER="false" SINCE="" WORKING_DIRECTORY="." \
    RUNNER_TEMP="$out" GITHUB_OUTPUT="$out/gh-output.txt" \
    GITHUB_STEP_SUMMARY="$out/summary.md" GITHUB_BASE_REF="" GITHUB_EVENT_NAME="" \
    STUB_EXIT=1 STUB_WRITE=1 \
    "$@" bash -e -o pipefail "$SCRATCH/step.sh" > "$out/stdout.txt" 2> "$out/stderr.txt"
  echo "$name: exit=$?"
  echo "  args: $(cat "$SCRATCH/stub-args.txt" 2>/dev/null)"
}

echo "== 1: failing run, default json (expects error annotations + escaped path + report output) =="
run_step case1
grep '::error' "$SCRATCH/case1/stdout.txt"
grep -A1 'report<<' "$SCRATCH/case1/gh-output.txt" | tail -1 | sed 's/^/  report: /' 
echo "  summary head: $(head -1 "$SCRATCH/case1/summary.md")"

echo; echo "== 1b: dropped copies (#374) =="
cat > "$SCRATCH/report-dropped.json" <<'JSON'
{"schema_version":"1.10","summary":{"total":1,"killed":0,"survived":1,"no_coverage":0,"ignored":0,"no_verdict":0,"score":0.0,"scoped":false,"dropped":2},"survivors":[{"subject":"G.kind","file":"lib/g.rb","line":2,"operator":"literal_mutation","id":"aaaaaaaaaaaa","token":".erb","diff":"d","copies":["bbbbbbbbbbbb"]}]}
JSON
run_step case1b STUB_REPORT="$SCRATCH/report-dropped.json" STUB_EXIT=1
grep -q 'Dropped: 2 repeat(s) of a kept mutant' "$SCRATCH/case1b/summary.md" && echo "  OK: dropped summary line" || echo "  FAIL: dropped summary line"
grep -q 'copies `bbbbbbbbbbbb`' "$SCRATCH/case1b/summary.md" && echo "  OK: dropped copy id on the survivor" || echo "  FAIL: copy id missing from the summary"
grep -q 'Copies: bbbbbbbbbbbb' "$SCRATCH/case1b/stdout.txt" && echo "  OK: dropped copy id on the annotation" || echo "  FAIL: copy id missing from the annotation"
grep -q 'Dropped:' "$SCRATCH/case1/summary.md" && echo "  FAIL: old report gained a dropped line" || echo "  OK: old report has no dropped line"

echo; echo "== 2: PASSING run (expects ::warning annotations, 'passed' summary) =="
run_step case2 STUB_EXIT=0
grep -q '::warning file=' "$SCRATCH/case2/stdout.txt" && echo "  OK: passing-run warnings" || echo "  FAIL: no warnings on passing run"
grep -q '::error' "$SCRATCH/case2/stdout.txt" && echo "  FAIL: errors on passing run" || echo "  OK: no errors on passing run"
echo "  summary head: $(head -1 "$SCRATCH/case2/summary.md")"

echo; echo "== 3: pull_request + event payload (expects --since <base.sha>) =="
BASE_SHA=$(git rev-parse HEAD)
printf '{"pull_request":{"base":{"sha":"%s"}}}' "$BASE_SHA" > "$SCRATCH/event.json"
run_step case3 GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main GITHUB_EVENT_PATH="$SCRATCH/event.json" STUB_REPORT="$SCRATCH/report-scoped.json"
grep -q -- "--since $BASE_SHA" "$SCRATCH/stub-args.txt" && echo "  OK: scoped to base.sha" || echo "  FAIL: base.sha not used"

echo; echo "== 3b: pull_request, no event payload (expects --since origin/main branch fallback) =="
run_step case3b GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main

echo; echo "== 4: pull_request_target (expects NO --since: full scan) =="
run_step case4 GITHUB_EVENT_NAME=pull_request_target GITHUB_BASE_REF=main

echo; echo "== 5: since=none on a PR (expects --no-since, NO --since) =="
run_step case5 GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main SINCE=none

echo; echo "== 6: caller output pre-exists (stale) + run dies before writing =="
mkdir -p "$SCRATCH/case6" && cp "$SCRATCH/report.json" "$SCRATCH/case6/stale-out.json"
run_step case6 STUB_EXIT=2 STUB_WRITE=0 OUTPUT="$SCRATCH/case6/stale-out.json"
[ -f "$SCRATCH/case6/stale-out.json" ] && echo "  OK: stale file NOT deleted (baseline-safe)" || echo "  FAIL: pre-existing file was deleted"
grep -q 'did not produce a report (exit 2)' "$SCRATCH/case6/summary.md" && echo "  OK: fallback summary line" || echo "  FAIL: no fallback line"
grep -q '## Mutineer' "$SCRATCH/case6/summary.md" && echo "  FAIL: stale summary rendered" || echo "  OK: no stale summary"
grep -q '::error file=' "$SCRATCH/case6/stdout.txt" && echo "  FAIL: stale annotations" || echo "  OK: no annotations"
grep -q 'report<<' "$SCRATCH/case6/gh-output.txt" && echo "  FAIL: report output points at stale file" || echo "  OK: no report output"

echo "  case3 baseline line: $(grep -o 'Baseline: .*' "$SCRATCH/case3/summary.md")"

echo; echo "== 7: WORKING_DIRECTORY ./sub (expects normalized file= prefix sub/...) =="
run_step case7 WORKING_DIRECTORY=./sub
grep -o 'file=[^,]*' "$SCRATCH/case7/stdout.txt" | head -2

echo; echo "== 8: extra-args smuggles --format (expects exit 2, mutineer never runs) =="
run_step case8 EXTRA_ARGS="--format human"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran despite the conflict" || echo "  OK: rejected before running"

echo; echo "== 8b: extra-args smuggles the --out abbreviation (expects exit 2) =="
run_step case8b EXTRA_ARGS="--out other.json"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: abbreviation bypassed the guard" || echo "  OK: abbreviation rejected"

echo; echo "== 9: caller output + passing run (expects delivered file + report= caller path) =="
mkdir -p "$SCRATCH/case9"
run_step case9 STUB_EXIT=0 OUTPUT="$SCRATCH/case9/out.json"
[ -s "$SCRATCH/case9/out.json" ] && echo "  OK: caller output delivered" || echo "  FAIL: caller output missing"
grep -A1 'report<<' "$SCRATCH/case9/gh-output.txt" | grep -q "case9/out.json" && echo "  OK: report output names caller path" || echo "  FAIL: report output wrong"

echo; echo "== 10: report counts old-format id matches (expects one old-format id warning) =="
run_step case10 STUB_REPORT="$SCRATCH/report-legacy.json"
grep 'title=Old-format mutant ids' "$SCRATCH/case10/stdout.txt"
[ "$(grep -c 'title=Old-format mutant ids' "$SCRATCH/case10/stdout.txt")" = "1" ] && echo "  OK: one old-format id warning" || echo "  FAIL: expected exactly one old-format id warning"
grep -q 'title=Old-format mutant ids' "$SCRATCH/case1/stdout.txt" && echo "  FAIL: old-format id warning without legacy_id_matches" || echo "  OK: no old-format id warning when the report has no counts"

echo; echo "== 11: exit 1 with output and baseline as the same file (expects exit 2, file unchanged) =="
mkdir -p .mutineer
cp "$SCRATCH/report.json" .mutineer/baseline.json
ln -s baseline.json .mutineer/link.json
before=$(cksum .mutineer/baseline.json)
run_step case11 STUB_EXIT=1 OUTPUT=".mutineer/link.json" BASELINE="$(pwd)/.mutineer/baseline.json"
after=$(cksum .mutineer/baseline.json)
[ "$before" = "$after" ] && echo "  OK: same-file baseline kept" || echo "  FAIL: baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran despite the same file" || echo "  OK: same file rejected before running"
grep -q 'Refresh the baseline with the CLI' "$SCRATCH/case11/stdout.txt" && echo "  OK: same-file message names the CLI" || echo "  FAIL: missing same-file message"

echo; echo "== 11b: exit 1 with output a hard link of the baseline (expects exit 2) =="
mkdir -p "$SCRATCH/case11b"
cp "$SCRATCH/report.json" "$SCRATCH/case11b/baseline.json"
ln "$SCRATCH/case11b/baseline.json" "$SCRATCH/case11b/hard.json"
before=$(cksum "$SCRATCH/case11b/baseline.json")
run_step case11b STUB_EXIT=1 OUTPUT="$SCRATCH/case11b/hard.json" BASELINE="$SCRATCH/case11b/baseline.json"
after=$(cksum "$SCRATCH/case11b/baseline.json")
[ "$before" = "$after" ] && echo "  OK: hard-link baseline kept" || echo "  FAIL: hard-link baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran on a hard link" || echo "  OK: hard link rejected before running"

echo; echo "== 12: exit 1 with output and baseline as two files (expects the report copied) =="
mkdir -p "$SCRATCH/case12"
cp "$SCRATCH/report.json" "$SCRATCH/case12/baseline.json"
before=$(cksum "$SCRATCH/case12/baseline.json")
run_step case12 STUB_EXIT=1 OUTPUT="$SCRATCH/case12/out.json" BASELINE="$SCRATCH/case12/baseline.json"
after=$(cksum "$SCRATCH/case12/baseline.json")
[ "$before" = "$after" ] && echo "  OK: distinct baseline kept" || echo "  FAIL: distinct baseline changed"
[ -s "$SCRATCH/case12/out.json" ] && echo "  OK: distinct output delivered" || echo "  FAIL: distinct output missing"

echo; echo "== 13: baseline only in .mutineer.yml, output is that file (expects exit 2) =="
cat > .mutineer.yml <<'YAML'
baseline: .mutineer/baseline.json
YAML
before=$(cksum .mutineer/baseline.json)
run_step case13 STUB_EXIT=1 OUTPUT=".mutineer/baseline.json"
after=$(cksum .mutineer/baseline.json)
[ "$before" = "$after" ] && echo "  OK: yml baseline kept" || echo "  FAIL: yml baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran on a yml baseline" || echo "  OK: yml baseline rejected before running"

echo; echo "== 14: extra-args --baseline is the same file as output (expects exit 2) =="
mkdir -p "$SCRATCH/case14"
cp "$SCRATCH/report.json" "$SCRATCH/case14/baseline.json"
before=$(cksum "$SCRATCH/case14/baseline.json")
run_step case14 STUB_EXIT=1 OUTPUT="$SCRATCH/case14/baseline.json" EXTRA_ARGS="--baseline $SCRATCH/case14/baseline.json"
after=$(cksum "$SCRATCH/case14/baseline.json")
[ "$before" = "$after" ] && echo "  OK: extra-args baseline kept" || echo "  FAIL: extra-args baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran on extra-args baseline" || echo "  OK: extra-args baseline rejected before running"

echo; echo "== 14b: extra-args --base abbreviation is the same file (expects exit 2) =="
run_step case14b STUB_EXIT=1 OUTPUT="$SCRATCH/case14/baseline.json" EXTRA_ARGS="--base $SCRATCH/case14/baseline.json"
[ "$(cksum "$SCRATCH/case14/baseline.json")" = "$before" ] && echo "  OK: abbreviated baseline kept" || echo "  FAIL: abbreviated baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran on abbreviated baseline" || echo "  OK: abbreviated baseline rejected before running"

echo; echo "== 15: yml baseline and a different output (expects the report copied) =="
mkdir -p "$SCRATCH/case15"
before=$(cksum .mutineer/baseline.json)
run_step case15 STUB_EXIT=1 OUTPUT="$SCRATCH/case15/out.json"
after=$(cksum .mutineer/baseline.json)
[ "$before" = "$after" ] && echo "  OK: yml baseline left in place" || echo "  FAIL: yml baseline changed on a different output"
[ -s "$SCRATCH/case15/out.json" ] && echo "  OK: different output still delivered" || echo "  FAIL: different output was refused"

echo; echo "== 16: numeric baseline in .mutineer.yml is the same file as output (expects exit 2) =="
printf 'baseline: 123\n' > .mutineer.yml
cp "$SCRATCH/report.json" 123
before=$(cksum 123)
run_step case16 STUB_EXIT=1 OUTPUT="123"
after=$(cksum 123)
[ "$before" = "$after" ] && echo "  OK: numeric baseline kept" || echo "  FAIL: numeric baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran on a numeric baseline" || echo "  OK: numeric baseline rejected before running"

echo; echo "== 17: same-file path escapes percent and newline (expects exit 2) =="
mkdir -p "$SCRATCH/case17"
weird="$SCRATCH/case17/a%b"$'\n'"c.json"
cp "$SCRATCH/report.json" "$weird"
before=$(cksum "$weird")
run_step case17 STUB_EXIT=1 OUTPUT="$weird" BASELINE="$weird"
after=$(cksum "$weird")
[ "$before" = "$after" ] && echo "  OK: escaped-path baseline kept" || echo "  FAIL: escaped-path baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran on an escaped path" || echo "  OK: escaped path rejected before running"
grep '::error::' "$SCRATCH/case17/stdout.txt"

echo; echo "== 17b: same-file path that ends in a newline (expects exit 2) (#394 review) =="
mkdir -p "$SCRATCH/case17b"
trailing="$SCRATCH/case17b/same.json"$'\n'
cp "$SCRATCH/report.json" "$trailing"
before=$(cksum "$trailing")
run_step case17b STUB_EXIT=1 OUTPUT="$trailing" BASELINE="$trailing"
after=$(cksum "$trailing")
[ "$before" = "$after" ] && echo "  OK: trailing-newline baseline kept" || echo "  FAIL: trailing-newline baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran on a trailing-newline path" || echo "  OK: trailing-newline path rejected before running"

echo; echo "== 18: output under missing .mutineer cache dir (expects mkdir + delivered file) (#340) =="
rm -rf .mutineer
rm -f .mutineer.yml
run_step case18 STUB_EXIT=0 OUTPUT=".mutineer/pr.json"
[ -d .mutineer ] && echo "  OK: cache dir created" || echo "  FAIL: cache dir missing"
[ -s .mutineer/pr.json ] && echo "  OK: output delivered into fresh cache dir" || echo "  FAIL: output not delivered"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  OK: mutineer ran after mkdir" || echo "  FAIL: mutineer never ran"

echo; echo "== 18b: output under other missing dir still exits 2 (#340) =="
run_step case18b STUB_EXIT=0 OUTPUT="reports/pr.json"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran for a non-cache missing parent" || echo "  OK: non-cache missing parent rejected"
grep -q 'cannot write output' "$SCRATCH/case18b/stdout.txt" && echo "  OK: missing-dir error" || echo "  FAIL: missing-dir error absent"

echo; echo "== 18c: output under missing custom cache-dir from yml (#340) =="
printf 'cache_dir: mcache\n' > .mutineer.yml
run_step case18c STUB_EXIT=0 OUTPUT="mcache/pr.json"
[ -d mcache ] && echo "  OK: yml cache dir created" || echo "  FAIL: yml cache dir missing"
[ -s mcache/pr.json ] && echo "  OK: output delivered into yml cache dir" || echo "  FAIL: yml cache output missing"
rm -f .mutineer.yml

echo; echo "== 18i: cache dir whose name ends in a newline (#394 review) =="
printf 'cache_dir: "nlcache\\n"\n' > .mutineer.yml
nl_out="nlcache"$'\n'"/pr.json"
run_step case18i STUB_EXIT=0 OUTPUT="$nl_out"
[ -s "$nl_out" ] && echo "  OK: newline-ended cache dir created" || echo "  FAIL: newline-ended cache dir output missing"
[ -e nlcache ] && echo "  FAIL: created the cache dir without its newline" || echo "  OK: no truncated cache dir"
rm -f .mutineer.yml

echo; echo "== 18d: cache dir from extra-args, as two words (#340) =="
run_step case18d STUB_EXIT=0 OUTPUT="xcache/pr.json" EXTRA_ARGS="--cache-dir xcache"
[ -s xcache/pr.json ] && echo "  OK: extra-args cache dir created" || echo "  FAIL: extra-args cache dir output missing"

echo; echo "== 18e: cache dir from extra-args, with = (#340) =="
run_step case18e STUB_EXIT=0 OUTPUT="ecache/pr.json" EXTRA_ARGS="--cache-dir=ecache"
[ -s ecache/pr.json ] && echo "  OK: extra-args = cache dir created" || echo "  FAIL: extra-args = cache dir output missing"

echo; echo "== 18f: cache dir from a short extra-args form the CLI accepts (#340) =="
run_step case18f STUB_EXIT=0 OUTPUT="scache/pr.json" EXTRA_ARGS="--cache=scache"
[ -s scache/pr.json ] && echo "  OK: short-form cache dir created" || echo "  FAIL: short-form cache dir output missing"

echo; echo "== 18g: the CLI names the cache dir (#394) =="
run_step case18g STUB_EXIT=0 OUTPUT="zcache/pr.json" STUB_CONFIG="zcache"
[ -s zcache/pr.json ] && echo "  OK: CLI-named cache dir created" || echo "  FAIL: the action did not ask the CLI for cache_dir"

echo; echo "== 18h: an older CLI without the config command falls back (#394) =="
run_step case18h STUB_EXIT=0 OUTPUT="ocache/pr.json" EXTRA_ARGS="--cache=ocache" STUB_CONFIG="old"
[ -s ocache/pr.json ] && echo "  OK: fallback cache dir created" || echo "  FAIL: fallback cache dir output missing"

echo; echo "== 13b: the CLI names the baseline, output is that file (#394) =="
mkdir -p "$SCRATCH/case13b"
cp "$SCRATCH/report.json" "$SCRATCH/case13b/baseline.json"
before=$(cksum "$SCRATCH/case13b/baseline.json")
run_step case13b STUB_EXIT=1 OUTPUT="$SCRATCH/case13b/baseline.json" STUB_CONFIG="$SCRATCH/case13b/baseline.json"
[ "$(cksum "$SCRATCH/case13b/baseline.json")" = "$before" ] && echo "  OK: CLI-named baseline kept" || echo "  FAIL: CLI-named baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: the action did not ask the CLI for baseline" || echo "  OK: CLI-named baseline rejected before running"

echo; echo "== 14c: an older CLI without the config command, abbreviated baseline (#394) =="
before=$(cksum "$SCRATCH/case14/baseline.json")
run_step case14c STUB_EXIT=1 OUTPUT="$SCRATCH/case14/baseline.json" EXTRA_ARGS="--base $SCRATCH/case14/baseline.json" STUB_CONFIG="old"
[ "$(cksum "$SCRATCH/case14/baseline.json")" = "$before" ] && echo "  OK: fallback baseline kept" || echo "  FAIL: fallback baseline was replaced"
[ -s "$SCRATCH/stub-args.txt" ] && echo "  FAIL: mutineer ran on the fallback baseline" || echo "  OK: fallback baseline rejected before running"

# == 19: one table of unusual path names, run through every path input (#401) ==
# Each name goes through every input that takes a path. A row asserts the
# files and folders the Action leaves, not only its exit code. extra-args is
# split on whitespace by design, so names with a space or a newline skip the
# extra-args rows. A known gap prints TABLE-GAP while it fails, and FAIL once
# it passes, so the list cannot go stale.
echo; echo "== 19: unusual path names through every path input (#401) =="
rm -rf .mutineer .mutineer.yml
TABLE_LABELS=(space newline dash glob unicode tilde)
TABLE_NAMES=("sp ace" "nl"$'\n' "-dash" "gl*ob" "ünï" "~tl")
# " row/label=#issue " entries while a row still fails, space-separated.
KNOWN_GAPS=""
children() { ruby -e 'print Dir.children(".").sort.inspect'; }
CLEAN_TREE="$(children; printf .)"
why() { echo "$*" > "$SCRATCH/table-why"; return 1; }
# Runs one row, removes what it made, and checks that nothing else was left.
table_row() { # row, label, name, the row's function
  local row=$1 label=$2 name=$3 fn=$4 ok=0 gap=""
  : > "$SCRATCH/table-why"
  rm -rf "$SCRATCH/t"
  "$fn" "$name" > "$SCRATCH/table-row.log" 2>&1 || ok=1
  rm -rf -- "./$name" .mutineer.yml
  if [ "$ok" = 0 ] && [ "$(children; printf .)" != "$CLEAN_TREE" ]; then
    why "left a stray entry: $(children)"; ok=1
  fi
  rm -rf -- "${name%%[[:space:]]*}"
  case "$KNOWN_GAPS" in *" $row/$label="*) gap="${KNOWN_GAPS#*" $row/$label="}"; gap="${gap%% *}" ;; esac
  if [ "$ok" = 0 ] && [ -z "$gap" ]; then echo "  TABLE-OK: $row/$label"
  elif [ "$ok" = 0 ]; then echo "  FAIL: $row/$label passes now; remove it from KNOWN_GAPS ($gap)"
  elif [ -n "$gap" ]; then echo "  TABLE-GAP: $row/$label ($gap)"
  else echo "  FAIL: $row/$label: $(cat "$SCRATCH/table-why")"
  fi
}
baseline_rejected() { # name: the baseline is untouched and the run refused
  [ "$(cat -- "./$1")" = "{}" ] || why "baseline was replaced" || return
  [ -s "$SCRATCH/stub-args.txt" ] && { why "mutineer ran on a same-file baseline"; return; }
  grep -q 'are the same file' "$SCRATCH/t/stdout.txt" || why "no same-file error" || return
  case "$1" in
    *$'\n'*) grep -q '%0A' "$SCRATCH/t/stdout.txt" || why "same-file error dropped a newline" ;;
  esac
}

# output: a folder and a file with the name.
row_output() {
  mkdir -- "./$1"
  run_step t STUB_EXIT=0 OUTPUT="$1/$1"
  [ -s "./$1/$1" ] || why "report not delivered to output" || return
  local got
  got="$(ruby -e 'print File.read(ARGV[0])[/^report<<(\S+)\n(.*)\n\1$/m, 2], "."' "$SCRATCH/t/gh-output.txt")"
  [ "${got%.}" = "$(pwd -P)/$1/$1" ] || why "report= is not the output path"
}
# output under a missing cache folder that .mutineer.yml names.
row_yml_cache() {
  ruby -ryaml -e 'File.write(".mutineer.yml", {"cache_dir" => ARGV[0]}.to_yaml)' -- "$1"
  run_step t STUB_EXIT=0 OUTPUT="$1/pr.json"
  [ -s "./$1/pr.json" ] || why "cache folder not created or report not delivered"
}
# output under a missing cache folder that extra-args names.
row_args_cache() {
  run_step t STUB_EXIT=0 OUTPUT="$1/pr.json" EXTRA_ARGS="--cache-dir=$1"
  [ -s "./$1/pr.json" ] || why "cache folder not created or report not delivered"
}
# baseline input, output the same file.
row_baseline() {
  echo "{}" > "./$1"
  run_step t STUB_EXIT=1 OUTPUT="$1" BASELINE="$1"
  baseline_rejected "$1"
}
# baseline from .mutineer.yml, output the same file.
row_yml_baseline() {
  echo "{}" > "./$1"
  ruby -ryaml -e 'File.write(".mutineer.yml", {"baseline" => ARGV[0]}.to_yaml)' -- "$1"
  run_step t STUB_EXIT=1 OUTPUT="$1"
  baseline_rejected "$1"
}
# baseline from extra-args, output the same file.
row_args_baseline() {
  echo "{}" > "./$1"
  run_step t STUB_EXIT=1 OUTPUT="$1" EXTRA_ARGS="--baseline=$1"
  baseline_rejected "$1"
}
# working-directory: the annotation file= field keeps the escaped name.
row_workdir() {
  run_step t WORKING_DIRECTORY="$1"
  local want="${1//%/%25}"
  want="${want//$'\n'/ }"; want="${want//:/%3A}"; want="${want//,/%2C}"
  grep -qF -- "::error file=$want/lib/calc.rb,line=20," "$SCRATCH/t/stdout.txt" || why "annotation file= lost the name"
}

for i in "${!TABLE_NAMES[@]}"; do
  name="${TABLE_NAMES[$i]}" label="${TABLE_LABELS[$i]}"
  table_row output "$label" "$name" row_output
  table_row baseline "$label" "$name" row_baseline
  table_row yml-baseline "$label" "$name" row_yml_baseline
  table_row workdir "$label" "$name" row_workdir
  case "$name" in
    # A leading `~` is a home shortcut for cache_dir (CLI expand_path), not a
    # literal folder name under cwd, so the cache-dir rows do not apply.
    "~"*) echo "  TABLE-SKIP: yml-cache/$label, args-cache/$label (~ cache_dir is home-relative)" ;;
    *) table_row yml-cache "$label" "$name" row_yml_cache ;;
  esac
  case "$name" in
    *[[:space:]]*) echo "  TABLE-SKIP: args-cache/$label, args-baseline/$label (extra-args splits on whitespace)" ;;
    "~"*) table_row args-baseline "$label" "$name" row_args_baseline ;;
    *)
      table_row args-cache "$label" "$name" row_args_cache
      table_row args-baseline "$label" "$name" row_args_baseline
      ;;
  esac
done

# A cache directory and an output parent that differ only by a newline are
# not the same folder. Creating the parent would put the report beside the
# cache, not in it.
echo; echo "== 19b: cache dir and output parent differ by a newline =="
rm -rf .mutineer.yml plain $'plain\n'
ruby -ryaml -e 'File.write(".mutineer.yml", {"cache_dir" => "plain"}.to_yaml)'
run_step t19b STUB_EXIT=0 OUTPUT=$'plain\n/pr.json'
if [ -d $'plain\n' ] || [ -d plain ]; then
  echo "  FAIL: created a folder that is not the cache dir"
elif grep -q 'no such directory' "$SCRATCH/t19b/stdout.txt"; then
  echo "  OK: newline parent is not the cache dir"
else
  echo "  FAIL: expected a missing-directory error"
fi
ruby -ryaml -e 'File.write(".mutineer.yml", {"cache_dir" => ARGV[0]}.to_yaml)' -- $'plain\n'
run_step t19c STUB_EXIT=0 OUTPUT=$'plain\n/pr.json'
[ -s $'plain\n/pr.json' ] && echo "  OK: newline cache dir created" || echo "  FAIL: newline cache dir not created"
rm -rf -- plain $'plain\n' .mutineer.yml

# A missing dash-leading parent that is not the cache dir must exit 2 without
# creating the folder (ruby must see ARGV, not switches) (#401 OCR).
echo; echo "== 19d: dash-leading output parent is not the cache dir =="
rm -rf .mutineer.yml .mutineer -- -dash
run_step t19d STUB_EXIT=0 OUTPUT="-dash/pr.json"
if [ -d -- "-dash" ]; then
  echo "  FAIL: created a dash-leading folder that is not the cache dir"
elif grep -q 'no such directory' "$SCRATCH/t19d/stdout.txt"; then
  echo "  OK: dash-leading parent is not the cache dir"
else
  echo "  FAIL: expected a missing-directory error"
fi
rm -rf -- -dash .mutineer.yml

# Home-relative cache_dir (~/...) must still match an absolute output parent
# under that home (CLI expand_path semantics) (#401 cubic).
echo; echo "== 19e: home-relative cache_dir matches absolute output parent =="
rm -rf .mutineer.yml
fake_home="$SCRATCH/fake-home"
rm -rf "$fake_home"
mkdir -p "$fake_home"
ruby -ryaml -e 'File.write(".mutineer.yml", {"cache_dir" => "~/mcache"}.to_yaml)'
HOME="$fake_home" run_step t19e STUB_EXIT=0 OUTPUT="$fake_home/mcache/pr.json"
[ -s "$fake_home/mcache/pr.json" ] && echo "  OK: home-relative cache dir created" || echo "  FAIL: home-relative cache dir not created"
rm -rf "$fake_home" .mutineer.yml
