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
for d in runs intake; do ck "рабочий каталог $d/" "[ -d '$ROOT/$d' ]"; done
echo "== контракты (JSON валиден) =="
for s in contracts/TASK.schema.json contracts/RESULT.schema.json contracts/INTAKE_STATE.schema.json; do
  ck "$s" "jq -e . '$ROOT/$s' >/dev/null"
done
echo "== конфигурация =="
for c in permissions routing projects; do
  ck "config/$c.json" "[ -f '$ROOT/config/$c.json' ] && jq -e . '$ROOT/config/$c.json' >/dev/null"
done
ck "execution_profile известен" "jq -e '.profiles[.execution_profile // \"balanced\"]' '$ROOT/config/permissions.json' >/dev/null"
ck "DEPLOY_ENABLED задан" "jq -e 'has(\"DEPLOY_ENABLED\")' '$ROOT/config/permissions.json' >/dev/null"
echo "== проекты реестра =="
for p in $(jq -r 'keys[] | select(startswith("$")|not)' "$ROOT/config/projects.json" 2>/dev/null); do
  repo=$(jq -r --arg p "$p" '.[$p].repo' "$ROOT/config/projects.json")
  ck "проект $p: репозиторий ($repo)" "[ -d \"\${repo//\\\$HOME/\$HOME}\" ]"
done
echo "== модели (роли назначены; без проверки ключей) =="
for r in explorer implementer strong_finalizer reviewer; do
  ck "роль $r" "jq -e --arg r \"$r\" '.roles[\$r].model' '$ROOT/config/routing.json' >/dev/null"
done
echo "== временный worktree =="
T=$(mktemp -d); ck "git worktree add" "git -C '$ROOT' rev-parse --git-dir >/dev/null 2>&1 || git init -q '$T/probe' && git -C '$T/probe' commit -q --allow-empty -m x 2>/dev/null; git -C '$T/probe' worktree add '$T/wt' -b probe >/dev/null 2>&1"; rm -rf "$T"
echo "== синтаксис =="
for f in "$ROOT"/bin/*.sh; do ck "bash -n $(basename "$f")" "bash -n '$f'"; done
echo
echo "DOCTOR: PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ] && echo "Рекомендация: bin/selftest.sh --full" || exit 1
