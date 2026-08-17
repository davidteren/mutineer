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
mkdir -p "$SCRATCH/repo" && cd "$SCRATCH/repo"
git init -q -b main
git config user.email "harness@test" && git config user.name "harness"
git commit -q --allow-empty -m x
git remote add origin "$SCRATCH/upstream.git" && git push -q origin main

run_step() { # name, then env overrides as KEY=VAL...
  local name=$1; shift
  local out="$SCRATCH/$name"
  mkdir -p "$out"
  : > "$SCRATCH/stub-args.txt"
  env -i PATH="$PATH" HOME="$HOME" \
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
grep -c '::warning file=' "$SCRATCH/case2/stdout.txt" | sed 's/^/  warning count: /'
grep -c '::error' "$SCRATCH/case2/stdout.txt" | sed 's/^/  error count: /' || true
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
