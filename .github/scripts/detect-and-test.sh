#!/usr/bin/env bash
# =============================================================================
# detect-and-test.sh — the deterministic verification gate.
#
# Auto-detects the stack(s) in the repo and runs install + lint + typecheck +
# tests + build for each. Exit 0 = GREEN, non-zero = RED. This script is the
# single source of truth for "the work is done, tested, and checked" — both
# the agents and the workflow call it.
#
# Override everything by setting VERIFY_COMMAND (the workflow's
# `verify_command` input), or edit the blocks below to match your project.
# =============================================================================
set -uo pipefail

if [ -n "${VERIFY_COMMAND:-}" ]; then
  echo "[verify] Using VERIFY_COMMAND override: $VERIFY_COMMAND"
  bash -c "$VERIFY_COMMAND"
  rc=$?
  [ "$rc" -eq 0 ] && echo "[verify] RESULT: GREEN — override command passed." \
                  || echo "[verify] RESULT: RED — override command failed (exit $rc)."
  exit "$rc"
fi

fail=0
detected=0
step() { echo; echo "== [verify] $* =="; }

# ------------------------------------------------------------------- Node ----
if [ -f package.json ]; then
  detected=1
  step "Node.js project detected"

  PM="npm"
  if [ -f pnpm-lock.yaml ]; then
    PM="pnpm"
    corepack enable >/dev/null 2>&1 || npm install -g pnpm >/dev/null 2>&1 || true
  elif [ -f yarn.lock ]; then
    PM="yarn"
    corepack enable >/dev/null 2>&1 || true
  fi

  step "Install dependencies ($PM)"
  case "$PM" in
    npm)  if [ -f package-lock.json ]; then npm ci || fail=1; else npm install || fail=1; fi ;;
    pnpm) pnpm install --frozen-lockfile || pnpm install || fail=1 ;;
    yarn) yarn install --frozen-lockfile || yarn install || fail=1 ;;
  esac

  has_script() { jq -e --arg s "$1" '.scripts[$s] // empty' package.json >/dev/null 2>&1; }

  if has_script lint; then
    step "Lint ($PM run lint)"
    "$PM" run lint || fail=1
  fi

  if [ -f tsconfig.json ] && npx --no-install tsc --version >/dev/null 2>&1; then
    step "Type check (tsc --noEmit)"
    npx --no-install tsc --noEmit || fail=1
  fi

  if has_script test; then
    step "Tests ($PM test)"
    "$PM" test || fail=1
  else
    echo "[verify] no test script in package.json — skipping Node tests"
  fi

  if has_script build; then
    step "Build ($PM run build)"
    "$PM" run build || fail=1
  fi
fi

# ----------------------------------------------------------------- Python ----
if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ]; then
  detected=1
  step "Python project detected"
  PY=python3

  step "Install dependencies"
  if [ -f requirements.txt ]; then "$PY" -m pip install -q -r requirements.txt || fail=1; fi
  if [ -f requirements-dev.txt ]; then "$PY" -m pip install -q -r requirements-dev.txt || true; fi
  if [ -f pyproject.toml ]; then
    "$PY" -m pip install -q -e ".[dev]" 2>/dev/null || "$PY" -m pip install -q -e . 2>/dev/null || true
  fi

  if "$PY" -m ruff --version >/dev/null 2>&1; then
    step "Lint (ruff check)"
    "$PY" -m ruff check . || fail=1
  elif command -v ruff >/dev/null 2>&1; then
    step "Lint (ruff check)"
    ruff check . || fail=1
  fi

  if "$PY" -m mypy --version >/dev/null 2>&1 && { [ -f mypy.ini ] || grep -q '^\[tool\.mypy\]' pyproject.toml 2>/dev/null; }; then
    step "Type check (mypy)"
    "$PY" -m mypy . || fail=1
  fi

  if [ -d tests ] || [ -f pytest.ini ] || grep -q '^\[tool\.pytest' pyproject.toml 2>/dev/null || ls test_*.py >/dev/null 2>&1; then
    "$PY" -m pytest --version >/dev/null 2>&1 || "$PY" -m pip install -q pytest || true
    step "Tests (pytest)"
    "$PY" -m pytest -x -q || fail=1
  else
    echo "[verify] no pytest config or tests/ directory — skipping Python tests"
  fi
fi

# --------------------------------------------------------------------- Go ----
if [ -f go.mod ]; then
  detected=1
  step "Go project detected"
  step "go vet";   go vet ./...   || fail=1
  step "go build"; go build ./... || fail=1
  step "go test";  go test ./...  || fail=1
fi

# ------------------------------------------------------------------- Rust ----
if [ -f Cargo.toml ]; then
  detected=1
  step "Rust project detected"
  step "cargo check"; cargo check --all-targets || fail=1
  step "cargo test";  cargo test               || fail=1
fi

# --------------------------------------------------------------- Makefile ----
if [ -f Makefile ] && grep -qE '^test:' Makefile; then
  detected=1
  step "Makefile test target (make test)"
  make test || fail=1
fi

# ----------------------------------------------------------------- result ----
echo
if [ "$detected" -eq 0 ]; then
  echo "[verify] RESULT: RED — could not detect a known stack (Node/Python/Go/Rust/Make)."
  echo "[verify] Pass the workflow's 'verify_command' input, or edit .github/scripts/detect-and-test.sh for this repo."
  exit 2
fi

if [ "$fail" -eq 0 ]; then
  echo "[verify] RESULT: GREEN — all detected checks passed."
  exit 0
else
  echo "[verify] RESULT: RED — one or more checks failed (see FAIL markers above)."
  exit 1
fi
