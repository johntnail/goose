#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_SCRIPT="${SCRIPT_DIR}/goose-voice-ptt.sh"
GOOSE_BIN="${GOOSE_BIN:-goose}"
SESSION_KEY=""
DRY_RUN=0
GOOSE_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  goose-voice-ptt-session.sh [options] [-- goose session args...]

Launch goose with deterministic voice transcript env exports in one command,
without manual eval plumbing.

Options:
  --session-key KEY   pass through to goose-voice-ptt.sh --print-session-env
  --goose-bin BIN     goose executable to launch (default: goose)
  --dry-run           print exports + target goose command and exit
  -h, --help          show help

Examples:
  # Start default goose CLI session with voice transcript env pre-wired
  scripts/goose-voice-ptt-session.sh

  # Use deterministic per-session transcript routing
  scripts/goose-voice-ptt-session.sh --session-key demo

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

SESSION_EXPORTS="$(${PRINT_ENV_CMD[@]})"

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
