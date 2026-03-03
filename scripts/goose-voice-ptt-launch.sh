#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_SCRIPT="${SCRIPT_DIR}/goose-voice-ptt.sh"

if [[ ! -f "$VOICE_SCRIPT" ]]; then
  echo "Missing voice script: $VOICE_SCRIPT" >&2
  exit 2
fi

TMP_ERR="$(mktemp)"
cleanup() {
  rm -f "$TMP_ERR"
}
trap cleanup EXIT

run_voice_script() {
  local rc
  set +e
  bash "$VOICE_SCRIPT" --status-json "$@" \
    2> >(while IFS= read -r line; do
      printf '%s\n' "$line" >>"$TMP_ERR"
      [[ "$line" == GOOSE_VOICE_STATUS_JSON=* ]] && continue
      printf '%s\n' "$line" >&2
    done)
  rc=$?
  set -e
  return "$rc"
}

status_guidance() {
  local reason="$1"
  case "$reason" in
    accessibility_unavailable|auto_submit_accessibility_unavailable)
      echo "   Hint: grant Accessibility/Input Monitoring to your terminal and osascript host, then retry." ;;
    target_not_frontmost)
      echo "   Hint: bring the target terminal to front or set --paste-app \"YourTerminalApp\"." ;;
    activate_target_failed)
      echo "   Hint: verify --paste-app app name and that the app is installed/running." ;;
    tmux_insert_failed)
      echo "   Hint: verify tmux session/target pane (use --tmux-target if needed)." ;;
    paste_key_event_blocked|auto_submit_key_event_blocked)
      echo "   Hint: focused app blocked synthetic key events; retry with --insert-mode file or adjust permissions/state." ;;
    "")
      ;;
    *)
      echo "   Hint: reason='${reason}' (see stderr above for details)." ;;
  esac
}

print_status_summary() {
  local status_line payload
  status_line="$(grep '^GOOSE_VOICE_STATUS_JSON=' "$TMP_ERR" | tail -n 1 || true)"
  [[ -z "$status_line" ]] && return

  payload="${status_line#GOOSE_VOICE_STATUS_JSON=}"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "ℹ️  Voice run finished (status JSON captured; python3 unavailable for concise summary)." >&2
    return
  fi

  local parsed outcome delivery fallback reason requested resolved provider
  parsed="$(python3 - "$payload" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    print("parse_error")
    sys.exit(0)
fields=[
    d.get("outcome",""),
    d.get("delivery_mode",""),
    d.get("fallback_from",""),
    d.get("reason",""),
    d.get("insert_mode_requested",""),
    d.get("insert_mode_resolved",""),
    d.get("provider",""),
]
sep="\x1f"
print(sep.join(str(x).replace(sep, " ") for x in fields))
PY
)"

  if [[ "$parsed" == "parse_error" || -z "$parsed" ]]; then
    echo "ℹ️  Voice run finished (could not parse status summary)." >&2
    return
  fi

  IFS=$'\x1f' read -r outcome delivery fallback reason requested resolved provider <<<"$parsed"

  case "$outcome" in
    dry_run_ok)
      echo "✅ Voice preflight OK (insert: ${requested}->${resolved}, provider: ${provider})." >&2
      ;;
    ok)
      case "$delivery" in
        tmux)
          echo "✅ Voice transcript inserted via tmux fast path." >&2 ;;
        paste)
          echo "✅ Voice transcript inserted via focused-app paste fast path." >&2 ;;
        file)
          echo "✅ Voice transcript queued via file bridge for Goose prompt prefill." >&2 ;;
        *)
          echo "✅ Voice run completed (delivery: ${delivery})." >&2 ;;
      esac
      ;;
    ok_fallback)
      echo "⚠️  Voice fast path (${fallback}) failed; fell back to file bridge." >&2
      status_guidance "$reason" >&2
      ;;
    printed)
      echo "✅ Voice transcript printed to stdout (--print-only)." >&2
      ;;
    discarded|discarded_confirm)
      echo "🗑️  Voice transcript discarded." >&2
      ;;
    error)
      echo "❌ Voice run failed (delivery=${delivery}${reason:+, reason=${reason}})." >&2
      status_guidance "$reason" >&2
      ;;
    *)
      echo "ℹ️  Voice run outcome: ${outcome} (delivery=${delivery}${reason:+, reason=${reason}})." >&2
      ;;
  esac
}

if run_voice_script "$@"; then
  rc=0
else
  rc=$?
fi

print_status_summary
exit "$rc"
