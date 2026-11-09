#!/bin/zsh
# ralph-telemetry.sh — Optional OpenTelemetry-shaped telemetry for Ralph.
#
# Telemetry is off by default. It is enabled only when the env var
# RALPH_OTEL_FILE names a JSONL output file in an existing directory.
# When disabled (or python3 is unavailable), every function below is a
# pure no-op: no file is created, no exception is raised, and the
# caller's exit codes are never altered.
#
# Bash/zsh have no OpenTelemetry SDK here, so spans are written
# directly as JSONL records in the shared AEP telemetry contract —
# field-for-field identical to the _JsonlExporter._record output of
# AEP's tools/ghg/telemetry.py (the contract is the record shape, not
# the SDK):
#
#   name, trace_id (32-hex), span_id (16-hex), parent_span_id
#   (16-hex or null), start_time / end_time (epoch ns ints),
#   status (UNSET / OK / ERROR), attributes
#
# Spans carry ONLY allowlisted attributes (see _RALPH_TEL_ALLOWED_ATTRS):
# never argv, never resolved env values, never tokens. Every attribute
# passes through ralph_telemetry_set, which is the one and only
# attribute-setting path; the writer (lib/ralph-telemetry.py)
# deliberately does not re-filter, so this path is the sole guard
# against leaks — the same discipline as ghg's handle/exporter split.
#
# Span model: ralph_telemetry_session_start opens a root "session"
# span for one ralph_run_loop invocation; iteration / task_pick /
# gate_check spans nest under it via the span stack. The session span
# is closed by ralph_telemetry_session_end (wired into the loop's
# EXIT trap), so every exit path ends it exactly once.
#
# Implementation note: per-span attributes are kept as a "key=value"
# token string on the span stack. Attribute values in this adapter
# are single tokens by construction (operation names, agent keys,
# task keys, numbers, verdict words) — the same values the loop
# itself handles as words.

# ─── Allowlist ───────────────────────────────────────────────────────────────
# Contract set (operation, actor, exit_code, duration_ms, gate_verdict)
# plus ralph's one pinned per-runtime identifier: task_id.
typeset -ga _RALPH_TEL_ALLOWED_ATTRS=( operation actor exit_code duration_ms gate_verdict task_id )

# ─── State ───────────────────────────────────────────────────────────────────
typeset -g  _RALPH_TEL_ACTIVE=0
typeset -g  _RALPH_TEL_FILE=""
typeset -g  _RALPH_TEL_TRACE_ID=""
typeset -g  _RALPH_TEL_ACTOR=""
typeset -ga _RALPH_TEL_STACK_IDS=()
typeset -ga _RALPH_TEL_STACK_START=()
typeset -ga _RALPH_TEL_STACK_OPS=()
typeset -ga _RALPH_TEL_STACK_ATTRS=()

# Resolve the writer + a python3 interpreter once, at source time.
# This block must NEVER fail the sourcing shell: bin/ralph runs with
# `set -e` and both loop entry points source this file, so a non-zero
# status here would abort every loop at load time. A missing python3
# is not an error — it simply leaves telemetry disabled (the `|| true`
# below keeps the discovery substitution's status at 0, and
# ralph_telemetry_session_start refuses to activate without an
# interpreter). Python is not otherwise required by the loops.
_ralph_tel_lib_dir="${0:A:h}"
[[ -z "$_ralph_tel_lib_dir" || ! -d "$_ralph_tel_lib_dir" ]] && _ralph_tel_lib_dir="$RALPH_HOME/lib"
typeset -g _RALPH_TEL_WRITER="$_ralph_tel_lib_dir/ralph-telemetry.py"
typeset -g _RALPH_TEL_PYTHON=""
_ralph_tel_python_candidate="$(command -v python3 2>/dev/null || true)"
[[ -n "$_ralph_tel_python_candidate" && -f "$_RALPH_TEL_WRITER" ]] && _RALPH_TEL_PYTHON="$_ralph_tel_python_candidate"

# ─── Primitives ──────────────────────────────────────────────────────────────

# Epoch nanoseconds as an integer (GNU date; python3 fallback).
_ralph_tel_now_ns() {
  local ns
  ns="$(date +%s%N 2>/dev/null)"
  if [[ "$ns" == <-> ]]; then
    echo "$ns"
    return 0
  fi
  if [[ -n "$_RALPH_TEL_PYTHON" ]]; then
    "$_RALPH_TEL_PYTHON" -c 'import time; print(time.time_ns())' 2>/dev/null || echo 0
  else
    echo 0
  fi
  return 0
}

# Random hex string of exactly <nbytes>*2 hex chars.
_ralph_tel_hex() {
  local nbytes="$1" hex=""
  hex="$(od -An -N"$nbytes" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  if [[ ${#hex} -ne $(( nbytes * 2 )) ]]; then
    # Fallback: mix pid/time/RANDOM (ids only need uniqueness, not secrecy)
    hex=""
    while (( ${#hex} < nbytes * 2 )); do
      hex+=$(printf '%08x' $(( RANDOM * 32768 + RANDOM + $$ )) )
    done
    hex="${hex[1, $(( nbytes * 2 ))]}"
  fi
  echo "$hex"
  return 0
}

_ralph_tel_depth() {
  echo ${#_RALPH_TEL_STACK_IDS[@]}
  return 0
}

# ─── The one and only attribute-setting path ─────────────────────────────────
# ralph_telemetry_set <key> <value>
# Records an attribute on the current (innermost) span, if the key is
# allowlisted. Non-allowlisted keys are dropped silently. No-op when
# telemetry is inactive or no span is open. Always returns 0.
ralph_telemetry_set() {
  (( _RALPH_TEL_ACTIVE )) || return 0
  local key="${1:-}" value="${2:-}"
  [[ -n "$key" ]] || return 0
  local depth=${#_RALPH_TEL_STACK_IDS[@]}
  (( depth > 0 )) || return 0
  # Single filter: the allowlist check. Removing it turns the canary
  # test (tests/test-telemetry.sh) red — that is intentional.
  (( ${_RALPH_TEL_ALLOWED_ATTRS[(Ie)$key]} )) || return 0
  # Store as a key=value token on this span's token string, replacing
  # any earlier value for the same key.
  local cur="${_RALPH_TEL_STACK_ATTRS[depth]}"
  if [[ " $cur " == *" ${key}="* ]]; then
    local -a kept=()
    local tok
    for tok in ${=cur}; do
      [[ "$tok" == "${key}="* ]] || kept+=( "$tok" )
    done
    kept+=( "${key}=${value}" )
    _RALPH_TEL_STACK_ATTRS[depth]="${(j: :)kept}"
  elif [[ -n "$cur" ]]; then
    _RALPH_TEL_STACK_ATTRS[depth]="$cur ${key}=${value}"
  else
    _RALPH_TEL_STACK_ATTRS[depth]="${key}=${value}"
  fi
  return 0
}

# ─── Span lifecycle ──────────────────────────────────────────────────────────

# ralph_telemetry_start_span <operation>
# Pushes a span named "ralph.<operation>" onto the stack, parented to
# the span below it (the session span for top-level spans). Sets the
# operation + actor attributes through the filter path. No-op when
# inactive. Always returns 0.
ralph_telemetry_start_span() {
  (( _RALPH_TEL_ACTIVE )) || return 0
  local operation="${1:-span}"
  _RALPH_TEL_STACK_IDS+=( "$(_ralph_tel_hex 8)" )
  _RALPH_TEL_STACK_START+=( "$(_ralph_tel_now_ns)" )
  _RALPH_TEL_STACK_OPS+=( "$operation" )
  _RALPH_TEL_STACK_ATTRS+=( "" )
  ralph_telemetry_set operation "$operation"
  [[ -n "$_RALPH_TEL_ACTOR" ]] && ralph_telemetry_set actor "$_RALPH_TEL_ACTOR"
  return 0
}

# ralph_telemetry_end_span <exit_code> [gate_verdict] [status]
# Closes the innermost span: records exit_code, duration_ms and
# gate_verdict through the filter path (verdict defaults to
# "not_evaluated", mirroring ghg's finish semantics — a verdict is
# never derived from the exit code), then appends the contract record
# via the writer. No-op when no span is open. Always returns 0.
# (Note: the status parameter is named span_status — zsh reserves
# `status` as a read-only special variable.)
ralph_telemetry_end_span() {
  (( _RALPH_TEL_ACTIVE )) || return 0
  local depth=${#_RALPH_TEL_STACK_IDS[@]}
  (( depth > 0 )) || return 0
  local exit_code="${1:-0}"
  local verdict="${2:-not_evaluated}"
  local span_status="${3:-UNSET}"
  local end_ns
  end_ns="$(_ralph_tel_now_ns)"
  local start_ns="${_RALPH_TEL_STACK_START[depth]}"
  local span_id="${_RALPH_TEL_STACK_IDS[depth]}"
  local operation="${_RALPH_TEL_STACK_OPS[depth]}"
  local parent_id=""
  (( depth > 1 )) && parent_id="${_RALPH_TEL_STACK_IDS[depth-1]}"

  ralph_telemetry_set exit_code "$exit_code"
  local duration_ms
  duration_ms="$(printf '%.3f' $(( (end_ns - start_ns) / 1000000.0 )) 2>/dev/null)"
  ralph_telemetry_set duration_ms "${duration_ms:-0.000}"
  ralph_telemetry_set gate_verdict "$verdict"

  local -a writer_args=(
    --file "$_RALPH_TEL_FILE"
    --name "ralph.${operation}"
    --trace-id "$_RALPH_TEL_TRACE_ID"
    --span-id "$span_id"
    --parent-span-id "$parent_id"
    --start-ns "$start_ns"
    --end-ns "$end_ns"
    --status "$span_status"
  )
  local tok
  for tok in ${=_RALPH_TEL_STACK_ATTRS[depth]}; do
    writer_args+=( --attr "$tok" )
  done

  _RALPH_TEL_STACK_IDS[depth]=()
  _RALPH_TEL_STACK_START[depth]=()
  _RALPH_TEL_STACK_OPS[depth]=()
  _RALPH_TEL_STACK_ATTRS[depth]=()

  if [[ -n "$_RALPH_TEL_PYTHON" ]]; then
    "$_RALPH_TEL_PYTHON" "$_RALPH_TEL_WRITER" "${writer_args[@]}" >/dev/null 2>&1 || true
  fi
  return 0
}

# ralph_telemetry_instant_span <operation> <exit_code> <gate_verdict> [task_id]
# Emits a point span (used for gate/verdict points). No-op when
# inactive. Always returns 0.
ralph_telemetry_instant_span() {
  (( _RALPH_TEL_ACTIVE )) || return 0
  ralph_telemetry_start_span "${1:-span}"
  [[ -n "${4:-}" ]] && ralph_telemetry_set task_id "$4"
  ralph_telemetry_end_span "${2:-0}" "${3:-not_evaluated}"
  return 0
}

# ralph_telemetry_gate <gate_verdict> [task_id]
# Convenience wrapper for the gated loop's gate points.
ralph_telemetry_gate() {
  ralph_telemetry_instant_span "gate_check" 0 "${1:-not_evaluated}" "${2:-}"
  return 0
}

# ─── Session lifecycle ───────────────────────────────────────────────────────

# ralph_telemetry_session_start <agent_key> <instance_num>
# Opens the root session span if (and only if) telemetry is enabled:
# RALPH_OTEL_FILE set, its parent directory exists, python3 + writer
# available (mirrors ghg's "unusable path -> no-op" rule). Otherwise
# the whole subsystem stays inactive. Always returns 0.
ralph_telemetry_session_start() {
  (( _RALPH_TEL_ACTIVE )) && return 0
  local file="${RALPH_OTEL_FILE:-}"
  [[ -n "$file" ]] || return 0
  [[ -n "$_RALPH_TEL_PYTHON" ]] || return 0
  local parent_dir="${file:h}"
  [[ -n "$parent_dir" && -d "$parent_dir" ]] || return 0
  _RALPH_TEL_FILE="$file"
  _RALPH_TEL_TRACE_ID="$(_ralph_tel_hex 16)"
  _RALPH_TEL_ACTOR="${1:-ralph}"
  _RALPH_TEL_ACTIVE=1
  ralph_telemetry_start_span "session"
  return 0
}

# ralph_telemetry_session_end [exit_code]
# Closes any leaked inner spans, then the session span itself, with
# the run's exit code. Idempotent; no-op when inactive. Wired into the
# loop's EXIT trap so every exit path ends the session exactly once.
ralph_telemetry_session_end() {
  (( _RALPH_TEL_ACTIVE )) || return 0
  local exit_code="${1:-0}"
  local span_status="UNSET"
  (( exit_code != 0 )) && span_status="ERROR"
  while (( ${#_RALPH_TEL_STACK_IDS[@]} > 1 )); do
    ralph_telemetry_end_span "$exit_code" "not_evaluated" "$span_status"
  done
  ralph_telemetry_end_span "$exit_code" "not_evaluated" "$span_status"
  _RALPH_TEL_ACTIVE=0
  _RALPH_TEL_TRACE_ID=""
  _RALPH_TEL_ACTOR=""
  return 0
}
