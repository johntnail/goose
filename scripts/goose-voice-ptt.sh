#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  goose-voice-ptt.sh [options]

Record from your microphone and inject transcript text into Goose CLI via
GOOSE_CLI_VOICE_TRANSCRIPT_FILE semantics.

Defaults:
  - Local transcription via whisper.cpp (`whisper-cli`)
  - Transcript delivery: file mode (`--insert-mode file`) to Goose transcript bridge
  - Transcript file: $GOOSE_CLI_VOICE_TRANSCRIPT_FILE or /tmp/goose-cli-voice-transcript.txt
  - Interactive record mode: press ENTER to start, ENTER to stop
  - Max duration guard in interactive mode: 30s
  - Hold mode falls back to ENTER mode if key-state polling is unavailable

Options:
  --mic-index N           avfoundation audio index (default: 0)
  --mic-name TEXT         case-insensitive device name match (overrides --mic-index)
  --list-devices          list avfoundation audio devices and exit
  --duration SEC          fixed record duration in seconds (non-interactive)
  --max-duration SEC      safety cap for interactive record mode (default: 30)
  --ptt-mode MODE         interactive mode: enter|hold (default: enter)
  --ptt-key KEY           hold mode key: space|enter|return|left_shift|right_shift or keycode int (default: space)
  --hold-strict           fail instead of falling back when hold-key detection is unavailable
  --transcript-file PATH  transcript output file (default noted above)
  --insert-mode MODE      transcript delivery: file|tmux|auto (default: file)
  --tmux-target TARGET    tmux pane target for insert-mode tmux/auto
  --auto-submit           file mode: append " submit"; tmux mode: press ENTER after paste
  --clear-status          clear transient status lines before showing transcript
  --provider NAME         transcription provider: local|command (default: local)
  --model PATH            local model path (default: ~/.openclaw/models/whisper-cpp/ggml-base.en.bin)
  --lang CODE             local transcription language (default: en)
  --transcribe-cmd CMD    provider=command only; command that outputs transcript to stdout
  --discard               record + transcribe but do not write transcript file
  --print-only            print transcript to stdout (implies --discard)
  --confirm               ask before writing transcript file (decline => discard)
  --dry-run               validate config/tools and print resolved settings, then exit
  -h, --help              show help

Examples:
  # Interactive local PTT flow, insert into Goose next prompt
  goose-voice-ptt.sh

  # Hold-to-record (release key to stop)
  goose-voice-ptt.sh --ptt-mode hold --ptt-key space

  # Auto-send transcript after insertion
  goose-voice-ptt.sh --auto-submit

  # Ask for confirmation before writing into Goose's transcript bridge file
  goose-voice-ptt.sh --confirm

  # List microphone device indices
  goose-voice-ptt.sh --list-devices

  # Select mic by name (case-insensitive substring)
  goose-voice-ptt.sh --mic-name "MacBook Pro Microphone"

  # Use a custom transcript path for an active Goose session
  goose-voice-ptt.sh --transcript-file /tmp/goose-voice.txt

  # Paste directly into the current tmux pane's active Goose prompt
  goose-voice-ptt.sh --insert-mode tmux

  # Custom command provider
  goose-voice-ptt.sh --provider command --transcribe-cmd 'my_transcriber'

  # Validate setup and show resolved insertion/transcript targets without recording
  goose-voice-ptt.sh --dry-run
EOF
}

MIC_INDEX="0"
MIC_NAME=""
LIST_DEVICES=0
DURATION=""
MAX_DURATION="30"
PTT_MODE="${GOOSE_VOICE_PTT_MODE:-enter}"
PTT_KEY="${GOOSE_VOICE_PTT_KEY:-space}"
HOLD_STRICT="${GOOSE_VOICE_HOLD_STRICT:-0}"
TRANSCRIPT_FILE="${GOOSE_CLI_VOICE_TRANSCRIPT_FILE:-/tmp/goose-cli-voice-transcript.txt}"
INSERT_MODE="${GOOSE_VOICE_INSERT_MODE:-file}"
TMUX_TARGET="${GOOSE_VOICE_TMUX_TARGET:-}"
RESOLVED_INSERT_MODE="file"
AUTO_SUBMIT=0
CLEAR_STATUS=0
PROVIDER="${GOOSE_VOICE_PROVIDER:-local}"
MODEL_PATH="${GOOSE_VOICE_MODEL:-$HOME/.openclaw/models/whisper-cpp/ggml-base.en.bin}"
LANG="${GOOSE_VOICE_LANG:-en}"
TRANSCRIBE_CMD="${GOOSE_VOICE_TRANSCRIBE_CMD:-}"
DISCARD=0
PRINT_ONLY=0
CONFIRM=0
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYWATCH_SWIFT="${SCRIPT_DIR}/goose-voice-ptt-keywatch.swift"
STATUS_LINES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mic-index)
      MIC_INDEX="${2:-}"
      shift 2
      ;;
    --mic-name)
      MIC_NAME="${2:-}"
      shift 2
      ;;
    --list-devices)
      LIST_DEVICES=1
      shift
      ;;
    --duration)
      DURATION="${2:-}"
      shift 2
      ;;
    --max-duration)
      MAX_DURATION="${2:-}"
      shift 2
      ;;
    --ptt-mode)
      PTT_MODE="${2:-}"
      shift 2
      ;;
    --ptt-key)
      PTT_KEY="${2:-}"
      shift 2
      ;;
    --hold-strict)
      HOLD_STRICT=1
      shift
      ;;
    --transcript-file)
      TRANSCRIPT_FILE="${2:-}"
      shift 2
      ;;
    --insert-mode)
      INSERT_MODE="${2:-}"
      shift 2
      ;;
    --tmux-target)
      TMUX_TARGET="${2:-}"
      shift 2
      ;;
    --auto-submit)
      AUTO_SUBMIT=1
      shift
      ;;
    --clear-status)
      CLEAR_STATUS=1
      shift
      ;;
    --provider)
      PROVIDER="${2:-}"
      shift 2
      ;;
    --model)
      MODEL_PATH="${2:-}"
      shift 2
      ;;
    --lang)
      LANG="${2:-}"
      shift 2
      ;;
    --transcribe-cmd)
      TRANSCRIBE_CMD="${2:-}"
      shift 2
      ;;
    --discard)
      DISCARD=1
      shift
      ;;
    --print-only)
      PRINT_ONLY=1
      DISCARD=1
      shift
      ;;
    --confirm)
      CONFIRM=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 not found in PATH" >&2
    exit 2
  fi
}

status_line() {
  echo "$@"
  STATUS_LINES=$((STATUS_LINES + 1))
}

status_input_line() {
  STATUS_LINES=$((STATUS_LINES + 1))
}

clear_status_lines() {
  if [[ "$CLEAR_STATUS" -ne 1 ]]; then
    return
  fi
  if [[ ! -t 1 ]]; then
    return
  fi
  if [[ "$STATUS_LINES" -le 0 ]]; then
    return
  fi

  local i
  for ((i = 0; i < STATUS_LINES; i++)); do
    printf '\033[1A\033[2K'
  done
  STATUS_LINES=0
}

ptt_key_to_code() {
  local key="$1"
  case "$key" in
    space)
      echo "49"
      ;;
    enter|return)
      echo "36"
      ;;
    left_shift)
      echo "56"
      ;;
    right_shift)
      echo "60"
      ;;
    [0-9]*)
      echo "$key"
      ;;
    *)
      echo "Unsupported --ptt-key: $key" >&2
      echo "Use: space|enter|return|left_shift|right_shift or an integer keycode." >&2
      exit 8
      ;;
  esac
}

validate_mode() {
  case "$PTT_MODE" in
    enter|hold)
      ;;
    *)
      echo "Unsupported --ptt-mode: $PTT_MODE (expected enter|hold)" >&2
      exit 8
      ;;
  esac
}

validate_insert_mode() {
  case "$INSERT_MODE" in
    file)
      RESOLVED_INSERT_MODE="file"
      ;;
    tmux)
      require_cmd tmux
      if [[ -z "${TMUX:-}" && -z "$TMUX_TARGET" ]]; then
        echo "--insert-mode tmux requires an active tmux session or --tmux-target." >&2
        exit 13
      fi
      RESOLVED_INSERT_MODE="tmux"
      ;;
    auto)
      if command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX:-}" || -n "$TMUX_TARGET" ]]; then
        RESOLVED_INSERT_MODE="tmux"
      else
        RESOLVED_INSERT_MODE="file"
      fi
      ;;
    *)
      echo "Unsupported --insert-mode: $INSERT_MODE (expected file|tmux|auto)" >&2
      exit 13
      ;;
  esac
}

fallback_hold_unavailable() {
  local reason="$1"
  reason="${reason//$'\n'/ }"

  if [[ "$HOLD_STRICT" == "1" ]]; then
    echo "Hold-key detection unavailable (${reason}). Re-run without --hold-strict to fall back to ENTER mode." >&2
    exit 10
  fi

  echo "⚠️  Hold-key detection unavailable (${reason}). Falling back to ENTER mode." >&2
  record_interactive_enter
}

audio_devices_output() {
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true
}

list_audio_devices() {
  local out
  out="$(audio_devices_output)"

  echo "🎤 Available avfoundation audio devices:"
  if grep -q "AVFoundation audio devices" <<<"$out"; then
    awk '/AVFoundation audio devices:/{show=1} /AVFoundation video devices:/{show=0} show{print}' <<<"$out" | grep "AVFoundation indev" || true
  else
    echo "$out"
  fi

  echo
  echo "Use --mic-index N or --mic-name TEXT with goose-voice-ptt.sh."
}

resolve_mic_name() {
  local query="$1"
  local out lower_query idx

  lower_query="$(printf "%s" "$query" | tr '[:upper:]' '[:lower:]')"
  out="$(audio_devices_output)"

  idx="$(awk -v needle="$lower_query" '
    /AVFoundation audio devices:/ {show=1; next}
    /AVFoundation video devices:/ {show=0}
    show && /AVFoundation indev/ {
      line=tolower($0)
      if (index(line, needle) > 0) {
        if (match($0, /\[[0-9]+\]/)) {
          print substr($0, RSTART + 1, RLENGTH - 2)
          exit
        }
      }
    }
  ' <<<"$out")"

  if [[ -z "$idx" ]]; then
    echo "No audio device matching --mic-name '$query'." >&2
    echo "Run goose-voice-ptt.sh --list-devices to inspect available indices." >&2
    exit 11
  fi

  MIC_INDEX="$idx"
  echo "🎤 Selected mic index ${MIC_INDEX} from name match: ${query}"
}

require_cmd ffmpeg

if [[ "$LIST_DEVICES" -eq 1 ]]; then
  list_audio_devices
  exit 0
fi

if [[ -n "$MIC_NAME" ]]; then
  resolve_mic_name "$MIC_NAME"
fi

validate_mode
validate_insert_mode

if [[ "$PTT_MODE" == "hold" ]]; then
  require_cmd swift
  if [[ ! -f "$KEYWATCH_SWIFT" ]]; then
    echo "Missing keywatch helper: $KEYWATCH_SWIFT" >&2
    exit 9
  fi
fi

if [[ "$PROVIDER" == "local" ]]; then
  require_cmd whisper-cli
elif [[ "$PROVIDER" == "command" ]]; then
  if [[ -z "$TRANSCRIBE_CMD" ]]; then
    echo "--provider command requires --transcribe-cmd" >&2
    exit 3
  fi
else
  echo "Unsupported provider: $PROVIDER (expected local|command)" >&2
  exit 3
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "✅ goose-voice-ptt dry run: configuration looks valid"
  echo "   Mic index: ${MIC_INDEX}"
  echo "   PTT mode: ${PTT_MODE} (key: ${PTT_KEY})"
  echo "   Insert mode: ${INSERT_MODE} -> ${RESOLVED_INSERT_MODE}"
  if [[ "$RESOLVED_INSERT_MODE" == "tmux" ]]; then
    if [[ -n "$TMUX_TARGET" ]]; then
      echo "   tmux target: ${TMUX_TARGET}"
    else
      echo "   tmux target: current pane"
    fi
  else
    echo "   Transcript file: ${TRANSCRIPT_FILE}"
  fi
  echo "   Provider: ${PROVIDER}"
  if [[ "$PROVIDER" == "local" ]]; then
    echo "   Model: ${MODEL_PATH}"
    echo "   Language: ${LANG}"
  else
    echo "   Command: ${TRANSCRIBE_CMD}"
  fi
  echo "   Auto-submit: ${AUTO_SUBMIT}"
  echo "   Clear status: ${CLEAR_STATUS}"
  echo "   Confirm before insert: ${CONFIRM}"
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
AUDIO_PATH="$WORK_DIR/clip.m4a"
WAV_PATH="$WORK_DIR/clip.wav"
OUT_PREFIX="$WORK_DIR/transcript"
FFMPEG_LOG="$WORK_DIR/ffmpeg.log"

record_fixed_duration() {
  status_line "⏺️  Recording ${DURATION}s from mic index ${MIC_INDEX}..."
  ffmpeg -y -f avfoundation -i ":${MIC_INDEX}" -t "$DURATION" -c:a aac -b:a 96k "$AUDIO_PATH" >"$FFMPEG_LOG" 2>&1
}

record_interactive_enter() {
  status_line "🎙️  Ready. Press ENTER to start recording (Ctrl+C cancels)."
  read -r
  status_input_line

  status_line "⏺️  Recording... press ENTER to stop (auto-stop at ${MAX_DURATION}s)."
  ffmpeg -y -f avfoundation -i ":${MIC_INDEX}" -t "$MAX_DURATION" -c:a aac -b:a 96k "$AUDIO_PATH" >"$FFMPEG_LOG" 2>&1 &
  local ffmpeg_pid=$!

  while kill -0 "$ffmpeg_pid" >/dev/null 2>&1; do
    if IFS= read -r -t 0.2 _; then
      status_input_line
      kill -INT "$ffmpeg_pid" >/dev/null 2>&1 || true
      break
    fi
  done

  wait "$ffmpeg_pid" || true
}

record_interactive_hold() {
  local key_code
  key_code="$(ptt_key_to_code "$PTT_KEY")"

  status_line "🎙️  Hold ${PTT_KEY} to record (Ctrl+C cancels; max ${MAX_DURATION}s)."

  local down_msg
  if ! down_msg="$(swift "$KEYWATCH_SWIFT" --mode down --key-code "$key_code" 2>&1)"; then
    fallback_hold_unavailable "$down_msg"
    return
  fi

  status_line "⏺️  Recording... release ${PTT_KEY} to stop."
  ffmpeg -y -f avfoundation -i ":${MIC_INDEX}" -t "$MAX_DURATION" -c:a aac -b:a 96k "$AUDIO_PATH" >"$FFMPEG_LOG" 2>&1 &
  local ffmpeg_pid=$!

  local up_msg
  if up_msg="$(swift "$KEYWATCH_SWIFT" --mode up --key-code "$key_code" --timeout "$MAX_DURATION" 2>&1)"; then
    kill -INT "$ffmpeg_pid" >/dev/null 2>&1 || true
  else
    local up_rc=$?
    up_msg="${up_msg//$'\n'/ }"
    if [[ "$up_rc" -eq 3 ]]; then
      echo "⏱️  Max duration reached before key release (${MAX_DURATION}s)." >&2
    elif [[ "$HOLD_STRICT" == "1" ]]; then
      kill -INT "$ffmpeg_pid" >/dev/null 2>&1 || true
      echo "Hold-key release detection failed (${up_msg}). Re-run without --hold-strict to continue with max-duration fallback." >&2
      exit 10
    else
      echo "⚠️  Hold-key release detection failed (${up_msg}). Continuing until max duration (${MAX_DURATION}s)." >&2
    fi
  fi

  wait "$ffmpeg_pid" || true
}

record_interactive() {
  if [[ "$PTT_MODE" == "hold" ]]; then
    record_interactive_hold
  else
    record_interactive_enter
  fi
}

transcribe_local() {
  if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Model file not found: $MODEL_PATH" >&2
    exit 4
  fi

  ffmpeg -y -i "$AUDIO_PATH" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV_PATH" >/dev/null 2>&1

  whisper-cli \
    -m "$MODEL_PATH" \
    -l "$LANG" \
    -f "$WAV_PATH" \
    -otxt \
    -of "$OUT_PREFIX" >/dev/null 2>&1

  local txt_path="${OUT_PREFIX}.txt"
  if [[ ! -f "$txt_path" ]]; then
    echo "Transcription failed: expected ${txt_path}" >&2
    exit 5
  fi

  cat "$txt_path"
}

transcribe_command() {
  # shellcheck disable=SC2086
  bash -lc "$TRANSCRIBE_CMD \"$AUDIO_PATH\""
}

write_transcript_file() {
  local text="$1"
  mkdir -p "$(dirname "$TRANSCRIPT_FILE")"
  printf "%s" "$text" >"$TRANSCRIPT_FILE"

  echo "✅ Transcript saved to: $TRANSCRIPT_FILE"
  echo "   Launch/return to Goose CLI and press ENTER to accept or edit the prefill."
  if [[ "$AUTO_SUBMIT" -eq 1 ]]; then
    echo "   Auto-submit requested via trailing 'submit'."
  fi
}

insert_transcript_tmux() {
  local text="$1"
  local -a target_args=()

  if [[ -n "$TMUX_TARGET" ]]; then
    target_args=(-t "$TMUX_TARGET")
  fi

  tmux set-buffer -- "$text"
  tmux paste-buffer -d "${target_args[@]}"
  if [[ "$AUTO_SUBMIT" -eq 1 ]]; then
    tmux send-keys "${target_args[@]}" Enter
  fi

  echo "✅ Transcript pasted into tmux pane${TMUX_TARGET:+ ($TMUX_TARGET)}."
  if [[ "$AUTO_SUBMIT" -eq 1 ]]; then
    echo "   Auto-submit requested via ENTER key in tmux."
  fi
}

if [[ -n "$DURATION" ]]; then
  record_fixed_duration
else
  record_interactive
fi

if [[ ! -s "$AUDIO_PATH" ]]; then
  echo "Recording failed (empty audio). See: $FFMPEG_LOG" >&2
  exit 6
fi

status_line "🧠 Transcribing (${PROVIDER})..."
if [[ "$PROVIDER" == "local" ]]; then
  TRANSCRIPT="$(transcribe_local)"
else
  TRANSCRIPT="$(transcribe_command)"
fi

TRANSCRIPT="$(printf "%s" "$TRANSCRIPT" | sed '/^[[:space:]]*$/d' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"

if [[ -z "$TRANSCRIPT" ]]; then
  echo "Transcription empty; not writing transcript file." >&2
  exit 7
fi

clear_status_lines

FILE_TRANSCRIPT="$TRANSCRIPT"
if [[ "$AUTO_SUBMIT" -eq 1 ]]; then
  FILE_TRANSCRIPT="${TRANSCRIPT} submit"
fi

if [[ "$PRINT_ONLY" -eq 1 ]]; then
  echo "$TRANSCRIPT"
  exit 0
fi

if [[ "$DISCARD" -eq 1 ]]; then
  echo "🗑️  Discarded transcript (not written)."
  echo "$TRANSCRIPT"
  exit 0
fi

if [[ "$CONFIRM" -eq 1 ]]; then
  if [[ -t 0 ]]; then
    local_target="Goose prompt file"
    if [[ "$RESOLVED_INSERT_MODE" == "tmux" ]]; then
      local_target="active tmux pane"
    fi

    echo
    read -r -p "Insert transcript into ${local_target}? [y/N] " confirm_answer
    case "${confirm_answer,,}" in
      y|yes)
        ;;
      *)
        echo "🗑️  Discarded transcript (confirmation declined)."
        echo "$TRANSCRIPT"
        exit 0
        ;;
    esac
  else
    echo "--confirm requires an interactive terminal (stdin is not a TTY)." >&2
    exit 12
  fi
fi

if [[ "$RESOLVED_INSERT_MODE" == "tmux" ]]; then
  if ! insert_transcript_tmux "$TRANSCRIPT"; then
    if [[ "$INSERT_MODE" == "tmux" ]]; then
      echo "tmux insertion failed; rerun with --insert-mode file or fix tmux target/session." >&2
      exit 14
    fi

    echo "⚠️  tmux insertion failed; falling back to transcript file mode." >&2
    write_transcript_file "$FILE_TRANSCRIPT"
  fi
else
  write_transcript_file "$FILE_TRANSCRIPT"
fi

echo
echo "Transcript:"
echo "$TRANSCRIPT"
