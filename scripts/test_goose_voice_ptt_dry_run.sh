#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOICE_SCRIPT="${ROOT_DIR}/scripts/goose-voice-ptt.sh"
LAUNCH_SCRIPT="${ROOT_DIR}/scripts/goose-voice-ptt-launch.sh"
SESSION_LAUNCH_SCRIPT="${ROOT_DIR}/scripts/goose-voice-ptt-session.sh"
DOCS_FILE="${ROOT_DIR}/documentation/docs/guides/sessions/in-session-actions.md"

if [[ ! -x "${VOICE_SCRIPT}" ]]; then
  echo "voice script not executable: ${VOICE_SCRIPT}" >&2
  exit 1
fi

if [[ ! -x "${LAUNCH_SCRIPT}" ]]; then
  echo "launcher script not executable: ${LAUNCH_SCRIPT}" >&2
  exit 1
fi

if [[ ! -x "${SESSION_LAUNCH_SCRIPT}" ]]; then
  echo "session launcher script not executable: ${SESSION_LAUNCH_SCRIPT}" >&2
  exit 1
fi

if [[ ! -f "${DOCS_FILE}" ]]; then
  echo "voice docs file not found: ${DOCS_FILE}" >&2
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

require_file_equals() {
  local file_path="$1"
  local expected="$2"
  local label="$3"

  if [[ ! -f "${file_path}" ]]; then
    echo "${label}: expected file to exist: ${file_path}" >&2
    exit 1
  fi

  local actual
  actual="$(cat "${file_path}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "${label}: file contents mismatch" >&2
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual}" >&2
    exit 1
  fi
}

array_contains_exact() {
  local needle="$1"
  shift

  local item
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done

  return 1
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

run_auto_mode_paste_app_prefers_paste_dry_run() {
  if ! can_use_macos_paste; then
    skip "auto-mode paste-app preference check requires macOS paste support"
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${fake_bin}/tmux"

  local out
  out="$(PATH="${fake_bin}:${PATH}" env TMUX=/tmp/fake-tmux "${VOICE_SCRIPT}" \
    --dry-run \
    --insert-mode auto \
    --paste-app iTerm2 \
    --provider command \
    --transcribe-cmd cat 2>&1)"

  require_output_contains "${out}" "Insert mode: auto -> paste" "auto-mode paste-app preference dry-run"
  require_output_contains "${out}" "Paste target: iTerm2 (activated before paste)" "auto-mode paste-app preference dry-run"

  rm -rf "${tmp_dir}"
  pass "auto mode prefers paste path when --paste-app is set"
}

run_auto_mode_paste_fallback_smoke() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "auto-mode paste fallback smoke requires macOS"
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "${out}")"
printf "fake-audio" >"${out}"
EOF
  chmod +x "${fake_bin}/ffmpeg"

  cat >"${fake_bin}/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
  chmod +x "${fake_bin}/pbcopy"

  cat >"${fake_bin}/osascript" <<'EOF'
#!/usr/bin/env bash
# Simulate inaccessible System Events / failed paste injection.
cat >/dev/null || true
exit 1
EOF
  chmod +x "${fake_bin}/osascript"

  local transcript_file="${tmp_dir}/fallback-transcript.txt"

  set +e
  local out
  out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode auto \
    --provider command \
    --transcribe-cmd 'printf "fallback smoke transcript\\n"' \
    --transcript-file "${transcript_file}" \
    --status-json 2>&1)"
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    rm -rf "${tmp_dir}"
    echo "auto-mode paste fallback smoke: expected rc 0, got ${rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${out}" "Focused-app paste failed; falling back to transcript file mode." "auto-mode paste fallback smoke"
  require_output_contains "${out}" "GOOSE_VOICE_PASTE_FAILURE_REASON=accessibility_unavailable" "auto-mode paste fallback smoke"
  require_output_contains "${out}" "✅ Transcript saved to: ${transcript_file}" "auto-mode paste fallback smoke"
  require_output_contains "${out}" "GOOSE_VOICE_STATUS_JSON=" "auto-mode paste fallback smoke"
  require_output_contains "${out}" "\"outcome\":\"ok_fallback\"" "auto-mode paste fallback smoke"
  require_output_contains "${out}" "\"fallback_from\":\"paste\"" "auto-mode paste fallback smoke"
  require_output_contains "${out}" "\"delivery_mode\":\"file\"" "auto-mode paste fallback smoke"
  require_file_equals "${transcript_file}" "fallback smoke transcript" "auto-mode paste fallback smoke"

  rm -rf "${tmp_dir}"
  pass "auto-mode falls back to file mode when focused-app paste fails"
}

run_launcher_status_summary_smoke() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "launcher summary smoke requires macOS"
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "${out}")"
printf "fake-audio" >"${out}"
EOF
  chmod +x "${fake_bin}/ffmpeg"

  cat >"${fake_bin}/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
  chmod +x "${fake_bin}/pbcopy"

  cat >"${fake_bin}/osascript" <<'EOF'
#!/usr/bin/env bash
# Simulate inaccessible System Events / failed paste injection.
cat >/dev/null || true
exit 1
EOF
  chmod +x "${fake_bin}/osascript"

  local transcript_file="${tmp_dir}/launcher-fallback-transcript.txt"

  set +e
  local fallback_out
  fallback_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode auto \
    --provider command \
    --transcribe-cmd 'printf "launcher fallback smoke transcript\\n"' \
    --transcript-file "${transcript_file}" 2>&1)"
  local fallback_rc=$?
  set -e

  if [[ "${fallback_rc}" -ne 0 ]]; then
    rm -rf "${tmp_dir}"
    echo "launcher fallback smoke: expected rc 0, got ${fallback_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${fallback_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${fallback_out}" "⚠️  Voice fast path (paste) failed; fell back to file bridge." "launcher fallback smoke"
  require_output_contains "${fallback_out}" "Hint: grant Accessibility/Input Monitoring to your terminal and osascript host, then retry." "launcher fallback smoke"
  require_file_equals "${transcript_file}" "launcher fallback smoke transcript" "launcher fallback smoke"

  set +e
  local error_out
  error_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --provider command \
    --transcribe-cmd 'printf "launcher error smoke transcript\\n"' 2>&1)"
  local error_rc=$?
  set -e

  if [[ "${error_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "launcher error smoke: expected rc 14, got ${error_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${error_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${error_out}" "❌ Voice run failed (delivery=paste, reason=accessibility_unavailable)." "launcher error smoke"
  require_output_contains "${error_out}" "Hint: grant Accessibility/Input Monitoring to your terminal and osascript host, then retry." "launcher error smoke"

  rm -rf "${tmp_dir}"
  pass "launcher emits concise fallback/error summaries for accessibility failures"
}

run_mic_name_resolution_smoke() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${*}" == *"-list_devices true"* ]]; then
  cat >&2 <<'LIST'
[AVFoundation indev @ 0x111] AVFoundation audio devices:
[AVFoundation indev @ 0x111] [0] Built-in Mic
[AVFoundation indev @ 0x111] [1] USB Mic
[AVFoundation indev @ 0x111] [2] USB Mic (Aggregate)
[AVFoundation indev @ 0x111] AVFoundation video devices:
LIST
  exit 1
fi

echo "unexpected ffmpeg invocation in mic-name smoke: ${*}" >&2
exit 99
EOF
  chmod +x "${fake_bin}/ffmpeg"

  local unique_out
  unique_out="$(PATH="${fake_bin}:${PATH}" "${VOICE_SCRIPT}" --dry-run --mic-name aggregate --provider command --transcribe-cmd cat 2>&1)"
  require_output_contains "${unique_out}" "🎤 Selected mic index 2 from name match: aggregate" "mic-name unique smoke"
  require_output_contains "${unique_out}" "Mic index: 2" "mic-name unique smoke"

  set +e
  local missing_index_out
  missing_index_out="$(PATH="${fake_bin}:${PATH}" "${VOICE_SCRIPT}" --dry-run --mic-index 9 --provider command --transcribe-cmd cat 2>&1)"
  local missing_index_rc=$?
  set -e

  if [[ "${missing_index_rc}" -ne 11 ]]; then
    rm -rf "${tmp_dir}"
    echo "mic-index missing-device smoke: expected rc 11, got ${missing_index_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${missing_index_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${missing_index_out}" "No audio device found for --mic-index 9." "mic-index missing-device smoke"
  require_output_contains "${missing_index_out}" "Run goose-voice-ptt.sh --list-devices to inspect available indices." "mic-index missing-device smoke"

  set +e
  local ambiguous_out
  ambiguous_out="$(PATH="${fake_bin}:${PATH}" "${VOICE_SCRIPT}" --dry-run --mic-name usb --provider command --transcribe-cmd cat 2>&1)"
  local ambiguous_rc=$?
  set -e

  if [[ "${ambiguous_rc}" -ne 11 ]]; then
    rm -rf "${tmp_dir}"
    echo "mic-name ambiguous smoke: expected rc 11, got ${ambiguous_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${ambiguous_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${ambiguous_out}" "Multiple audio devices match --mic-name 'usb':" "mic-name ambiguous smoke"
  require_output_contains "${ambiguous_out}" "[1] USB Mic" "mic-name ambiguous smoke"
  require_output_contains "${ambiguous_out}" "[2] USB Mic (Aggregate)" "mic-name ambiguous smoke"
  require_output_contains "${ambiguous_out}" "Use --mic-index N or a more specific --mic-name." "mic-name ambiguous smoke"

  set +e
  local no_match_out
  no_match_out="$(PATH="${fake_bin}:${PATH}" "${VOICE_SCRIPT}" --dry-run --mic-name builtin --provider command --transcribe-cmd cat 2>&1)"
  local no_match_rc=$?
  set -e

  if [[ "${no_match_rc}" -ne 11 ]]; then
    rm -rf "${tmp_dir}"
    echo "mic-name no-match smoke: expected rc 11, got ${no_match_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${no_match_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${no_match_out}" "No audio device matching --mic-name 'builtin'." "mic-name no-match smoke"
  require_output_contains "${no_match_out}" "Did you mean one of these devices?" "mic-name no-match smoke"
  require_output_contains "${no_match_out}" "[0] Built-in Mic" "mic-name no-match smoke"

  rm -rf "${tmp_dir}"
  pass "mic selection dry-run resolves names, rejects missing indices/ambiguous matches, and suggests close devices"
}

run_auto_submit_failure_reason_smoke() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "auto-submit failure smoke requires macOS"
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "${out}")"
printf "fake-audio" >"${out}"
EOF
  chmod +x "${fake_bin}/ffmpeg"

  cat >"${fake_bin}/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
  chmod +x "${fake_bin}/pbcopy"

  cat >"${fake_bin}/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script="$(cat)"

if [[ "${script}" == *"keystroke \"v\" using command down"* ]]; then
  exit 0
fi

if [[ "${script}" == *"key code 36"* ]]; then
  exit 1
fi

if [[ "${script}" == *"count every process"* ]]; then
  exit 0
fi

exit 0
EOF
  chmod +x "${fake_bin}/osascript"

  set +e
  local status_err_out
  status_err_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --auto-submit \
    --provider command \
    --transcribe-cmd 'printf "status auto-submit failure transcript\\n"' \
    --status-json 2>&1)"
  local status_err_rc=$?
  set -e

  if [[ "${status_err_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "status-json auto-submit error smoke: expected rc 14, got ${status_err_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${status_err_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${status_err_out}" "GOOSE_VOICE_PASTE_FAILURE_REASON=auto_submit_key_event_blocked" "status-json auto-submit error smoke"
  require_output_contains "${status_err_out}" "GOOSE_VOICE_STATUS_JSON=" "status-json auto-submit error smoke"
  require_output_contains "${status_err_out}" "\"outcome\":\"error\"" "status-json auto-submit error smoke"
  require_output_contains "${status_err_out}" "\"delivery_mode\":\"paste\"" "status-json auto-submit error smoke"
  require_output_contains "${status_err_out}" "\"reason\":\"auto_submit_key_event_blocked\"" "status-json auto-submit error smoke"

  local transcript_file="${tmp_dir}/auto-submit-fallback-transcript.txt"
  set +e
  local status_fallback_out
  status_fallback_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode auto \
    --auto-submit \
    --provider command \
    --transcribe-cmd 'printf "status auto-submit fallback transcript\\n"' \
    --transcript-file "${transcript_file}" \
    --status-json 2>&1)"
  local status_fallback_rc=$?
  set -e

  if [[ "${status_fallback_rc}" -ne 0 ]]; then
    rm -rf "${tmp_dir}"
    echo "status-json auto-submit fallback smoke: expected rc 0, got ${status_fallback_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${status_fallback_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${status_fallback_out}" "Focused-app paste failed; falling back to transcript file mode. (reason: auto_submit_key_event_blocked)" "status-json auto-submit fallback smoke"
  require_output_contains "${status_fallback_out}" "\"outcome\":\"ok_fallback\"" "status-json auto-submit fallback smoke"
  require_output_contains "${status_fallback_out}" "\"fallback_from\":\"paste\"" "status-json auto-submit fallback smoke"
  require_output_contains "${status_fallback_out}" "\"delivery_mode\":\"file\"" "status-json auto-submit fallback smoke"
  require_output_contains "${status_fallback_out}" "\"reason\":\"auto_submit_key_event_blocked\"" "status-json auto-submit fallback smoke"
  require_file_equals "${transcript_file}" "status auto-submit fallback transcript submit" "status-json auto-submit fallback smoke"

  set +e
  local launcher_err_out
  launcher_err_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --auto-submit \
    --provider command \
    --transcribe-cmd 'printf "launcher auto-submit error transcript\\n"' 2>&1)"
  local launcher_err_rc=$?
  set -e

  if [[ "${launcher_err_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "launcher auto-submit error smoke: expected rc 14, got ${launcher_err_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${launcher_err_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${launcher_err_out}" "❌ Voice run failed (delivery=paste, reason=auto_submit_key_event_blocked)." "launcher auto-submit error smoke"
  require_output_contains "${launcher_err_out}" "Hint: focused app blocked synthetic key events; retry with --insert-mode file or adjust permissions/state." "launcher auto-submit error smoke"

  cat >"${fake_bin}/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script="$(cat)"

if [[ "${script}" == *"keystroke \"v\" using command down"* ]]; then
  exit 0
fi

if [[ "${script}" == *"key code 36"* ]]; then
  exit 1
fi

if [[ "${script}" == *"count every process"* ]]; then
  exit 1
fi

exit 0
EOF
  chmod +x "${fake_bin}/osascript"

  set +e
  local status_access_out
  status_access_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --auto-submit \
    --provider command \
    --transcribe-cmd 'printf "status auto-submit accessibility transcript\\n"' \
    --status-json 2>&1)"
  local status_access_rc=$?
  set -e

  if [[ "${status_access_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "status-json auto-submit accessibility smoke: expected rc 14, got ${status_access_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${status_access_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${status_access_out}" "GOOSE_VOICE_PASTE_FAILURE_REASON=auto_submit_accessibility_unavailable" "status-json auto-submit accessibility smoke"
  require_output_contains "${status_access_out}" "\"reason\":\"auto_submit_accessibility_unavailable\"" "status-json auto-submit accessibility smoke"

  set +e
  local launcher_access_out
  launcher_access_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --auto-submit \
    --provider command \
    --transcribe-cmd 'printf "launcher auto-submit accessibility transcript\\n"' 2>&1)"
  local launcher_access_rc=$?
  set -e

  if [[ "${launcher_access_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "launcher auto-submit accessibility smoke: expected rc 14, got ${launcher_access_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${launcher_access_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${launcher_access_out}" "❌ Voice run failed (delivery=paste, reason=auto_submit_accessibility_unavailable)." "launcher auto-submit accessibility smoke"
  require_output_contains "${launcher_access_out}" "Hint: grant Accessibility/Input Monitoring to your terminal and osascript host, then retry." "launcher auto-submit accessibility smoke"

  local status_auto_access_transcript_file="${tmp_dir}/auto-submit-accessibility-fallback-transcript.txt"
  set +e
  local status_auto_access_out
  status_auto_access_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode auto \
    --auto-submit \
    --provider command \
    --transcribe-cmd 'printf "status auto-submit accessibility fallback transcript\\n"' \
    --transcript-file "${status_auto_access_transcript_file}" \
    --status-json 2>&1)"
  local status_auto_access_rc=$?
  set -e

  if [[ "${status_auto_access_rc}" -ne 0 ]]; then
    rm -rf "${tmp_dir}"
    echo "status-json auto-submit accessibility auto-fallback smoke: expected rc 0, got ${status_auto_access_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${status_auto_access_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${status_auto_access_out}" "Focused-app paste failed; falling back to transcript file mode. (reason: auto_submit_accessibility_unavailable)" "status-json auto-submit accessibility auto-fallback smoke"
  require_output_contains "${status_auto_access_out}" "\"outcome\":\"ok_fallback\"" "status-json auto-submit accessibility auto-fallback smoke"
  require_output_contains "${status_auto_access_out}" "\"fallback_from\":\"paste\"" "status-json auto-submit accessibility auto-fallback smoke"
  require_output_contains "${status_auto_access_out}" "\"delivery_mode\":\"file\"" "status-json auto-submit accessibility auto-fallback smoke"
  require_output_contains "${status_auto_access_out}" "\"reason\":\"auto_submit_accessibility_unavailable\"" "status-json auto-submit accessibility auto-fallback smoke"
  require_file_equals "${status_auto_access_transcript_file}" "status auto-submit accessibility fallback transcript submit" "status-json auto-submit accessibility auto-fallback smoke"

  local launcher_auto_access_transcript_file="${tmp_dir}/launcher-auto-submit-accessibility-fallback-transcript.txt"
  set +e
  local launcher_auto_access_out
  launcher_auto_access_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode auto \
    --auto-submit \
    --provider command \
    --transcribe-cmd 'printf "launcher auto-submit accessibility fallback transcript\\n"' \
    --transcript-file "${launcher_auto_access_transcript_file}" 2>&1)"
  local launcher_auto_access_rc=$?
  set -e

  if [[ "${launcher_auto_access_rc}" -ne 0 ]]; then
    rm -rf "${tmp_dir}"
    echo "launcher auto-submit accessibility auto-fallback smoke: expected rc 0, got ${launcher_auto_access_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${launcher_auto_access_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${launcher_auto_access_out}" "⚠️  Voice fast path (paste) failed; fell back to file bridge." "launcher auto-submit accessibility auto-fallback smoke"
  require_output_contains "${launcher_auto_access_out}" "Hint: grant Accessibility/Input Monitoring to your terminal and osascript host, then retry." "launcher auto-submit accessibility auto-fallback smoke"
  require_file_equals "${launcher_auto_access_transcript_file}" "launcher auto-submit accessibility fallback transcript submit" "launcher auto-submit accessibility auto-fallback smoke"

  rm -rf "${tmp_dir}"
  pass "status-json and launcher expose auto-submit failure reasons (key-event + accessibility)"
}

run_paste_reason_bucket_smoke() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "paste reason bucket smoke requires macOS"
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "${out}")"
printf "fake-audio" >"${out}"
EOF
  chmod +x "${fake_bin}/ffmpeg"

  cat >"${fake_bin}/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
  chmod +x "${fake_bin}/pbcopy"

  # Scenario 1: --paste-app activation fails -> activate_target_failed
  cat >"${fake_bin}/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script="$(cat || true)"

if [[ "$#" -gt 0 ]]; then
  # activate_target_app_for_paste passes app name as argv[1]
  exit 1
fi

if [[ "${script}" == *"count every process"* ]]; then
  exit 0
fi

exit 0
EOF
  chmod +x "${fake_bin}/osascript"

  set +e
  local activate_out
  activate_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --paste-app iTerm2 \
    --provider command \
    --transcribe-cmd 'printf "activate failed transcript\\n"' \
    --status-json 2>&1)"
  local activate_rc=$?
  set -e

  if [[ "${activate_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "activate-target-failed status smoke: expected rc 14, got ${activate_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${activate_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${activate_out}" "GOOSE_VOICE_PASTE_FAILURE_REASON=activate_target_failed" "activate-target-failed status smoke"
  require_output_contains "${activate_out}" "\"reason\":\"activate_target_failed\"" "activate-target-failed status smoke"

  set +e
  local activate_launcher_out
  activate_launcher_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --paste-app iTerm2 \
    --provider command \
    --transcribe-cmd 'printf "activate failed launcher transcript\\n"' 2>&1)"
  local activate_launcher_rc=$?
  set -e

  if [[ "${activate_launcher_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "activate-target-failed launcher smoke: expected rc 14, got ${activate_launcher_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${activate_launcher_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${activate_launcher_out}" "❌ Voice run failed (delivery=paste, reason=activate_target_failed)." "activate-target-failed launcher smoke"
  require_output_contains "${activate_launcher_out}" "Hint: verify --paste-app app name and that the app is installed/running." "activate-target-failed launcher smoke"

  # Scenario 2: paste key event blocked with System Events accessible -> paste_key_event_blocked
  cat >"${fake_bin}/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script="$(cat || true)"

if [[ "${script}" == *"name of first application process whose frontmost is true"* ]]; then
  echo "Terminal"
  exit 0
fi

if [[ "${script}" == *"keystroke \"v\" using command down"* ]]; then
  exit 1
fi

if [[ "${script}" == *"count every process"* ]]; then
  exit 0
fi

exit 0
EOF
  chmod +x "${fake_bin}/osascript"

  set +e
  local key_blocked_out
  key_blocked_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --provider command \
    --transcribe-cmd 'printf "key event blocked transcript\\n"' \
    --status-json 2>&1)"
  local key_blocked_rc=$?
  set -e

  if [[ "${key_blocked_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "paste-key-event-blocked status smoke: expected rc 14, got ${key_blocked_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${key_blocked_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${key_blocked_out}" "GOOSE_VOICE_PASTE_FAILURE_REASON=paste_key_event_blocked" "paste-key-event-blocked status smoke"
  require_output_contains "${key_blocked_out}" "\"reason\":\"paste_key_event_blocked\"" "paste-key-event-blocked status smoke"

  set +e
  local key_blocked_launcher_out
  key_blocked_launcher_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --provider command \
    --transcribe-cmd 'printf "key event blocked launcher transcript\\n"' 2>&1)"
  local key_blocked_launcher_rc=$?
  set -e

  if [[ "${key_blocked_launcher_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "paste-key-event-blocked launcher smoke: expected rc 14, got ${key_blocked_launcher_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${key_blocked_launcher_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${key_blocked_launcher_out}" "❌ Voice run failed (delivery=paste, reason=paste_key_event_blocked)." "paste-key-event-blocked launcher smoke"
  require_output_contains "${key_blocked_launcher_out}" "Hint: focused app blocked synthetic key events; retry with --insert-mode file or adjust permissions/state." "paste-key-event-blocked launcher smoke"

  rm -rf "${tmp_dir}"
  pass "status-json and launcher expose activate_target_failed + paste_key_event_blocked reasons"
}

run_target_not_frontmost_reason_smoke() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "target-not-frontmost reason smoke requires macOS"
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "${out}")"
printf "fake-audio" >"${out}"
EOF
  chmod +x "${fake_bin}/ffmpeg"

  cat >"${fake_bin}/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
  chmod +x "${fake_bin}/pbcopy"

  cat >"${fake_bin}/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script="$(cat)"

# activate_target_app_for_paste passes target app as argv[1]
if [[ "$#" -gt 0 ]]; then
  exit 0
fi

if [[ "${script}" == *"name of first application process whose frontmost is true"* ]]; then
  echo "Terminal"
  exit 0
fi

if [[ "${script}" == *"keystroke \"v\" using command down"* ]]; then
  exit 1
fi

if [[ "${script}" == *"count every process"* ]]; then
  exit 0
fi

exit 0
EOF
  chmod +x "${fake_bin}/osascript"

  local status_transcript_file="${tmp_dir}/target-not-frontmost-status-transcript.txt"

  set +e
  local status_out
  status_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode auto \
    --paste-app iTerm2 \
    --provider command \
    --transcribe-cmd 'printf "target not frontmost status transcript\\n"' \
    --transcript-file "${status_transcript_file}" \
    --status-json 2>&1)"
  local status_rc=$?
  set -e

  if [[ "${status_rc}" -ne 0 ]]; then
    rm -rf "${tmp_dir}"
    echo "target-not-frontmost status smoke: expected rc 0, got ${status_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${status_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${status_out}" "GOOSE_VOICE_PASTE_FAILURE_REASON=target_not_frontmost" "target-not-frontmost status smoke"
  require_output_contains "${status_out}" "Focused-app paste failed: target app 'iTerm2' is not frontmost (frontmost app: Terminal)." "target-not-frontmost status smoke"
  require_output_contains "${status_out}" "Focused-app paste failed; falling back to transcript file mode. (reason: target_not_frontmost)" "target-not-frontmost status smoke"
  require_output_contains "${status_out}" "\"outcome\":\"ok_fallback\"" "target-not-frontmost status smoke"
  require_output_contains "${status_out}" "\"reason\":\"target_not_frontmost\"" "target-not-frontmost status smoke"
  require_file_equals "${status_transcript_file}" "target not frontmost status transcript" "target-not-frontmost status smoke"

  local launcher_transcript_file="${tmp_dir}/target-not-frontmost-launcher-transcript.txt"

  set +e
  local launcher_out
  launcher_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode auto \
    --paste-app iTerm2 \
    --provider command \
    --transcribe-cmd 'printf "target not frontmost launcher transcript\\n"' \
    --transcript-file "${launcher_transcript_file}" 2>&1)"
  local launcher_rc=$?
  set -e

  if [[ "${launcher_rc}" -ne 0 ]]; then
    rm -rf "${tmp_dir}"
    echo "target-not-frontmost launcher smoke: expected rc 0, got ${launcher_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${launcher_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${launcher_out}" "⚠️  Voice fast path (paste) failed; fell back to file bridge." "target-not-frontmost launcher smoke"
  require_output_contains "${launcher_out}" "Hint: bring the target terminal to front or set --paste-app \"YourTerminalApp\"." "target-not-frontmost launcher smoke"
  require_file_equals "${launcher_transcript_file}" "target not frontmost launcher transcript" "target-not-frontmost launcher smoke"

  set +e
  local explicit_status_out
  explicit_status_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --paste-app iTerm2 \
    --provider command \
    --transcribe-cmd 'printf "target not frontmost explicit status transcript\\n"' \
    --status-json 2>&1)"
  local explicit_status_rc=$?
  set -e

  if [[ "${explicit_status_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "target-not-frontmost explicit status smoke: expected rc 14, got ${explicit_status_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${explicit_status_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${explicit_status_out}" "GOOSE_VOICE_PASTE_FAILURE_REASON=target_not_frontmost" "target-not-frontmost explicit status smoke"
  require_output_contains "${explicit_status_out}" "\"outcome\":\"error\"" "target-not-frontmost explicit status smoke"
  require_output_contains "${explicit_status_out}" "\"delivery_mode\":\"paste\"" "target-not-frontmost explicit status smoke"
  require_output_contains "${explicit_status_out}" "\"reason\":\"target_not_frontmost\"" "target-not-frontmost explicit status smoke"

  set +e
  local explicit_launcher_out
  explicit_launcher_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode paste \
    --paste-app iTerm2 \
    --provider command \
    --transcribe-cmd 'printf "target not frontmost explicit launcher transcript\\n"' 2>&1)"
  local explicit_launcher_rc=$?
  set -e

  if [[ "${explicit_launcher_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "target-not-frontmost explicit launcher smoke: expected rc 14, got ${explicit_launcher_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${explicit_launcher_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${explicit_launcher_out}" "❌ Voice run failed (delivery=paste, reason=target_not_frontmost)." "target-not-frontmost explicit launcher smoke"
  require_output_contains "${explicit_launcher_out}" "Hint: bring the target terminal to front or set --paste-app \"YourTerminalApp\"." "target-not-frontmost explicit launcher smoke"

  rm -rf "${tmp_dir}"
  pass "status-json and launcher expose target_not_frontmost fallback + explicit-paste error reasons"
}

run_launcher_tmux_fallback_summary_smoke() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "${out}")"
printf "fake-audio" >"${out}"
EOF
  chmod +x "${fake_bin}/ffmpeg"

  cat >"${fake_bin}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  set-buffer)
    exit 0
    ;;
  paste-buffer)
    exit 1
    ;;
  send-keys)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${fake_bin}/tmux"

  local transcript_file="${tmp_dir}/launcher-tmux-fallback-transcript.txt"

  set +e
  local fallback_out
  fallback_out="$(PATH="${fake_bin}:${PATH}" env TMUX=/tmp/fake-tmux "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode auto \
    --provider command \
    --transcribe-cmd 'printf "launcher tmux fallback smoke transcript\\n"' \
    --transcript-file "${transcript_file}" 2>&1)"
  local fallback_rc=$?
  set -e

  if [[ "${fallback_rc}" -ne 0 ]]; then
    rm -rf "${tmp_dir}"
    echo "launcher tmux fallback smoke: expected rc 0, got ${fallback_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${fallback_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${fallback_out}" "⚠️  Voice fast path (tmux) failed; fell back to file bridge." "launcher tmux fallback smoke"
  require_output_contains "${fallback_out}" "Hint: verify tmux session/target pane (use --tmux-target if needed)." "launcher tmux fallback smoke"
  require_file_equals "${transcript_file}" "launcher tmux fallback smoke transcript" "launcher tmux fallback smoke"

  rm -rf "${tmp_dir}"
  pass "launcher emits concise tmux fallback summary with guidance"
}

run_launcher_tmux_error_summary_smoke() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "${out}")"
printf "fake-audio" >"${out}"
EOF
  chmod +x "${fake_bin}/ffmpeg"

  cat >"${fake_bin}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  set-buffer)
    exit 0
    ;;
  paste-buffer)
    exit 1
    ;;
  send-keys)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${fake_bin}/tmux"

  set +e
  local error_out
  error_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0 \
    --insert-mode tmux \
    --tmux-target dev:1.1 \
    --provider command \
    --transcribe-cmd 'printf "launcher tmux error smoke transcript\\n"' 2>&1)"
  local error_rc=$?
  set -e

  if [[ "${error_rc}" -ne 14 ]]; then
    rm -rf "${tmp_dir}"
    echo "launcher tmux error smoke: expected rc 14, got ${error_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${error_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${error_out}" "❌ Voice run failed (delivery=tmux, reason=tmux_insert_failed)." "launcher tmux error smoke"
  require_output_contains "${error_out}" "Hint: verify tmux session/target pane (use --tmux-target if needed)." "launcher tmux error smoke"

  rm -rf "${tmp_dir}"
  pass "launcher emits concise tmux failure summary with guidance"
}

run_min_duration_reason_smoke() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local fake_bin="${tmp_dir}/bin"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "${out}")"
printf "fake-audio" >"${out}"
EOF
  chmod +x "${fake_bin}/ffmpeg"

  cat >"${fake_bin}/ffprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "0.10"
EOF
  chmod +x "${fake_bin}/ffprobe"

  set +e
  local status_out
  status_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${VOICE_SCRIPT}" \
    --duration 1 \
    --min-duration 0.25 \
    --insert-mode file \
    --provider command \
    --transcribe-cmd 'printf "min duration smoke transcript\\n"' \
    --status-json 2>&1)"
  local status_rc=$?
  set -e

  if [[ "${status_rc}" -ne 15 ]]; then
    rm -rf "${tmp_dir}"
    echo "min-duration status-json smoke: expected rc 15, got ${status_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${status_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${status_out}" "Recording too short" "min-duration status-json smoke"
  require_output_contains "${status_out}" "\"reason\":\"min_duration_too_short\"" "min-duration status-json smoke"

  set +e
  local launcher_out
  launcher_out="$(PATH="${fake_bin}:${PATH}" env -u TMUX "${LAUNCH_SCRIPT}" \
    --duration 1 \
    --min-duration 0.25 \
    --insert-mode file \
    --provider command \
    --transcribe-cmd 'printf "min duration launcher transcript\\n"' 2>&1)"
  local launcher_rc=$?
  set -e

  if [[ "${launcher_rc}" -ne 15 ]]; then
    rm -rf "${tmp_dir}"
    echo "min-duration launcher smoke: expected rc 15, got ${launcher_rc}" >&2
    echo "--- output ---" >&2
    printf "%s\n" "${launcher_out}" >&2
    echo "--------------" >&2
    exit 1
  fi

  require_output_contains "${launcher_out}" "❌ Voice run failed (delivery=none, reason=min_duration_too_short)." "min-duration launcher smoke"
  require_output_contains "${launcher_out}" "Hint: hold push-to-talk a bit longer, lower --min-duration, or disable the guard with --min-duration 0." "min-duration launcher smoke"

  rm -rf "${tmp_dir}"
  pass "status-json and launcher expose min_duration_too_short reason"
}

run_reason_bucket_sync_smoke() {
  local docs_reasons=()
  while IFS= read -r reason; do
    docs_reasons+=("${reason}")
  done < <(
    grep -E '^[[:space:]]*\| `[a-z0-9_]+` \|' "${DOCS_FILE}" \
      | sed -E 's/^[[:space:]]*\| `([a-z0-9_]+)` \|.*/\1/' \
      | sort -u
  )

  local script_reasons=()
  while IFS= read -r reason; do
    [[ -z "${reason}" ]] && continue
    script_reasons+=("${reason}")
  done < <("${VOICE_SCRIPT}" --reason-buckets | sort -u)

  if [[ ${#docs_reasons[@]} -eq 0 ]]; then
    echo "reason bucket sync smoke: no reason buckets parsed from docs table (${DOCS_FILE})" >&2
    exit 1
  fi

  if [[ ${#script_reasons[@]} -eq 0 ]]; then
    echo "reason bucket sync smoke: no reason buckets parsed from script (${VOICE_SCRIPT})" >&2
    exit 1
  fi

  local missing_in_script=()
  local missing_in_docs=()
  local missing_in_tests=()
  local reason

  for reason in "${docs_reasons[@]}"; do
    if ! array_contains_exact "${reason}" "${script_reasons[@]}"; then
      missing_in_script+=("${reason}")
    fi

    if ! grep -Fq "${reason}" "$0"; then
      missing_in_tests+=("${reason}")
    fi
  done

  for reason in "${script_reasons[@]}"; do
    if ! array_contains_exact "${reason}" "${docs_reasons[@]}"; then
      missing_in_docs+=("${reason}")
    fi
  done

  if [[ ${#missing_in_script[@]} -gt 0 || ${#missing_in_docs[@]} -gt 0 || ${#missing_in_tests[@]} -gt 0 ]]; then
    echo "reason bucket sync smoke failed:" >&2
    if [[ ${#missing_in_script[@]} -gt 0 ]]; then
      echo "  documented but not emitted by script: ${missing_in_script[*]}" >&2
    fi
    if [[ ${#missing_in_docs[@]} -gt 0 ]]; then
      echo "  emitted by script but undocumented: ${missing_in_docs[*]}" >&2
    fi
    if [[ ${#missing_in_tests[@]} -gt 0 ]]; then
      echo "  documented but missing test coverage strings: ${missing_in_tests[*]}" >&2
    fi
    exit 1
  fi

  pass "reason bucket docs/script/tests sync (${#docs_reasons[@]} buckets)"
}

BASE_CMD=("${VOICE_SCRIPT}" --dry-run --provider command --transcribe-cmd cat)

# Default/file dry-run should succeed and keep file insertion.
DEFAULT_OUT="$("${BASE_CMD[@]}" 2>&1)"
require_output_contains "${DEFAULT_OUT}" "Insert mode: file -> file" "default dry-run"
require_output_contains "${DEFAULT_OUT}" "Min clip duration: 0.25s" "default dry-run"
pass "default dry-run (file mode)"

STATUS_DRY_OUT="$(${VOICE_SCRIPT} --dry-run --status-json --provider command --transcribe-cmd cat 2>&1)"
require_output_contains "${STATUS_DRY_OUT}" "GOOSE_VOICE_STATUS_JSON=" "status-json dry-run"
require_output_contains "${STATUS_DRY_OUT}" "\"phase\":\"dry-run\"" "status-json dry-run"
require_output_contains "${STATUS_DRY_OUT}" "\"outcome\":\"dry_run_ok\"" "status-json dry-run"
require_output_contains "${STATUS_DRY_OUT}" "\"insert_mode_resolved\":\"file\"" "status-json dry-run"
pass "status-json emits machine-parseable dry-run summary"

REASON_BUCKETS_OUT=()
while IFS= read -r reason; do
  [[ -z "${reason}" ]] && continue
  REASON_BUCKETS_OUT+=("${reason}")
done < <("${VOICE_SCRIPT}" --reason-buckets)
EXPECTED_REASON_BUCKETS=(
  accessibility_unavailable
  activate_target_failed
  auto_submit_accessibility_unavailable
  auto_submit_key_event_blocked
  min_duration_too_short
  paste_key_event_blocked
  target_not_frontmost
  tmux_insert_failed
)
for expected_reason in "${EXPECTED_REASON_BUCKETS[@]}"; do
  if ! array_contains_exact "${expected_reason}" "${REASON_BUCKETS_OUT[@]}"; then
    echo "reason-buckets output missing: ${expected_reason}" >&2
    printf 'got:\n%s\n' "${REASON_BUCKETS_OUT[*]}" >&2
    exit 1
  fi
done
pass "reason-buckets command emits canonical machine-readable reason list"

SESSION_ENV_OUT="$(${VOICE_SCRIPT} --print-session-env 2>&1)"
require_output_contains "${SESSION_ENV_OUT}" "export GOOSE_VOICE_SESSION_KEY=" "print-session-env"
require_output_contains "${SESSION_ENV_OUT}" "export GOOSE_CLI_VOICE_TRANSCRIPT_FILE=" "print-session-env"
require_output_contains "${SESSION_ENV_OUT}" "export GOOSE_VOICE_PROVIDER=" "print-session-env"
require_output_contains "${SESSION_ENV_OUT}" "export GOOSE_VOICE_LANG=" "print-session-env"
pass "print-session-env emits per-session export hints"

SESSION_ENV_OVERRIDE_OUT="$(${VOICE_SCRIPT} --print-session-env --session-key env-room --transcript-file /tmp/goose-voice-env-room.txt --provider command --model demo-model --lang fr 2>&1)"
require_output_contains "${SESSION_ENV_OVERRIDE_OUT}" "export GOOSE_VOICE_SESSION_KEY=\"env-room\"" "print-session-env overrides"
require_output_contains "${SESSION_ENV_OVERRIDE_OUT}" "export GOOSE_CLI_VOICE_TRANSCRIPT_FILE=\"/tmp/goose-voice-env-room.txt\"" "print-session-env overrides"
require_output_contains "${SESSION_ENV_OVERRIDE_OUT}" "export GOOSE_VOICE_PROVIDER=\"command\"" "print-session-env overrides"
require_output_contains "${SESSION_ENV_OVERRIDE_OUT}" "export GOOSE_VOICE_MODEL=\"demo-model\"" "print-session-env overrides"
require_output_contains "${SESSION_ENV_OVERRIDE_OUT}" "export GOOSE_VOICE_LANG=\"fr\"" "print-session-env overrides"
pass "print-session-env respects transcript/provider/model/lang overrides"

SESSION_LAUNCH_DRY_OUT="$(${SESSION_LAUNCH_SCRIPT} --dry-run 2>&1)"
require_output_contains "${SESSION_LAUNCH_DRY_OUT}" "export GOOSE_VOICE_SESSION_KEY=" "session launcher dry-run"
require_output_contains "${SESSION_LAUNCH_DRY_OUT}" "export GOOSE_CLI_VOICE_TRANSCRIPT_FILE=" "session launcher dry-run"
require_output_contains "${SESSION_LAUNCH_DRY_OUT}" "export GOOSE_VOICE_LANG=" "session launcher dry-run"
require_output_contains "${SESSION_LAUNCH_DRY_OUT}" "Would run: goose session" "session launcher dry-run"
pass "session launcher dry-run emits voice exports and default goose command"

SESSION_LAUNCH_FLAG_ONLY_DRY_OUT="$(${SESSION_LAUNCH_SCRIPT} --session-key voice-demo --dry-run -n voice-demo 2>&1)"
require_output_contains "${SESSION_LAUNCH_FLAG_ONLY_DRY_OUT}" "export GOOSE_VOICE_SESSION_KEY=\"voice-demo\"" "session launcher flag-only dry-run"
require_output_contains "${SESSION_LAUNCH_FLAG_ONLY_DRY_OUT}" "Would run: goose session -n voice-demo" "session launcher flag-only dry-run"
pass "session launcher auto-prefixes session when only session flags are passed"

SESSION_LAUNCH_KEY_DRY_OUT="$(${SESSION_LAUNCH_SCRIPT} --session-key voice-demo --dry-run -- session -n voice-demo 2>&1)"
require_output_contains "${SESSION_LAUNCH_KEY_DRY_OUT}" "export GOOSE_VOICE_SESSION_KEY=\"voice-demo\"" "session launcher session-key dry-run"
require_output_contains "${SESSION_LAUNCH_KEY_DRY_OUT}" "export GOOSE_CLI_VOICE_TRANSCRIPT_FILE=\"/tmp/goose-cli-voice-transcript-voice-demo.txt\"" "session launcher session-key dry-run"
require_output_contains "${SESSION_LAUNCH_KEY_DRY_OUT}" "Would run: goose session -n voice-demo" "session launcher session-key dry-run"
pass "session launcher supports --session-key and passthrough goose args"

SESSION_LAUNCH_OVERRIDE_DRY_OUT="$(${SESSION_LAUNCH_SCRIPT} --session-key voice-es --transcript-file /tmp/goose-voice-es.txt --provider command --model custom-model --lang es --dry-run -- session -n voz 2>&1)"
require_output_contains "${SESSION_LAUNCH_OVERRIDE_DRY_OUT}" "export GOOSE_VOICE_SESSION_KEY=\"voice-es\"" "session launcher overrides dry-run"
require_output_contains "${SESSION_LAUNCH_OVERRIDE_DRY_OUT}" "export GOOSE_CLI_VOICE_TRANSCRIPT_FILE=\"/tmp/goose-voice-es.txt\"" "session launcher overrides dry-run"
require_output_contains "${SESSION_LAUNCH_OVERRIDE_DRY_OUT}" "export GOOSE_VOICE_PROVIDER=\"command\"" "session launcher overrides dry-run"
require_output_contains "${SESSION_LAUNCH_OVERRIDE_DRY_OUT}" "export GOOSE_VOICE_MODEL=\"custom-model\"" "session launcher overrides dry-run"
require_output_contains "${SESSION_LAUNCH_OVERRIDE_DRY_OUT}" "export GOOSE_VOICE_LANG=\"es\"" "session launcher overrides dry-run"
require_output_contains "${SESSION_LAUNCH_OVERRIDE_DRY_OUT}" "Would run: goose session -n voz" "session launcher overrides dry-run"
pass "session launcher forwards transcript/provider/model/lang overrides"

run_failure_case "session launcher rejects missing --session-key value" 8 \
  "${SESSION_LAUNCH_SCRIPT}" --session-key --dry-run

run_failure_case "session launcher rejects missing --transcript-file value" 8 \
  "${SESSION_LAUNCH_SCRIPT}" --transcript-file --dry-run

run_failure_case "session launcher rejects missing --provider value" 8 \
  "${SESSION_LAUNCH_SCRIPT}" --provider --dry-run

run_failure_case "session launcher rejects missing --model value" 8 \
  "${SESSION_LAUNCH_SCRIPT}" --model --dry-run

run_failure_case "session launcher rejects missing --lang value" 8 \
  "${SESSION_LAUNCH_SCRIPT}" --lang --dry-run

SESSION_KEY_DRY_OUT="$(GOOSE_VOICE_SESSION_KEY='demo-room' ${VOICE_SCRIPT} --dry-run --provider command --transcribe-cmd cat 2>&1)"
require_output_contains "${SESSION_KEY_DRY_OUT}" "Transcript file: /tmp/goose-cli-voice-transcript-demo-room.txt" "session-key env dry-run"
require_output_contains "${SESSION_KEY_DRY_OUT}" "Session key: demo-room" "session-key env dry-run"
pass "session-key env derives deterministic transcript path"

SESSION_KEY_FLAG_DRY_OUT="$(${VOICE_SCRIPT} --dry-run --session-key focused-room --provider command --transcribe-cmd cat 2>&1)"
require_output_contains "${SESSION_KEY_FLAG_DRY_OUT}" "Transcript file: /tmp/goose-cli-voice-transcript-focused-room.txt" "session-key flag dry-run"
require_output_contains "${SESSION_KEY_FLAG_DRY_OUT}" "Session key: focused-room" "session-key flag dry-run"
pass "--session-key overrides transcript path deterministically"

ARGV_DRY_OUT="$(${VOICE_SCRIPT} --dry-run --provider command --transcribe-bin cat --transcribe-arg --dummy 2>&1)"
require_output_contains "${ARGV_DRY_OUT}" "Command mode: argv" "command argv dry-run"
require_output_contains "${ARGV_DRY_OUT}" "Command bin: cat" "command argv dry-run"
pass "provider command argv mode dry-run is wired"

run_failure_case "--transcribe-arg requires --transcribe-bin" 3 \
  "${VOICE_SCRIPT}" --dry-run --provider command --transcribe-arg --dummy --transcribe-cmd cat

run_failure_case "--provider command rejects mixed --transcribe-bin and --transcribe-cmd" 3 \
  "${VOICE_SCRIPT}" --dry-run --provider command --transcribe-bin cat --transcribe-cmd cat

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

run_auto_mode_paste_app_prefers_paste_dry_run
run_auto_mode_paste_fallback_smoke
run_launcher_status_summary_smoke
run_mic_name_resolution_smoke
run_auto_submit_failure_reason_smoke
run_paste_reason_bucket_smoke
run_target_not_frontmost_reason_smoke
run_launcher_tmux_fallback_summary_smoke
run_launcher_tmux_error_summary_smoke
run_min_duration_reason_smoke
run_reason_bucket_sync_smoke

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

run_failure_case "missing --ptt-mode value is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --ptt-mode --provider command --transcribe-cmd cat

run_failure_case "missing --mic-name value is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --mic-name --provider command --transcribe-cmd cat

run_failure_case "missing --session-key value is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --session-key --provider command --transcribe-cmd cat

run_failure_case "missing --provider value is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --provider --transcribe-cmd cat

run_failure_case "missing --transcribe-cmd value is rejected" 8 \
  "${VOICE_SCRIPT}" --dry-run --provider command --transcribe-cmd --insert-mode file

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
