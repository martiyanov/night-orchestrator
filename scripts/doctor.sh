#!/usr/bin/env bash
# doctor.sh — диагностика установки без секретов и без касания production.
set -u
ROOT="${2:-}"
[[ "${1:-}" == "--root" ]] && ROOT="$2"
[ -n "$ROOT" ] || { echo "usage: doctor.sh --root <install-dir>"; exit 2; }
PASS=0; FAIL=0
ck() { if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ok: $1"; else FAIL=$((FAIL+1)); echo "  FAIL: $1"; fi; }
echo "== зависимости =="
ck bash    'command -v bash'
ck git     'command -v git'
ck jq      'command -v jq'
ck python3 'command -v python3'
echo "== установка ($ROOT) =="
ck "каталог существует" "[ -d '$ROOT' ]"
for f in bin/run_task.sh bin/gates.sh bin/intake.py bin/task.sh bin/selftest.sh; do
  ck "$f" "[ -f '$ROOT/$f' ]"
done
for d in runs intake; do
  if [ -d "$ROOT/$d" ]; then PASS=$((PASS+1)); echo "  ok: рабочий каталог $d/";
  elif [ -f "$ROOT/config/permissions.example.json" ] && [ ! -f "$ROOT/config/permissions.json" ]; then
    PASS=$((PASS+1)); echo "  ok: $d/ не создан (исходный репозиторий; появится при install)"
  else FAIL=$((FAIL+1)); echo "  FAIL: рабочий каталог $d/"; fi
done
echo "== контракты (JSON валиден) =="
for s in contracts/TASK.schema.json contracts/RESULT.schema.json contracts/INTAKE_STATE.schema.json; do
  ck "$s" "jq -e . '$ROOT/$s' >/dev/null"
done
echo "== конфигурация =="
PRM="$ROOT/config/permissions.json"; [ -f "$PRM" ] || PRM="$ROOT/config/permissions.example.json"
RTG="$ROOT/config/routing.json";     [ -f "$RTG" ] || RTG="$ROOT/config/routing.example.json"
CONF_NOTE=""
for c in permissions routing projects; do
  if [ -f "$ROOT/config/$c.json" ]; then
    ck "config/$c.json" "jq -e . '$ROOT/config/$c.json' >/dev/null"
  elif [ -f "$ROOT/config/$c.example.json" ]; then
    ck "config/$c.example.json (реальный конфиг ещё не создан)" "jq -e . '$ROOT/config/$c.example.json' >/dev/null"
    CONF_NOTE=1
  else
    ck "config/$c.json" false
  fi
done
if [ -n "$CONF_NOTE" ]; then
  echo "  ПРИМЕЧАНИЕ: найдены только example-конфиги — скопируйте их в config/*.json и настройте (docs/CONFIGURATION.md)."
fi
ck "execution_profile известен" "jq -e '.profiles[.execution_profile // \"balanced\"]' '$PRM' >/dev/null"
ck "DEPLOY_ENABLED задан" "jq -e 'has(\"DEPLOY_ENABLED\")' '$PRM' >/dev/null"
echo "== проекты реестра =="
REGF="$ROOT/config/projects.json"; [ -f "$REGF" ] || REGF="$ROOT/config/projects.example.json"
for p in $(jq -r 'keys[] | select(startswith("$")|not)' "$REGF" 2>/dev/null); do
  repo=$(jq -r --arg p "$p" '.[$p].repo' "$REGF")
  repo="${repo//\$HOME/$HOME}"
  if [ -d "$repo" ]; then PASS=$((PASS+1)); echo "  ok: проект $p: репозиторий ($repo)";
  elif [ "$repo" = "$HOME/src/example-project" ]; then PASS=$((PASS+1)); echo "  ok: проект $p — заглушка из example: укажите свой репозиторий в config/projects.json";
  elif [ "$REGF" = "$ROOT/config/projects.example.json" ]; then PASS=$((PASS+1)); echo "  ok: проект $p: репозиторий example — не найден, ожидаемо до настройки";
  else FAIL=$((FAIL+1)); echo "  FAIL: проект $p: репозиторий ($repo)"; fi
done
echo "== модели (роли назначены; без проверки ключей) =="
for r in explorer implementer strong_finalizer reviewer; do
  ck "роль $r" "jq -e --arg r \"$r\" '.roles[\$r].model' '$RTG' >/dev/null"
done
echo "== временный worktree =="
T=$(mktemp -d)
if git init -q "$T/probe" && git -C "$T/probe" -c user.email=d@d -c user.name=d commit -q --allow-empty -m x \
   && git -C "$T/probe" worktree add -q "$T/wt" -b probe >/dev/null 2>&1; then
  PASS=$((PASS+1)); echo "  ok: git worktree add (проверка на временном репо)"
else FAIL=$((FAIL+1)); echo "  FAIL: git worktree add"; fi
rm -rf "$T"
echo "== синтаксис =="
for f in "$ROOT"/bin/*.sh; do ck "bash -n $(basename "$f")" "bash -n '$f'"; done
echo
echo "DOCTOR: PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ] && echo "Рекомендация: bin/selftest.sh --full" || exit 1
