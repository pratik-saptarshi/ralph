#!/bin/zsh
# test-telemetry.sh — Tests for lib/ralph-telemetry.sh (RALPH_OTEL_FILE spans)
#
# Verifies the shared AEP telemetry contract for the bash/zsh adapter:
#   (a) off (env unset)  = no file created, identical fixture behaviour
#   (b) on               = well-formed contract records, allowlisted
#                          attributes only, correct parent linkage
#   (c) canary           = a token-shaped value passed under
#                          non-allowlisted keys never reaches the file
#   (d) unusable path    = no-op, exit codes preserved
#   (e) EXIT-trap wiring = session span closed with the run's exit code
#
# Usage: zsh tests/test-telemetry.sh
#
# Note: no `set -e` here — scenarios deliberately run failing commands
# and non-zero exits; the harness counts failures instead.

RALPH_HOME="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"

# ─── Minimal test harness ────────────────────────────────────────────────────

_pass=0
_fail=0
_test_name=""

test_case() { _test_name="$1"; }

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-$_test_name}"
  if [[ "$actual" == "$expected" ]]; then
    _pass=$((_pass + 1))
    echo "  PASS: $msg"
  else
    _fail=$((_fail + 1))
    echo "  FAIL: $msg"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_file_absent() {
  if [[ ! -e "$1" ]]; then
    _pass=$((_pass + 1)); echo "  PASS: $_test_name (no file: $1)"
  else
    _fail=$((_fail + 1)); echo "  FAIL: $_test_name (unexpected file: $1)"
  fi
}

test_summary() {
  echo ""
  echo "Results: $_pass passed, $_fail failed"
  (( _fail > 0 )) && exit 1
  exit 0
}

# ─── Fixture ─────────────────────────────────────────────────────────────────

_TEL_TMP="$(mktemp -d)"

# A miniature loop-shaped run: session → pick (with a nested gate
# span) → iteration, exercising failing commands and explicit exit
# codes the way ralph_run_loop does. Prints a marker; returns 7.
_fixture_run() {
  source "$RALPH_HOME/lib/ralph-telemetry.sh"
  ralph_telemetry_session_start builder 1
  ralph_telemetry_start_span "task_pick"
  ralph_telemetry_gate "pass" "PROD-42"
  false
  local pick_rc=$?
  ralph_telemetry_set task_id "PROD-42"
  ralph_telemetry_end_span $pick_rc
  ralph_telemetry_start_span "iteration"
  ralph_telemetry_set task_id "PROD-42"
  ralph_telemetry_end_span 0 "complete"
  ralph_telemetry_session_end 7
  echo "fixture-done"
  return 7
}

# ─── (a) Off = no file, identical behaviour ──────────────────────────────────

echo "=== Telemetry off (RALPH_OTEL_FILE unset) ==="

test_case "off: fixture output + exit code, no file"
_off_target="$_TEL_TMP/off.jsonl"
out_off=$( ( export RALPH_OTEL_FILE="$_off_target"; unset RALPH_OTEL_FILE; _fixture_run ) 2>/dev/null )
rc_off=$?
assert_eq "$out_off" "fixture-done" "off: stdout"
# rc captured after assignment is the assignment's status; re-run for rc:
( unset RALPH_OTEL_FILE; _fixture_run ) >/dev/null 2>&1
rc_off=$?
assert_eq "$rc_off" "7" "off: exit code preserved (7)"
assert_file_absent "$_off_target"

echo ""
echo "=== Telemetry on: identical behaviour + records written ==="

test_case "on: fixture output + exit code unchanged"
_on_target="$_TEL_TMP/on.jsonl"
( export RALPH_OTEL_FILE="$_on_target"; _fixture_run ) >/dev/null 2>&1
rc_on=$?
assert_eq "$rc_on" "7" "on: exit code preserved (7)"
if [[ -s "$_on_target" ]]; then
  _pass=$((_pass + 1)); echo "  PASS: on: records file written"
else
  _fail=$((_fail + 1)); echo "  FAIL: on: records file written (missing/empty: $_on_target)"
fi

# ─── (b) Well-formed records, allowlist, linkage ─────────────────────────────

echo ""
echo "=== Record shape / allowlist / parent linkage ==="

test_case "records match the contract"
verdict=$(python3 - "$_on_target" <<'PYEOF'
import json, re, sys
path = sys.argv[1]
records = [json.loads(line) for line in open(path) if line.strip()]
assert len(records) == 4, f"expected 4 records, got {len(records)}"
keys = ["name", "trace_id", "span_id", "parent_span_id",
        "start_time", "end_time", "status", "attributes"]
allow = {"operation", "actor", "exit_code", "duration_ms",
         "gate_verdict", "task_id"}
by_name = {}
for r in records:
    assert list(r.keys()) == keys, f"key shape/order: {list(r.keys())}"
    assert re.fullmatch(r"[0-9a-f]{32}", r["trace_id"]), "trace_id shape"
    assert re.fullmatch(r"[0-9a-f]{16}", r["span_id"]), "span_id shape"
    assert r["parent_span_id"] is None or \
        re.fullmatch(r"[0-9a-f]{16}", r["parent_span_id"]), "parent shape"
    assert isinstance(r["start_time"], int) and r["start_time"] > 0
    assert isinstance(r["end_time"], int) and r["end_time"] >= r["start_time"]
    assert r["status"] in ("UNSET", "OK", "ERROR"), r["status"]
    assert set(r["attributes"]) <= allow, \
        f"non-allowlisted attrs: {set(r['attributes']) - allow}"
    assert isinstance(r["attributes"]["exit_code"], int), "exit_code typed int"
    assert isinstance(r["attributes"]["duration_ms"], float), "duration_ms typed float"
    by_name[r["name"]] = r
assert len({r["trace_id"] for r in records}) == 1, "one trace per session"
assert len({r["span_id"] for r in records}) == 4, "unique span ids"
s = by_name["ralph.session"]; p = by_name["ralph.task_pick"]
g = by_name["ralph.gate_check"]; i = by_name["ralph.iteration"]
assert s["parent_span_id"] is None, "session is the root"
assert p["parent_span_id"] == s["span_id"], "pick nests under session"
assert g["parent_span_id"] == p["span_id"], "gate nests under pick"
assert i["parent_span_id"] == s["span_id"], "iteration nests under session"
assert s["attributes"]["operation"] == "session"
assert s["attributes"]["actor"] == "builder"
assert s["attributes"]["exit_code"] == 7, "session carries run exit code"
assert s["attributes"]["gate_verdict"] == "not_evaluated"
assert s["status"] == "ERROR", "non-zero session exit -> ERROR status"
assert p["attributes"]["task_id"] == "PROD-42"
assert g["attributes"]["gate_verdict"] == "pass"
assert g["attributes"]["task_id"] == "PROD-42"
assert i["attributes"]["task_id"] == "PROD-42"
assert i["attributes"]["gate_verdict"] == "complete"
assert i["attributes"]["exit_code"] == 0
print("RECORDS_OK")
PYEOF
)
assert_eq "$verdict" "RECORDS_OK" "contract shape, allowlist, linkage, values"

# ─── (c) Canary ──────────────────────────────────────────────────────────────

echo ""
echo "=== Canary: token-shaped values under non-allowlisted keys ==="

test_case "canary never reaches the file"
_canary_target="$_TEL_TMP/canary.jsonl"
_canary="ghp_CANARY7f3d9a1b5eSECRET"
(
  export RALPH_OTEL_FILE="$_canary_target"
  export FAKE_GITHUB_TOKEN="$_canary"
  source "$RALPH_HOME/lib/ralph-telemetry.sh"
  ralph_telemetry_session_start builder 1
  ralph_telemetry_start_span "iteration"
  ralph_telemetry_set command_argv "$FAKE_GITHUB_TOKEN"
  ralph_telemetry_set env_value "prefix-${FAKE_GITHUB_TOKEN}"
  ralph_telemetry_set api_token "$FAKE_GITHUB_TOKEN"
  ralph_telemetry_set task_id "PROD-42"
  ralph_telemetry_end_span 0 "complete"
  ralph_telemetry_session_end 0
) >/dev/null 2>&1
if [[ -s "$_canary_target" ]] && ! grep -q "CANARY" "$_canary_target" \
   && ! grep -q "command_argv" "$_canary_target"; then
  _pass=$((_pass + 1)); echo "  PASS: canary absent, allowlisted records present"
else
  _fail=$((_fail + 1)); echo "  FAIL: canary leaked or records missing ($_canary_target)"
fi

# ─── (d) Unusable path = no-op ───────────────────────────────────────────────

echo ""
echo "=== Unusable output path ==="

test_case "missing parent dir: no file, no crash, exit preserved"
_bad_target="/nonexistent-dir-ralph-test-$$/t.jsonl"
( export RALPH_OTEL_FILE="$_bad_target"; _fixture_run ) >/dev/null 2>&1
rc_bad=$?
assert_eq "$rc_bad" "7" "unusable path: exit code preserved (7)"
assert_file_absent "$_bad_target"

# ─── (e) EXIT-trap session close (the ralph-loop.sh wiring pattern) ─────────

echo ""
echo "=== EXIT trap closes the session with the run's exit code ==="

test_case "trap: session record carries exit 3 + ERROR"
_trap_target="$_TEL_TMP/trap.jsonl"
(
  export RALPH_OTEL_FILE="$_trap_target"
  source "$RALPH_HOME/lib/ralph-telemetry.sh"
  ralph_telemetry_session_start builder 2
  trap 'ralph_telemetry_session_end $?' EXIT
  exit 3
) >/dev/null 2>&1
rc_trap=$?
assert_eq "$rc_trap" "3" "trap: process exit code untouched (3)"
trap_verdict=$(python3 - "$_trap_target" <<'PYEOF'
import json, sys
records = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(records) == 1, f"expected 1 session record, got {len(records)}"
r = records[0]
assert r["name"] == "ralph.session"
assert r["attributes"]["exit_code"] == 3, r["attributes"]
assert r["status"] == "ERROR"
print("TRAP_OK")
PYEOF
)
assert_eq "$trap_verdict" "TRAP_OK" "trap: session closed with exit 3"

# ─── Sourcing ralph-loop.sh defines telemetry, inactive by default ──────────

echo ""
echo "=== Loop integration surface ==="

test_case "ralph-loop.sh sources cleanly; telemetry present but inactive"
loop_probe=$(
  export RALPH_HOME
  unset RALPH_OTEL_FILE
  source "$RALPH_HOME/lib/ralph-loop.sh" 2>/dev/null
  if (( ${+functions[ralph_telemetry_session_start]} )) \
     && (( ${+functions[ralph_telemetry_gate]} )); then
    echo "DEFINED"
  else
    echo "MISSING"
  fi
)
assert_eq "$loop_probe" "DEFINED" "telemetry functions defined via ralph-loop.sh"

# ─── Cleanup & summary ───────────────────────────────────────────────────────

rm -rf "$_TEL_TMP"
test_summary
