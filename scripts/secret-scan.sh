#!/usr/bin/env bash
# secret-scan.sh — аудит репозитория на секреты/приватные данные перед commit.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
FAIL=0
note_hit() { FAIL=1; echo "SECRET-SCAN HIT: $1"; }
scan_file() { # file allow_private_markers
  local f="$1"; shift
  local out
  # токеноподобные значения (кроме плейсхолдеров/переменных)
  out=$(grep -nE '(api[_-]?key|token|secret|password)["'"'"']?\s*[:=]\s*["'"'"']?[A-Za-z0-9_-]{20,}' "$f" 2>/dev/null | grep -viE 'example|placeholder|your[-_]|\$|<|\{\{|grep -E' || true)
  [ -n "$out" ] && note_hit "$f: $out"
  # известные форматы
  out=$(grep -nE 'sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-|-----BEGIN [A-Z ]*PRIVATE KEY' "$f" 2>/dev/null || true)
  [ -n "$out" ] && note_hit "$f: $out"
  # приватные маркеры (кроме examples/ и самого сканера)
  if [ "${1:-}" != "allow" ]; then
    out=$(grep -nE '/home/openclaw|127583377|ZAI_API_KEY=[^ ]|agonarena|AgonArena' "$f" 2>/dev/null | grep -v 'credentials.env' || true)
    [ -n "$out" ] && note_hit "$f: $out"
  fi
}
for f in $(git ls-files 2>/dev/null | grep -v '^examples/' | grep -v 'secret-scan.sh'); do scan_file "$f"; done
for f in $(git ls-files 'examples/*' 2>/dev/null); do scan_file "$f" allow; done
(( FAIL == 0 )) && echo "SECRET-SCAN: GREEN"
exit $FAIL
