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


mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/mutineer" <<STUB
#!/usr/bin/env bash
# The action's version-floor check asks for --version before running.
if [ "\${1:-}" = "--version" ]; then echo "1.0.0"; exit 0; fi
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

echo; echo "== 10: exit 3 passes through (expects exit-code=3, no old-format warning) =="
run_step case10 STUB_EXIT=3
grep -q 'exit-code=3' "$SCRATCH/case10/gh-output.txt" && echo "  OK: exit-code output is 3" || echo "  FAIL: exit-code output is not 3"
grep -q 'title=Old-format mutant ids' "$SCRATCH/case10/stdout.txt" && echo "  FAIL: old-format id warning" || echo "  OK: no old-format id warning"
grep -q 'title=Old-format mutant ids' "$SCRATCH/case1/stdout.txt" && echo "  FAIL: old-format id warning on a normal report" || echo "  OK: no old-format id warning when the report has no counts"

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
