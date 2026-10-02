#!/usr/bin/env bash
# Ancroo Backend — local development helper
#
# Runs PostgreSQL + backend + runner with hot reload (see dev/compose.yml).
# If the ancroo-stack network "ai-network" exists, the dev containers join it
# and reach Ollama, Speaches and n8n from the stack.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_DIR="$ROOT/dev"
STACK_DIR="${ANCROO_STACK_DIR:-$ROOT/../ancroo-stack}"
STACK_NETWORK="ai-network"

# Optional overrides from dev/.env
if [[ -f "$DEV_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$DEV_DIR/.env"
  set +a
fi

BACKEND_URL="http://localhost:${DEV_BACKEND_PORT:-8900}"
VARIANT="${ANCROO_VARIANT:-cuda}"

info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

has_stack_network() {
  docker network inspect "$STACK_NETWORK" >/dev/null 2>&1
}

compose() {
  local files=(-f "$DEV_DIR/compose.yml")
  if has_stack_network; then
    files+=(-f "$DEV_DIR/compose.stack.yml")
  fi
  docker compose --project-directory "$DEV_DIR" "${files[@]}" "$@"
}

check_conflicts() {
  local name
  for name in ancroo-backend ancroo-runner; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
      warn "Stack container '$name' is running — it uses the same ports/hostnames."
      warn "Stop it first: docker stop $name"
    fi
  done
}

cmd_up() {
  check_conflicts
  if has_stack_network; then
    info "Stack network '$STACK_NETWORK' found — using Ollama/Speaches/n8n from ancroo-stack"
  else
    info "No stack network — external services via host.docker.internal (see dev/.env.example)"
  fi
  compose up -d --build "$@"
  info "Waiting for backend health..."
  local i
  for i in $(seq 1 60); do
    if curl -fsS "$BACKEND_URL/health" >/dev/null 2>&1; then
      info "Backend ready:  $BACKEND_URL"
      info "Admin UI:       $BACKEND_URL/admin/"
      info "API docs:       $BACKEND_URL/api/docs"
      info "Runner:         http://localhost:${DEV_RUNNER_PORT:-8510}/plugins"
      return 0
    fi
    sleep 1
  done
  warn "Backend did not become healthy within 60s — check: ./dev.sh logs dev-backend"
  return 1
}

cmd_stack() {
  # Start only the AI services the backend needs from ancroo-stack.
  [[ -d "$STACK_DIR" ]] || die "ancroo-stack not found at $STACK_DIR (set ANCROO_STACK_DIR)"
  info "Starting ollama, speaches, n8n from $STACK_DIR"
  (cd "$STACK_DIR" && docker compose up -d ollama speaches n8n)
}

cmd_import() {
  # Import example workflows in dependency order: category -> model/tool -> workflow.
  local dir="${1:-}"
  local dirs=()
  if [[ -n "$dir" ]]; then
    dirs=("$ROOT/workflows/$dir")
  else
    dirs=("$ROOT"/workflows/example-*/)
  fi

  local skip_variant
  case "$VARIANT" in
    cuda) skip_variant="rocm" ;;
    rocm) skip_variant="cuda" ;;
    *) die "ANCROO_VARIANT must be 'cuda' or 'rocm' (got '$VARIANT')" ;;
  esac

  local d f pattern status
  for d in "${dirs[@]}"; do
    d="${d%/}"
    [[ -d "$d" ]] || die "Workflow directory not found: $d"
    info "Importing $(basename "$d") ($VARIANT)"
    for pattern in "category*.json" "llm-model*.json" "stt-model*.json" "tool*.json" "workflow*.json"; do
      for f in "$d"/$pattern; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *"-$skip_variant.json" ]] && continue
        status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
          "$BACKEND_URL/admin/api/import" \
          -H "Content-Type: application/json" --data-binary "@$f")
        echo "    $(basename "$f") -> HTTP $status"
      done
    done
  done
}

cmd_reset() {
  read -r -p "Delete the dev database volume? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { info "Aborted"; return 0; }
  compose down -v
}

usage() {
  cat <<EOF
Usage: ./dev.sh <command> [args]

  up [service...]   Build and start the dev environment (hot reload)
  down              Stop and remove dev containers (keeps the database)
  restart [service] Restart services
  logs [service]    Follow logs (default: all)
  ps                Show dev container status
  stack             Start ollama, speaches, n8n from ancroo-stack
  import [dir]      Import example workflows (all example-* or one directory)
                    Model variant via ANCROO_VARIANT=cuda|rocm (default: cuda)
  psql              Open psql in the dev database
  reset             Remove containers AND the dev database volume
  compose [args]    Pass arguments to docker compose
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    up)      cmd_up "$@" ;;
    down)    compose down "$@" ;;
    restart) compose restart "$@" ;;
    logs)    compose logs -f --tail=100 "$@" ;;
    ps)      compose ps "$@" ;;
    stack)   cmd_stack ;;
    import)  cmd_import "$@" ;;
    psql)    compose exec dev-postgres psql -U ancroo ancroo ;;
    reset)   cmd_reset ;;
    compose) compose "$@" ;;
    ""|-h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
