#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_SCRIPT="${SCRIPT_DIR}/goose-voice-ptt.sh"
GOOSE_BIN="${GOOSE_BIN:-goose}"
SESSION_KEY=""
TRANSCRIPT_FILE_OVERRIDE=""
PROVIDER_OVERRIDE=""
MODEL_OVERRIDE=""
LANG_OVERRIDE=""
DRY_RUN=0
GOOSE_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  goose-voice-ptt-session.sh [options] [-- goose session args...]

Launch goose with deterministic voice transcript env exports in one command,
without manual eval plumbing.

Options:
  --session-key KEY      pass through to goose-voice-ptt.sh --print-session-env
  --transcript-file PATH override transcript file export for this session launch
  --provider NAME        override voice provider export (local|command)
  --model PATH           override voice model export
  --lang CODE            override voice language export
  --goose-bin BIN        goose executable to launch (default: goose)
  --dry-run              print exports + target goose command and exit
  -h, --help             show help

Examples:
  # Start default goose CLI session with voice transcript env pre-wired
  scripts/goose-voice-ptt-session.sh

  # Use deterministic per-session transcript routing
  scripts/goose-voice-ptt-session.sh --session-key demo

  # Override transcript/provider settings for this launch
  scripts/goose-voice-ptt-session.sh --session-key demo --provider local --lang en

  # Start goose session with explicit goose args
  scripts/goose-voice-ptt-session.sh -- session -n voice-demo

  # Dry-run to inspect env + launch command
  scripts/goose-voice-ptt-session.sh --session-key demo --dry-run
EOF
}

if [[ ! -f "${VOICE_SCRIPT}" ]]; then
  echo "Missing voice script: ${VOICE_SCRIPT}" >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-key)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--session-key requires a non-empty identifier, e.g. --session-key demo." >&2
        exit 8
      fi
      SESSION_KEY="$2"
      shift 2
      ;;
    --transcript-file)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--transcript-file requires a writable file path." >&2
        exit 8
      fi
      TRANSCRIPT_FILE_OVERRIDE="$2"
      shift 2
      ;;
    --provider)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--provider requires local or command." >&2
        exit 8
      fi
      PROVIDER_OVERRIDE="$2"
      shift 2
      ;;
    --model)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--model requires a model path/string." >&2
        exit 8
      fi
      MODEL_OVERRIDE="$2"
      shift 2
      ;;
    --lang)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--lang requires a language code, e.g. en." >&2
        exit 8
      fi
      LANG_OVERRIDE="$2"
      shift 2
      ;;
    --goose-bin)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--goose-bin requires an executable name/path." >&2
        exit 8
      fi
      GOOSE_BIN="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      GOOSE_ARGS=("$@")
      break
      ;;
    *)
      GOOSE_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#GOOSE_ARGS[@]} -eq 0 ]]; then
  GOOSE_ARGS=(session)
fi

PRINT_ENV_CMD=("${VOICE_SCRIPT}" --print-session-env)
if [[ -n "${SESSION_KEY}" ]]; then
  PRINT_ENV_CMD+=(--session-key "${SESSION_KEY}")
fi
if [[ -n "${TRANSCRIPT_FILE_OVERRIDE}" ]]; then
  PRINT_ENV_CMD+=(--transcript-file "${TRANSCRIPT_FILE_OVERRIDE}")
fi
if [[ -n "${PROVIDER_OVERRIDE}" ]]; then
  PRINT_ENV_CMD+=(--provider "${PROVIDER_OVERRIDE}")
fi
if [[ -n "${MODEL_OVERRIDE}" ]]; then
  PRINT_ENV_CMD+=(--model "${MODEL_OVERRIDE}")
fi
if [[ -n "${LANG_OVERRIDE}" ]]; then
  PRINT_ENV_CMD+=(--lang "${LANG_OVERRIDE}")
fi

SESSION_EXPORTS="$("${PRINT_ENV_CMD[@]}")"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '%s\n' "${SESSION_EXPORTS}"
  printf 'Would run: '
  printf '%q ' "${GOOSE_BIN}" "${GOOSE_ARGS[@]}"
  printf '\n'
  exit 0
fi

# Session exports are produced by local goose-voice-ptt.sh as shell-safe export lines.
# shellcheck disable=SC1090
eval "${SESSION_EXPORTS}"

exec "${GOOSE_BIN}" "${GOOSE_ARGS[@]}"
