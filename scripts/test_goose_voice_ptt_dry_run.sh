#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOICE_SCRIPT="${ROOT_DIR}/scripts/goose-voice-ptt.sh"

if [[ ! -x "${VOICE_SCRIPT}" ]]; then
  echo "voice script not executable: ${VOICE_SCRIPT}" >&2
  exit 1
fi

PASS_COUNT=0
SKIP_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "✅ $1"
}

skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  echo "⏭️  $1"
}

can_use_macos_paste() {
  [[ "$(uname -s)" == "Darwin" ]] && command -v pbcopy >/dev/null 2>&1 && command -v osascript >/dev/null 2>&1
}

require_output_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "${label}: expected output to contain '${needle}'" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${haystack}" >&2
    echo "--------------" >&2
    exit 1
  fi
}

run_success_case() {
  local label="$1"
  shift

  local out
  out="$("$@" 2>&1)"
  echo "${out}" >/dev/null
  pass "${label}"
}

run_failure_case() {
  local label="$1"
  local expected_rc="$2"
  shift 2

  set +e
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  set -e

  if [[ "${rc}" -ne "${expected_rc}" ]]; then
    echo "${label}: expected rc ${expected_rc}, got ${rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  pass "${label}"
}

BASE_CMD=("${VOICE_SCRIPT}" --dry-run --provider command --transcribe-cmd cat)

# Default/file dry-run should succeed and keep file insertion.
DEFAULT_OUT="$("${BASE_CMD[@]}" 2>&1)"
require_output_contains "${DEFAULT_OUT}" "Insert mode: file -> file" "default dry-run"
require_output_contains "${DEFAULT_OUT}" "Min clip duration: 0.25s" "default dry-run"
pass "default dry-run (file mode)"

# Auto mode without tmux context should resolve to paste on supported macOS hosts, else file.
AUTO_OUT="$(${VOICE_SCRIPT} --dry-run --insert-mode auto --provider command --transcribe-cmd cat 2>&1)"
if can_use_macos_paste; then
  require_output_contains "${AUTO_OUT}" "Insert mode: auto -> paste" "auto dry-run"
  pass "auto insert-mode resolves to paste when macOS focused-app paste is available"

  PASTE_OUT="$(${VOICE_SCRIPT} --dry-run --insert-mode paste --provider command --transcribe-cmd cat 2>&1)"
  require_output_contains "${PASTE_OUT}" "Insert mode: paste -> paste" "paste dry-run"
  require_output_contains "${PASTE_OUT}" "Paste target: currently focused macOS app" "paste dry-run"
  require_output_contains "${PASTE_OUT}" "Accessibility (System Events):" "paste dry-run"
  pass "explicit paste mode dry-run succeeds on supported macOS hosts"

  PASTE_APP_OUT="$(${VOICE_SCRIPT} --dry-run --insert-mode paste --paste-app iTerm2 --provider command --transcribe-cmd cat 2>&1)"
  require_output_contains "${PASTE_APP_OUT}" "Paste target: iTerm2 (activated before paste)" "paste-app dry-run"
  pass "paste mode reports explicit --paste-app target"
else
  require_output_contains "${AUTO_OUT}" "Insert mode: auto -> file" "auto dry-run"
  pass "auto insert-mode resolves to file when no tmux/paste fast path is available"

  run_failure_case "explicit paste mode rejects unsupported hosts" 13 \
    "${VOICE_SCRIPT}" --dry-run --insert-mode paste --provider command --transcribe-cmd cat
fi

# Hold mode dry-run should surface preflight readiness details.
HOLD_OUT="$(${VOICE_SCRIPT} --dry-run --ptt-mode hold --provider command --transcribe-cmd cat 2>&1)"
require_output_contains "${HOLD_OUT}" "Hold preflight:" "hold dry-run"
pass "hold-mode dry-run reports preflight readiness"

if [[ "${HOLD_OUT}" == *"Hold preflight: unavailable"* ]]; then
  run_failure_case "hold-strict fails when preflight is unavailable" 10 \
    "${VOICE_SCRIPT}" --dry-run --ptt-mode hold --hold-strict --provider command --transcribe-cmd cat
else
  run_success_case "hold-strict dry-run succeeds when preflight is ready" \
    "${VOICE_SCRIPT}" --dry-run --ptt-mode hold --hold-strict --provider command --transcribe-cmd cat
fi

# Fixed-duration mode should bypass hold preflight even if --ptt-mode hold was provided.
FIXED_HOLD_OUT="$(${VOICE_SCRIPT} --dry-run --duration 2 --ptt-mode hold --provider command --transcribe-cmd cat 2>&1)"
require_output_contains "${FIXED_HOLD_OUT}" "Record mode: fixed (duration: 2s)" "fixed-duration dry-run"
require_output_contains "${FIXED_HOLD_OUT}" "Hold preflight: skipped (fixed-duration mode)" "fixed-duration dry-run"
pass "fixed-duration mode bypasses hold preflight checks"

# Invalid mode should fail fast with argument validation.
run_failure_case "invalid --ptt-mode is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --ptt-mode nope --provider command --transcribe-cmd cat

run_failure_case "invalid --mic-index is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --mic-index -1 --provider command --transcribe-cmd cat

run_failure_case "invalid --duration is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --duration 0 --provider command --transcribe-cmd cat

run_failure_case "invalid --max-duration is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --max-duration 0 --provider command --transcribe-cmd cat

run_failure_case "invalid --min-duration is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --min-duration -1 --provider command --transcribe-cmd cat

run_failure_case "--paste-app requires insert-mode paste|auto" 13 \
  "${VOICE_SCRIPT}" --dry-run --insert-mode file --paste-app iTerm2 --provider command --transcribe-cmd cat

if command -v tmux >/dev/null 2>&1; then
  # For tmux mode, missing session/target should fail with a clear code.
  run_failure_case "tmux mode requires TMUX session or --tmux-target" 13 \
    env -u TMUX "${VOICE_SCRIPT}" --dry-run --insert-mode tmux --provider command --transcribe-cmd cat

  TMUX_TARGET_OUT="$(env -u TMUX "${VOICE_SCRIPT}" --dry-run --insert-mode tmux --tmux-target dev:1.1 --provider command --transcribe-cmd cat 2>&1)"
  require_output_contains "${TMUX_TARGET_OUT}" "Insert mode: tmux -> tmux" "tmux target dry-run"
  require_output_contains "${TMUX_TARGET_OUT}" "tmux target: dev:1.1" "tmux target dry-run"
  pass "tmux dry-run succeeds with explicit --tmux-target"
else
  skip "tmux not installed; skipped tmux mode dry-run checks"
fi

echo
echo "Voice dry-run checks complete: ${PASS_COUNT} passed, ${SKIP_COUNT} skipped."
