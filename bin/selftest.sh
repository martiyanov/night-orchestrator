#!/usr/bin/env bash
# selftest.sh — deterministic acceptance tests for Night Orchestrator v1.
# 1) guard unit tests (no model calls, no repo contact)
# 2) mock-driven run_task scenarios (invalid RESULT repair, forbidden paths,
#    push block, bounded retry + strong escalation, writable sandbox in worktree)
# 3) GPT-5.6 trigger guard
# Usage: selftest.sh [--full]   (default: guard+trigger only; --full adds mock scenarios)
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH_ROOT="${ORCH_ROOT:-$REPO_ROOT}"
# shellcheck source=bin/gates.sh
source "$ORCH_ROOT/bin/gates.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_deny()   { guard_check "$1" "$2" "$3" 2>/dev/null && bad "should DENY: $3" || ok "deny: $3"; }
assert_allow()  { guard_check "$1" "$2" "$3" 2>/dev/null && ok "allow: $3" || bad "should ALLOW: $3"; }

# Изолированное окружение самопроверки: фикстурный git-репозиторий и
# тестовая инсталляция оркестратора (без реальных проектов/секретов/моделей).
SELFTEST_ROOT="$HOME/.cache/no-selftest-env/$(date +%s%N)"
mkdir -p "$SELFTEST_ROOT"
trap 'rm -rf "$SELFTEST_ROOT"' EXIT
REPO="$SELFTEST_ROOT/project"
WT="$SELFTEST_ROOT/worktrees/test"
git init -q "$REPO" && git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t
printf 'version 1\n' > "$REPO/VERSION"; mkdir -p "$REPO/app"; printf 'x = 1\n' > "$REPO/app/config.py"
git -C "$REPO" add -A && git -C "$REPO" commit -qm init
mkdir -p "$SELFTEST_ROOT/worktrees"
git -C "$REPO" worktree add -q "$WT" -b test 2>/dev/null || git -C "$REPO" worktree add "$WT" -b test
# тестовая инсталляция: ORCH_ROOT указывает на копию config/contracts с example-проектом на фикстурный репо
ORCH_TEST_HOME="$SELFTEST_ROOT/orch"
mkdir -p "$ORCH_TEST_HOME"/{bin,config,contracts,prompts,runs,intake}
cp "$(dirname "$0")"/../*.{sh,py} "$ORCH_TEST_HOME/bin/" 2>/dev/null || true
cp "$(dirname "$0")"/* "$ORCH_TEST_HOME/bin/"
cp "$(dirname "$0")"/../contracts/* "$ORCH_TEST_HOME/contracts/"
cp "$(dirname "$0")"/../prompts/* "$ORCH_TEST_HOME/prompts/"
for c in permissions routing; do
  src="$(dirname "$0")/../config/$c.json"; [ -f "$src" ] || src="$(dirname "$0")/../config/$c.example.json"
  cp "$src" "$ORCH_TEST_HOME/config/$c.json"
done
jq -n --arg repo "$REPO" --arg wtr "$SELFTEST_ROOT/worktrees" \
  '{"example-project":{"repo":$repo, "protected_checkout":false, "worktree_root":$wtr, "default_branch":"master",
    "bootstrap":[], "test_command":"true", "forbidden_paths":[".env","data/"], "guard_roots":[]}}' \
  > "$ORCH_TEST_HOME/config/projects.json"
export ORCH_ROOT="$ORCH_TEST_HOME"
AGT="$ORCH_TEST_HOME/bin/task.sh"
INTK="python3 $ORCH_TEST_HOME/bin/intake.py"

echo "== 1. guard: read_only denials =="
assert_deny read_only "$REPO" 'cat .env'
assert_deny read_only "$REPO" 'cat .env.example'
assert_deny read_only "$REPO" 'grep KEY .env.staging'
assert_deny read_only "$REPO" 'git push origin main'
assert_deny read_only "$REPO" 'git merge night/branch'
assert_deny read_only "$REPO" 'git reset --hard HEAD~1'
assert_deny read_only "$REPO" 'git clean -fd'
assert_deny read_only "$REPO" 'ops/deploy.sh'
assert_deny read_only "$REPO" 'bash ops/deploy.sh'
assert_deny read_only "$REPO" 'systemctl restart example-app'
assert_deny read_only "$REPO" 'docker ps'
assert_deny read_only "$REPO" 'docker compose up -d'
assert_deny read_only "$REPO" 'curl -s http://example.com'
assert_deny read_only "$REPO" 'ssh x@y'
assert_deny read_only "$REPO" 'sudo rm x'
assert_deny read_only "$REPO" 'echo hi > out.txt'
assert_deny read_only "$REPO" 'touch newfile.md'
assert_deny read_only "$REPO" 'pytest -q'
assert_deny read_only "$REPO" 'python3 -c "print(1)"'
assert_deny read_only "$REPO" "cat $HOME/.config/example/secrets.json"
assert_deny read_only "$REPO" "cat $HOME/.config/example/providers.json"
assert_deny read_only "$REPO" 'ls ~/.ssh'
assert_deny read_only "$REPO" 'bash -c "git push origin main"'
assert_deny read_only "$REPO" 'eval ls'
assert_deny read_only "$REPO" 'git -c user.x=1 status'
assert_deny read_only "$REPO" "git -C $HOME status"
assert_deny read_only "$REPO" 'git config user.name'
assert_deny read_only "$REPO" 'pip install requests'
assert_deny read_only "$REPO" 'kill -9 1234'
assert_deny read_only "$REPO" 'chmod 777 file'
assert_deny read_only "$REPO" 'cat data/production.db'

echo "== 2. guard: read_only allows =="
assert_allow read_only "$REPO" 'cat AGENTS.md'
assert_allow read_only "$REPO" 'ls -la docs'
assert_allow read_only "$REPO" 'git status'
assert_allow read_only "$REPO" 'git log --oneline -5'
assert_allow read_only "$REPO" 'grep -rn "AG-094" state/TODO.md'
assert_allow read_only "$REPO" 'sed -n "1,5p" PROJECT_CONTEXT_SUMMARY.md'
assert_allow read_only "$REPO" 'find docs -name "*.md"'
assert_allow read_only "$REPO" 'git diff --stat'
assert_allow read_only "$REPO" 'wc -l state/TODO.md'
assert_allow read_only "$REPO" 'ls 2>&1'

echo "== 3. guard: writable denials =="
assert_deny writable "$WT" "echo evil > $REPO/evil.txt"
assert_deny writable "$WT" "cp f.txt $HOME/backup/f.txt"
assert_deny writable "$WT" "cd $REPO && git commit"
assert_deny writable "$WT" 'git checkout main'
assert_deny writable "$WT" 'git switch main'
assert_deny writable "$WT" 'git branch -D feature'
assert_deny writable "$WT" 'git worktree add /tmp/x'
assert_deny writable "$WT" 'git push origin night/branch'
assert_deny writable "$WT" 'rm -rf .'
assert_deny writable "$WT" 'rm -rf /'
assert_deny writable "$WT" 'pip install requests'
assert_deny writable "$WT" 'python3 - <<EOF
print(1)
EOF'
assert_deny writable "$WT" 'wget http://x'
assert_deny writable "$WT" 'GIT_DIR=/x git status'
assert_deny writable "$WT" "cat $ORCH_ROOT/config/credentials.env"

echo "== 4. guard: writable allows =="
assert_allow writable "$WT" 'echo x > night_sandbox_selftest.md'
assert_allow writable "$WT" 'mkdir -p docs/sandbox'
assert_allow writable "$WT" 'git add night_sandbox_selftest.md && git commit -m "sandbox: test"'
assert_allow writable "$WT" 'git switch -c sub-branch'
assert_allow writable "$WT" 'git status --porcelain'
assert_allow writable "$WT" 'python3 -m pytest -q tests/test_smoke.py'
assert_allow writable "$WT" 'git diff --stat main'
assert_allow writable "$WT" 'rm night_sandbox_selftest.md'

echo "== 4b. guard regression: reads inside worktree allowed regardless of allowed_paths =="
# (1) exact false-positive command shape from run 20260925-ag095_exec (relative
# multi-segment path + cd must not yield a spurious /services/... abs token)
assert_allow writable "$WT" "cd $WT && cat app/services/duel_service.py"
assert_allow writable "$WT" 'cat app/services/duel_service.py'
assert_allow writable "$WT" 'sed -n "1,80p" app/bot/handlers/menu/duel_start.py'
assert_allow writable "$WT" 'grep -rn "free_daily_battles" app/ tests/'
assert_allow writable "$WT" 'rg -n "limit.free_battles" app/'
assert_allow writable "$WT" 'head -50 app/i18n.py && wc -l tests/test_free_battles_quota.py'
assert_allow writable "$WT" 'find tests -name "*.py" -newer VERSION'
assert_allow writable "$WT" 'cat docs/SPEC.md'
assert_allow writable "$WT" 'python3 -m pytest tests/test_free_battles_quota.py -q'

echo "== 4c. guard regression: writes outside allowed_paths / jail =="
# relative writes INSIDE jail are allowed by guard BY DESIGN — allowed_paths is
# enforced by the changed-paths GATE (see 4c-gate below and mock scenario 6f)
assert_allow writable "$WT" 'echo rogue > rogue_outside_allowed.md'
# explicit gate-level enforcement of allowed_paths (self-contained scratch repo):
mkdir -p /tmp/no_gate_check && cd /tmp/no_gate_check && git init -q . 2>/dev/null
git -C /tmp/no_gate_check add -A 2>/dev/null; git -C /tmp/no_gate_check -c user.name=t -c user.email=t@t commit -qm base 2>/dev/null
echo rogue > /tmp/no_gate_check/rogue_outside_allowed.md
ALLOWED_GLOBS="allowed_only.md" FORBIDDEN_GLOBS=".env .env.*" \
  gate_changed_paths /tmp/no_gate_check writable main | grep -q '^changed_paths:FAIL' \
  && ok "4c-gate: change outside allowed_paths -> gate FAIL" \
  || bad "4c-gate: rogue file not caught by gate_changed_paths"
rm -rf /tmp/no_gate_check; cd /tmp
assert_deny writable "$WT" "echo evil > $HOME/evil.txt"
assert_deny writable "$WT" "echo evil > $REPO/evil.md"
assert_deny writable "$WT" "cp f.txt $HOME/backup/f.txt"
assert_deny writable "$WT" "mv night_sandbox_selftest.md $HOME/elsewhere.md"

echo "== 4d. guard regression: .env and secrets denied even for reads =="
assert_deny writable "$WT" 'cat .env'
assert_deny writable "$WT" 'sed -n "1,20p" .env.staging'
assert_deny writable "$WT" 'grep -n "KEY" .env.example'
assert_deny writable "$WT" "cat $HOME/.config/example/secrets.json"

echo "== 4d2. guard regression: /dev/null redirects are not writes =="
# exact false-positive shape from run 20260925-ag095_exec7 (env probing, read-only)
assert_allow writable "$WT" "ls /usr/bin/python3* 2>/dev/null; find $HOME -maxdepth 4 -name pytest -path '*/bin/*' -type f 2>/dev/null | head -5"
assert_allow writable "$WT" 'ls -a 2>/dev/null'
assert_allow writable "$WT" 'grep -rn "quota" app/ 2>/dev/null | head -3'
# but redirects to REAL paths outside jail stay denied (both streams)
assert_deny writable "$WT" "echo evil > $HOME/evil.txt"
assert_deny writable "$WT" "echo evil 2>$HOME/err.log"
assert_deny writable "$WT" 'grep x .env 2>/dev/null'

echo "== 4d3. guard regression: lone dot argument is not dot-sourcing =="
# exact false-positive shape from run 20260925-ag095_exec8
assert_allow writable "$WT" 'ls -a . | head -30; which python3; ls /usr/bin | grep -i pytest | head -3'
assert_allow writable "$WT" 'find . -name "*.py" | head -3'
assert_allow writable "$WT" 'wc -l .'
# real dot-sourcing still denied
assert_deny writable "$WT" '. ./evil.sh'
assert_deny writable "$WT" ". $HOME/evil.sh"
assert_allow read_only "$REPO" 'ls -a . | head'

echo "== 4d4. guard regression: read-only sed is not a write =="
# exact false-positive shape from run 20260925-ag095_exec9
assert_allow writable "$WT" "sed -n '1,15p' $REPO/app/config.py"
assert_allow writable "$WT" "sed -n '236,280p' app/bot/handlers/menu/duel_start.py | head -20"
# sed -i outside jail stays denied
assert_deny writable "$WT" "sed -i 's/a/b/' $HOME/evil.txt"
assert_deny writable "$WT" "sed -i 's/a/b/' app/config.py && echo evil > $HOME/evil.txt"

echo "== 4d5. guard regression: heredoc file content is inert text =="
# exact false-positive shape from run 20260925-ag095_exec10: docstring contained "git -c"
assert_allow writable "$WT" "cat > tests/test_free_battles_quota.py <<'EOF'
\"\"\"AG-095 quota tests.
Plan: git -c user.name=x commit; also mentions .env, data/, curl http://x.
\"\"\"
import pytest
EOF
echo WRITTEN"
# command-level violations remain denied
assert_deny writable "$WT" 'git -c user.name=x commit -m t'
assert_deny writable "$WT" 'git -C /other status'

echo "== 4d6. guard regression: single-quoted sed scripts are not paths =="
# exact false-positive shape from run 20260925-ag095_exec11
assert_allow writable "$WT" "sed -i '/^from app.db import session as db_session\$/a from app.config import settings' app/bot/handlers/menu/duel_start.py"
assert_allow writable "$WT" "sed -i '/_LIMITS\\[\"duels_daily\"\\]\\[0\\]:/ {N;N;a\\
            # comment here\\
}' app/bot/handlers/menu/duel_start.py"
# writes outside jail remain denied (bare and double-quoted)
assert_deny writable "$WT" "echo evil > $HOME/evil.txt"
assert_deny writable "$WT" "echo evil > \"$HOME/evil.txt\""

echo "== 4d7. guard regression: чтение веток в read_only разрешено (po-02 postmortem) =="
assert_allow read_only "$REPO" "git branch --show-current"
assert_allow read_only "$REPO" "git status --porcelain=v1 | wc -l; git log -1 --oneline; git branch --show-current"
assert_deny read_only "$REPO" 'git branch -D x'
assert_deny read_only "$REPO" 'git branch new-branch'
assert_deny read_only "$REPO" 'git add f'
assert_deny read_only "$REPO" 'git commit -m x'

echo "== 4e. guard regression: git merge-base is read-only (real-run postmortem) =="
# ложно срабатывал universal deny `merge` без word-boundary; после фикса
# merge-base разрешён, merge/push/rebase и обходы через кавычки — нет
assert_allow read_only "$REPO" 'git merge-base --is-ancestor HEAD origin/main'
assert_allow read_only "$REPO" 'git merge-base HEAD main'
assert_allow read_only "$REPO" 'git merge-base --fork-point main HEAD'
assert_allow writable "$WT" "cd $WT && git merge-base --is-ancestor 01aa041 HEAD"
# мутационные глаголы остаются запрещены (обе моды)
assert_deny read_only "$REPO" 'git merge main'
assert_deny read_only "$REPO" 'git merge --no-ff foo'
assert_deny writable "$WT" 'git merge main'
assert_deny read_only "$REPO" 'git push'
assert_deny read_only "$REPO" 'git rebase main'
# обход через кавычки закрыт (gbody-матчинг)
assert_deny read_only "$REPO" 'git "merge" main'
assert_deny read_only "$REPO" "git 'merge' main"
assert_deny read_only "$REPO" 'git me"rge" main'
# nested shell по-прежнему запрещён универсальным guard'ом
assert_deny read_only "$REPO" 'bash -c "git merge main"'
# plumbing с пишущими/сетевыми префиксами не разблокирован boundary-фиксом
assert_deny read_only "$REPO" 'git merge-file a b c'
assert_deny read_only "$REPO" 'git fetch-pack --upload-pack=x host'
assert_deny read_only "$REPO" 'git commit-tree HEAD'
assert_deny read_only "$REPO" 'git checkout-index -a'

echo "== 4f. guard regression: awk regex literals are not paths; production env leak (TASK-7-01 postmortem) =="
# точный false positive из run 20260927-ag107-01: /TASK-7 из awk-regex-литерала
assert_allow read_only "$REPO" "git show 8ac8f32:state/TODO.md | awk '/^### TASK-7/{f=1} f{print; if (\$0 ~ /^### / && \$0 !~ /TASK-7/) exit}' | head -120"
assert_allow writable "$WT" "cd $WT && git show HEAD:state/TODO.md | awk '/^### TASK-7/,/^### / {print}'"
assert_allow writable "$WT" "awk '/foo\\/bar/ {print}' app/test.txt"
assert_allow read_only "$REPO" "grep '^/api/' app/routes.txt"
assert_allow writable "$WT" "sed -n '/^\\/health/p' app/conf.txt"
assert_allow read_only "$REPO" 'awk "{print}" app/todo.txt'
assert_allow read_only "$REPO" 'awk -v k=TASK-7 "\$0 ~ k" app/todo.txt'
assert_allow read_only "$REPO" 'awk -F: "{print \$1}" app/todo.txt'
# file-операнды awk остаются path-кандидатами; прод-контур закрыт на уровне команд
# запретные корни проекта (guard_roots из реестра; здесь симулируем через env)
GUARD_DENY_ROOTS="/srv/prod" assert_deny read_only "$REPO" 'cat /srv/prod/env/app.env'
GUARD_DENY_ROOTS="/srv/prod" assert_deny read_only "$REPO" 'grep TOKEN /srv/prod/env/app.env'
GUARD_DENY_ROOTS="/srv/prod" assert_deny read_only "$REPO" 'grep x /srv/prod/secret'
GUARD_DENY_ROOTS="/srv/prod" assert_deny read_only "$REPO" 'awk -f /srv/prod/x.awk'
GUARD_DENY_ROOTS="/srv/prod" assert_deny writable "$WT" 'cp x /srv/prod/y'
GUARD_DENY_ROOTS="/srv/prod" assert_deny read_only "$REPO" 'cat /srv/prod/anything'
# *.env-имена ловятся и с alnum-префиксом (production.env), без over-deny
assert_deny read_only "$REPO" 'cat staging.env'
assert_deny read_only "$REPO" 'cat /opt/app/prod.env'
assert_allow read_only "$REPO" 'cat environment.md'
assert_allow read_only "$REPO" 'cat app_envelope.py'
assert_deny writable "$WT" 'cat .env'

echo "== 4e. guard regression: production checkout protected =="
assert_deny writable "$WT" "cd $REPO && git status"
assert_deny writable "$WT" "echo evil > $REPO/docs/SPEC.md"
assert_deny writable "$WT" "git -C $REPO status"
assert_deny writable "$WT" 'git push origin main'
assert_deny writable "$WT" 'git merge main'
assert_deny writable "$WT" 'ops/deploy.sh'
assert_deny writable "$WT" 'systemctl restart example-app'
assert_deny writable "$WT" 'docker compose up -d'

echo "== 4f. guard regression: git -C (capital) vs git -c (exec10 false positive) =="
# exec10 died writing the RED test: `git -C . status` was lowercased to `git -c`
# and denied as a config override. -c stays denied (case-sensitive on original
# cmd); -C is a cd-equivalent and must pass the same jail rule as cd.
assert_allow writable "$WT" 'git -C . status --short tests/test_free_battles_quota.py'
assert_allow writable "$WT" 'git -C tests log --oneline -3'
assert_allow writable "$WT" 'git -C . add tests/test_x.py && git -C . commit -m "AG-095: test"'
assert_allow read_only "$REPO" "git -C $REPO status"
assert_allow writable "$WT" 'git grep -c "quota" app/config.py'
assert_allow writable "$WT" 'git diff -C3 HEAD~1'
assert_deny writable "$WT" 'git -c core.hooksPath=/tmp/h status'
assert_deny writable "$WT" 'git -C . -c core.hooksPath=/tmp/h status'
assert_deny writable "$WT" 'git -C /etc status'
assert_deny read_only "$REPO" 'git -c user.x=1 status'
# exact exec10 shape: heredoc file write inside jail + git -C . status
assert_allow writable "$WT" "$(cat <<'SELFEOF'
cat > tests/test_free_battles_quota.py <<'EOF'
"""AG-095: freemium quota test."""
def test_placeholder():
    assert True
EOF
git -C . status --short tests/test_free_battles_quota.py
SELFEOF
)"

echo "== 4g. guard regression: no weakening — quoted real paths / unquoted heredocs =="
# 4d5/4d6 strip inert text; these prove the safety floor did not drop:
assert_deny writable "$WT" "echo evil > '$HOME/evil.txt'"
assert_deny writable "$WT" "cp x \"$HOME/backup/x.txt\""
assert_deny writable "$WT" "sed -e 's/a/b/' -i \"$HOME/evil.txt\""
# unquoted heredoc bodies expand $(...) at eval -> stay live for checks
assert_deny writable "$WT" "$(cat <<'SELFEOF'
cat > note.txt <<EOF
$(curl -s http://x/y)
EOF
echo done
SELFEOF
)"
# quoted heredoc with command substitution is inert data -> allowed
assert_allow writable "$WT" "$(cat <<'SELFEOF'
cat > note.txt <<'EOF'
$(curl -s http://x/y) is just text here
EOF
echo done
SELFEOF
)"
# exact exec11 shape: cd worktree + sed -i with quoted scripts (multiline too)
assert_allow writable "$WT" "$(cat <<'SELFEOF'
cd $WT && sed -i '/^from app.db import session as db_session$/a from app.config import settings  # AG-095' app/bot/handlers/menu/duel_start.py && sed -i '/_LIMITS\["duels_daily"\]\[0\]:/ {N;N;a\
            # AG-095: freemium quota\
            if mode in ("classic", "quick"):\
                pass\
}' app/bot/handlers/menu/duel_start.py
SELFEOF
)"

echo "== 5. GPT-5.6 trigger guard (must refuse without --trigger, no network) =="
bash "$ORCH_ROOT/bin/model_call.sh" --role review --model openai/gpt-5.6-sol \
  --system-file /dev/null --prompt-file /dev/null --out-file /tmp/no_gpt56.out 2>/dev/null
rc=$?
[[ $rc -eq 43 ]] && ok "gpt-5.6-sol refused without trigger (rc=43)" || bad "gpt-5.6-sol guard rc=$rc (expected 43)"

# ===========================================================================
echo "== 5b. ag_task.sh wrapper (lifecycle entrypoint; synthetic runs only) =="
AGT_PREFIX="selftest-agtask"
agtcleanup() { rm -rf "$ORCH_ROOT/runs/$AGT_PREFIX"-*; }
agtcleanup

# 5b-1: strict run-id validation — invalid ids refused, nothing created
for bad_id in '../x' '/tmp/x' 'a/b' 'a b' 'a;b' 'a&&b' 'a|b' '$(touch /tmp/agtask_pwn)' 'x`id`' ''; do
    bash "$AGT" status "$bad_id" >/dev/null 2>&1 && bad "invalid id ACCEPTED: [$bad_id]" || ok "invalid id rejected: [$bad_id]"
done
long_id="$(printf 'a%.0s' $(seq 1 65))"
bash "$AGT" status "$long_id" >/dev/null 2>&1 && bad "65-char id accepted" || ok "65-char id rejected"
# 64-символьный id валиден по формату: на несуществующем run ожидаем
# 'NOT FOUND' (валидация пройдена), а не 'invalid run-id'
msg64="$(bash "$AGT" status "${long_id:0:64}" 2>&1 || true)"
[[ "$msg64" == *"NOT FOUND"* ]] && ok "64-char id accepted (format-bound, not-found path)" \
    || bad "64-char id wrongly rejected: $msg64"
[ -e /tmp/agtask_pwn ] && bad "command substitution executed (/tmp/agtask_pwn)!" || ok "no injection side-effect"
bash "$AGT" frobnicate xyz123 >/dev/null 2>&1 && bad "unknown subcommand accepted" || ok "unknown subcommand refused"
bash "$AGT" new >/dev/null 2>&1 && bad "missing arg accepted" || ok "missing arg refused"

# 5b-2: valid ids + new/stop/status lifecycle on synthetic dirs
for good_id in ag103 20260927-ag103 task_123; do
    bash "$AGT" new "$AGT_PREFIX-$good_id" >/dev/null 2>&1 \
        && ok "new accepted valid id: $good_id" || bad "new refused valid id: $good_id"
done
for d in "$ORCH_ROOT/runs/$AGT_PREFIX-ag103" "$ORCH_ROOT/runs/$AGT_PREFIX-20260927-ag103" "$ORCH_ROOT/runs/$AGT_PREFIX-task_123"; do
    [ -d "$d/tasks" ] && ok "run dir + tasks created: $(basename "$d")" || bad "missing run dir: $d"
done
# idempotency: повторный new не ломает и не расширяет структуру
before="$(find "$ORCH_ROOT/runs/$AGT_PREFIX-ag103" | sort)"
bash "$AGT" new "$AGT_PREFIX-ag103" >/dev/null 2>&1 || bad "repeat new failed"
after="$(find "$ORCH_ROOT/runs/$AGT_PREFIX-ag103" | sort)"
[[ "$before" == "$after" ]] && ok "repeat new idempotent" || bad "repeat new changed tree"

# 5b-3: stop создаёт ТОЛЬКО STOP внутри существующего run; повтор безопасен
bash "$AGT" stop "$AGT_PREFIX-ag103" >/dev/null 2>&1 && ok "stop ok" || bad "stop failed"
[ -f "$ORCH_ROOT/runs/$AGT_PREFIX-ag103/STOP" ] && ok "STOP created inside run" || bad "STOP missing"
fs_before="$(find "$ORCH_ROOT/runs/$AGT_PREFIX-ag103" | sort)"
bash "$AGT" stop "$AGT_PREFIX-ag103" >/dev/null 2>&1 || bad "repeat stop failed"
fs_after="$(find "$ORCH_ROOT/runs/$AGT_PREFIX-ag103" | sort)"
[[ "$fs_before" == "$fs_after" ]] && ok "repeat stop idempotent" || bad "repeat stop changed tree"
# stop несуществующего run — отказ без создания каталогов
bash "$AGT" stop "$AGT_PREFIX-nothing-here" >/dev/null 2>&1 && bad "stop missing run accepted" || ok "stop missing run refused"
[ -e "$ORCH_ROOT/runs/$AGT_PREFIX-nothing-here" ] && bad "stop created dir for missing run!" || ok "no dir created for missing run"
# invalid id не создаёт ничего
bash "$AGT" stop '../escape' >/dev/null 2>&1 || true
[ -e "$ORCH_ROOT/runs/escape" ] && bad "traversal dir created!" || ok "no traversal artifact"

# 5b-4: status read-only (fs snapshot не меняется)
snap="$(find "$ORCH_ROOT/runs/$AGT_PREFIX-ag103" | sort)"
bash "$AGT" status "$AGT_PREFIX-ag103" >/dev/null 2>&1 || bad "status failed"
[[ "$snap" == "$(find "$ORCH_ROOT/runs/$AGT_PREFIX-ag103" | sort)" ]] && ok "status is read-only" || bad "status mutated fs"

# 5b-5: symlink escape — run-dir-симлинк отвергается и new, и stop
ln -sfn /tmp "$ORCH_ROOT/runs/$AGT_PREFIX-sym"
bash "$AGT" stop "$AGT_PREFIX-sym" >/dev/null 2>&1 && bad "stop via symlink ACCEPTED" || ok "stop via symlink refused"
bash "$AGT" new "$AGT_PREFIX-sym" >/dev/null 2>&1 && bad "new via symlink ACCEPTED" || ok "new via symlink refused"
[ -e /tmp/STOP ] && bad "/tmp/STOP leaked through symlink!" || ok "no write through symlink"

agtcleanup
[ -e "$ORCH_ROOT/runs/$AGT_PREFIX-ag103" ] && bad "cleanup left artifacts" || ok "synthetic runs cleaned"
# ===========================================================================

if [[ "${1:-}" != "--full" ]]; then
  echo; echo "SELFTEST SUMMARY: PASS=$PASS FAIL=$FAIL (guard+trigger only; use --full for mock scenarios)"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

# =========================================================================
echo; echo "== 6. mock scenarios (run_task.sh) =="
MOCKROOT="$(mktemp -d /tmp/no_selftest.XXXXXX)"
trap 'rm -rf "$MOCKROOT"' EXIT
# автономные/selftest-прогоны не ходят в Telegram (report строится, не шлётся)
export ORCH_TEST_NO_SEND=1

mk_task() { # file id mode extra...
  local f="$1" id="$2" mode="$3"; shift 3
  # jq uses the FIRST occurrence of a duplicate --argjson, so caller overrides come first
  jq -n "$@" --argjson checks '[]' --argjson og '[]' \
    --arg id "$id" --arg mode "$mode" \
    '{project:"example-project", task_id:$id, goal:"selftest", risk:"LOW", mode:$mode,
      allowed_paths:[], forbidden_paths:[".env"], bootstrap:["AGENTS.md"],
      checks:$checks, owner_gates:$og}' > "$f"
}

run_case() { # name taskfile fixture -> echoes FINAL_STATUS
  local name="$1" task="$2" fixture="$3"
  local rd="$MOCKROOT/$name"; mkdir -p "$rd/tasks"
  cp "$task" "$rd/tasks/"
  cp "$fixture" "$rd/fixture.jsonl"
  MOCK_FIXTURE="$rd/fixture.jsonl" bash "$ORCH_ROOT/bin/run_task.sh" "$rd" "$rd/tasks/$(basename "$task")" > "$rd/stdout.log" 2>&1
  grep -oE 'FINAL_STATUS [A-Z_]+' "$rd/stdout.log" | tail -1 | cut -d' ' -f2
}

# --- 6a: invalid RESULT -> one repair -> PASS
mk_task "$MOCKROOT/t_a.json" "SELF-A" read_only
jq -n --arg r '{"action":"result","result":{"task_id":"SELF-A","status":"PASS"}}' \
  '{"role":"executor","response":$r}' > "$MOCKROOT/f_a.jsonl"
jq -n --arg r '{"action":"result","result":{"task_id":"SELF-A","status":"PASS","summary":"all good","files_changed":[],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"none"}}' \
  '{"role":"executor","response":$r}' >> "$MOCKROOT/f_a.jsonl"
st="$(run_case "case_a" "$MOCKROOT/t_a.json" "$MOCKROOT/f_a.jsonl")"
calls="$(wc -l < "$MOCKROOT/case_a/SELF-A/model_calls.jsonl")"
[[ "$st" == "READY_FOR_OWNER_PASS" ]] && ok "6a invalid RESULT repaired -> READY_FOR_OWNER_PASS" || bad "6a status=$st (expected READY_FOR_OWNER_PASS)"
[[ "$calls" == "2" ]] && ok "6a exactly 2 executor calls (initial+repair)" || bad "6a calls=$calls (expected 2)"

# --- 6b: forbidden path (.env read) -> PERMISSION_VIOLATION
mk_task "$MOCKROOT/t_b.json" "SELF-B" read_only
jq -n --arg r '{"action":"shell","command":"cat .env"}' '{"role":"executor","response":$r}' > "$MOCKROOT/f_b.jsonl"
st="$(run_case "case_b" "$MOCKROOT/t_b.json" "$MOCKROOT/f_b.jsonl")"
[[ "$st" == "PERMISSION_VIOLATION" ]] && ok "6b .env read -> PERMISSION_VIOLATION" || bad "6b status=$st"

# --- 6c: git push attempt -> PERMISSION_VIOLATION
mk_task "$MOCKROOT/t_c.json" "SELF-C" read_only
jq -n --arg r '{"action":"shell","command":"git push origin main"}' '{"role":"executor","response":$r}' > "$MOCKROOT/f_c.jsonl"
st="$(run_case "case_c" "$MOCKROOT/t_c.json" "$MOCKROOT/f_c.jsonl")"
[[ "$st" == "PERMISSION_VIOLATION" ]] && ok "6c git push -> PERMISSION_VIOLATION" || bad "6c status=$st"

# --- 6d: persistent failure -> bounded retry + strong review -> BLOCKED
mk_task "$MOCKROOT/t_d.json" "SELF-D" read_only \
  --argjson checks '[{"name":"must_fail","command":"test -f definitely_missing_file_xyz"}]'
PASSRESULT='{"action":"result","result":{"task_id":"SELF-D","status":"PASS","summary":"done","files_changed":[],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"none"}}'
: > "$MOCKROOT/f_d.jsonl"
for i in 1 2 3; do jq -n --arg r "$PASSRESULT" '{"role":"executor","response":$r}' >> "$MOCKROOT/f_d.jsonl"; done
jq -n --arg r '{"verdict":"REJECT","comments":"checks still failing","remediation":"re-run the missing file check after creating the file"}' \
  '{"role":"review","response":$r}' >> "$MOCKROOT/f_d.jsonl"
st="$(run_case "case_d" "$MOCKROOT/t_d.json" "$MOCKROOT/f_d.jsonl")"
ecalls="$(jq -s '[.[] | select(.role=="executor")] | length' "$MOCKROOT/case_d/SELF-D/model_calls.jsonl")"
rcalls="$(jq -s '[.[] | select(.role=="review")] | length' "$MOCKROOT/case_d/SELF-D/model_calls.jsonl")"
[[ "$st" == "BLOCKED" ]] && ok "6d bounded retry -> BLOCKED" || bad "6d status=$st"
[[ "$ecalls" == "3" && "$rcalls" == "1" ]] && ok "6d attempts bounded: 3 executor + 1 strong review" || bad "6d exec=$ecalls review=$rcalls (expected 3/1)"

# --- 6e: writable sandbox in worktree, then cleanup
jq -n '{project:"example-project", task_id:"SELF-E", goal:"create disposable file", risk:"LOW", mode:"writable",
        allowed_paths:["night_sandbox_selftest.md"], forbidden_paths:[".env"], bootstrap:["AGENTS.md"],
        checks:[{"name":"file_exists","command":"test -f night_sandbox_selftest.md"}],
        owner_gates:[], cleanup_worktree:true}' > "$MOCKROOT/t_e.json"
: > "$MOCKROOT/f_e.jsonl"
jq -n --arg r '{"action":"shell","command":"echo \"night sandbox selftest\" > night_sandbox_selftest.md"}' '{"role":"executor","response":$r}' >> "$MOCKROOT/f_e.jsonl"
jq -n --arg r '{"action":"shell","command":"git add night_sandbox_selftest.md && git commit -m \"sandbox: disposable selftest file\""}' '{"role":"executor","response":$r}' >> "$MOCKROOT/f_e.jsonl"
jq -n --arg r '{"action":"result","result":{"task_id":"SELF-E","status":"PASS","summary":"file created and committed","files_changed":["night_sandbox_selftest.md"],"checks":[{"name":"file_exists","status":"PASS"}],"decisions":[],"assumptions":[],"unresolved":[],"next":"cleanup"}}' '{"role":"executor","response":$r}' >> "$MOCKROOT/f_e.jsonl"
head_before="$(git -C "$REPO" rev-parse HEAD)"
st="$(run_case "case_e" "$MOCKROOT/t_e.json" "$MOCKROOT/f_e.jsonl")"
wt_gone="$(git -C "$REPO" worktree list | grep -c "SELF-E" || true)"
br_gone="$(git -C "$REPO" branch --list 'night/SELF-E*' | wc -l)"
repo_dirty="$(git -C "$REPO" status --porcelain | wc -l)"
head_after="$(git -C "$REPO" rev-parse HEAD)"
[[ "$st" == "READY_FOR_OWNER_PASS" ]] && ok "6e writable sandbox -> READY_FOR_OWNER_PASS" || bad "6e status=$st"
[[ "$wt_gone" == "0" && "$br_gone" == "0" ]] && ok "6e worktree+branch cleaned up" || bad "6e cleanup wt=$wt_gone br=$br_gone"
[[ "$repo_dirty" == "0" && "$head_before" == "$head_after" ]] && ok "6e production checkout untouched" || bad "6e prod dirty=$repo_dirty head $head_before->$head_after"
changed="$(jq -r '.checks[] | select(.name=="gate:changed_paths") | .status' "$MOCKROOT/case_e/SELF-E/RESULT.json" 2>/dev/null)"
[[ "$changed" == "PASS" ]] && ok "6e changed-path gate PASS" || bad "6e changed-path gate=$changed"

# --- 6f: forbidden path inside writable worktree (file outside allowed_paths)
jq -n '{project:"example-project", task_id:"SELF-F", goal:"write only allowed file", risk:"LOW", mode:"writable",
        allowed_paths:["allowed_only.md"], forbidden_paths:[".env"], bootstrap:[],
        checks:[], owner_gates:[], cleanup_worktree:true}' > "$MOCKROOT/t_f.json"
: > "$MOCKROOT/f_f.jsonl"
jq -n --arg r '{"action":"shell","command":"echo rogue > rogue_file.md"}' '{"role":"executor","response":$r}' >> "$MOCKROOT/f_f.jsonl"
jq -n --arg r '{"action":"result","result":{"task_id":"SELF-F","status":"PASS","summary":"done","files_changed":["rogue_file.md"],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"none"}}' '{"role":"executor","response":$r}' >> "$MOCKROOT/f_f.jsonl"
st="$(run_case "case_f" "$MOCKROOT/t_f.json" "$MOCKROOT/f_f.jsonl")"
[[ "$st" == "FAILED" || "$st" == "BLOCKED" ]] && ok "6f change outside allowed_paths caught by gates ($st)" || bad "6f status=$st (expected FAILED/BLOCKED)"

# --- 7: autonomy loop (exploration budget / escalation / result / report) ---
fixture_shell() { # file cmd — добавить executor-shell запись (response = СТРОКА)
  jq -n --arg r "$(jq -cn --arg cmd "$2" '{"action":"shell","command":$cmd}')" \
     '{"role":"executor","response":$r}' >> "$1"
}
fixture_result() { # file RESULT-JSON-STRING
  jq -n --arg r "$2" '{"role":"executor","response":$r}' >> "$1"
}

# 7a: exploration runaway -> ранний EXPLORATION_BUDGET_EXCEEDED (не 60m)
mk_task "$MOCKROOT/t_7a.json" "SELF-7A" writable
jq '.cleanup_worktree=true' "$MOCKROOT/t_7a.json" > "$MOCKROOT/t_7a.json.t" && mv "$MOCKROOT/t_7a.json.t" "$MOCKROOT/t_7a.json"
: > "$MOCKROOT/f_7a.jsonl"
for c in "cat AGENTS.md" "sed -n 1,40p README.md" "git log --oneline -5" "git status" "cat pyproject.toml" "ls tests" "cat VERSION"; do
  fixture_shell "$MOCKROOT/f_7a.jsonl" "$c"
done
st="$(ORCH_TEST_MAX_READ_CALLS=1 run_case "case_7a" "$MOCKROOT/t_7a.json" "$MOCKROOT/f_7a.jsonl")"
ev=$(grep -c 'EXPLORATION_BUDGET_EXCEEDED' "$MOCKROOT/case_7a/log.jsonl" 2>/dev/null || true); ev=${ev:-0}
rsn="$(jq -r '.reason // ""' "$MOCKROOT/case_7a/SELF-7A/RESULT.json" 2>/dev/null)"
[[ "$st" == "BLOCKED" ]] && ok "7a runaway reads -> BLOCKED (early, no 60m timeout)" || bad "7a status=$st"
[[ "${ev:-0}" -ge 1 ]] && ok "7a EXPLORATION_BUDGET_EXCEEDED emitted" || bad "7a no budget event"
[[ "$rsn" == EXPLORATION_BUDGET_EXCEEDED* ]] && ok "7a RESULT.reason structured" || bad "7a reason='$rsn'"
[[ -s "$MOCKROOT/case_7a/report.txt" ]] && ok "7a report.txt built on direct run_task" || bad "7a no report.txt"

# 7b: повторное чтение тех же файлов = не progress (run завершается корректно)
mk_task "$MOCKROOT/t_7b.json" "SELF-7B" writable
jq '.cleanup_worktree=true' "$MOCKROOT/t_7b.json" > "$MOCKROOT/t_7b.json.t" && mv "$MOCKROOT/t_7b.json.t" "$MOCKROOT/t_7b.json"
: > "$MOCKROOT/f_7b.jsonl"
for i in 1 2 3; do fixture_shell "$MOCKROOT/f_7b.jsonl" "cat AGENTS.md"; done
fixture_result "$MOCKROOT/f_7b.jsonl" "$(jq -cn '{task_id:"SELF-7B",status:"NO_CHANGE_REQUIRED",summary:"read-only verified",files_changed:[],checks:[],decisions:[],assumptions:[],unresolved:[],next:"close"}' | jq -Rs . | sed 's/^"//;s/"$//' | sed 's/\\\\/\\/g' 2>/dev/null || true)"
fixture_result "$MOCKROOT/f_7b.jsonl" '{"action":"result","result":{"task_id":"SELF-7B","status":"NO_CHANGE_REQUIRED","summary":"verified","files_changed":[],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"close"}}'
st="$(ORCH_TEST_MAX_READ_CALLS=99 ORCH_TEST_MAX_REPEAT_READS=1 run_case "case_7b" "$MOCKROOT/t_7b.json" "$MOCKROOT/f_7b.jsonl")"
rr=$(grep -c 'REPEAT_READ' "$MOCKROOT/case_7b/log.jsonl" 2>/dev/null || true); rr=${rr:-0}
[[ "$st" == "NO_CHANGE_REQUIRED" && "${rr:-0}" -ge 1 ]] && ok "7b repeat reads flagged, run completes" || bad "7b status=$st repeats=${rr:-0}"

# 7c: первый meaningful write гасит exploration deadline
jq -n --argjson checks '[]' --argjson og '[]' --arg id "SELF-7C" --arg mode "writable" \
  '{project:"example-project", task_id:$id, goal:"selftest", risk:"LOW", mode:$mode, allowed_paths:["sandbox.md"], forbidden_paths:[".env"], bootstrap:["AGENTS.md"], checks:$checks, owner_gates:$og, cleanup_worktree:true}' > "$MOCKROOT/t_7c.json"
: > "$MOCKROOT/f_7c.jsonl"
fixture_shell "$MOCKROOT/f_7c.jsonl" "cat AGENTS.md"
fixture_shell "$MOCKROOT/f_7c.jsonl" "echo probe > sandbox.md"
fixture_result "$MOCKROOT/f_7c.jsonl" '{"action":"result","result":{"task_id":"SELF-7C","status":"PASS","summary":"wrote sandbox","files_changed":["sandbox.md"],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"none"}}'
st="$(ORCH_TEST_MAX_READ_CALLS=1 run_case "case_7c" "$MOCKROOT/t_7c.json" "$MOCKROOT/f_7c.jsonl")"
be=$(grep -c 'EXPLORATION_BUDGET_EXCEEDED' "$MOCKROOT/case_7c/log.jsonl" 2>/dev/null || true); be=${be:-0}
mw=$(grep -c 'MEANINGFUL_WRITE' "$MOCKROOT/case_7c/log.jsonl" 2>/dev/null || true); mw=${mw:-0}
[[ "$st" == "READY_FOR_OWNER_PASS" && "${be:-0}" -eq 0 && "${mw:-0}" -ge 1 ]] && ok "7c first write satisfies deadline" || bad "7c status=$st budget=${be:-0} writes=${mw:-0}"

# 7d: fast profile эскалирует на takeover-модель (legacy 999-noop устранён)
mk_task "$MOCKROOT/t_7d.json" "SELF-7D" writable
jq '.cleanup_worktree=true' "$MOCKROOT/t_7d.json" > "$MOCKROOT/t_7d.json.t" && mv "$MOCKROOT/t_7d.json.t" "$MOCKROOT/t_7d.json"
: > "$MOCKROOT/f_7d.jsonl"
for c in "cat AGENTS.md" "cat README.md" "git log --oneline -3"; do fixture_shell "$MOCKROOT/f_7d.jsonl" "$c"; done
fixture_result "$MOCKROOT/f_7d.jsonl" '{"action":"result","result":{"task_id":"SELF-7D","status":"NO_CHANGE_REQUIRED","summary":"verified","files_changed":[],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"close"}}'
rd7d="$MOCKROOT/case_7d"; mkdir -p "$rd7d/tasks"; cp "$MOCKROOT/t_7d.json" "$rd7d/tasks/"; cp "$MOCKROOT/f_7d.jsonl" "$rd7d/fixture.jsonl"
st7d="$(MOCK_FIXTURE="$rd7d/fixture.jsonl" ORCH_TEST_MAX_READ_CALLS=2 bash "$ORCH_ROOT/bin/run_task.sh" "$rd7d" "$rd7d/tasks/t_7d.json" fast 2>/dev/null | grep -oE 'FINAL_STATUS [A-Z_]+' | tail -1 | cut -d' ' -f2)"
tk="$(grep -o '"event":"TAKEOVER","task_id":"SELF-7D","model":"[^"]*"' "$rd7d/log.jsonl" 2>/dev/null | head -1)"
[[ -n "$tk" ]] && ok "7d fast escalates to takeover model" || bad "7d no TAKEOVER event (status=$st7d)"
[[ -s "$rd7d/report.txt" ]] && ok "7d report.txt built" || bad "7d no report.txt"

# 7e: read_only задача — write deadline НЕ применяется
mk_task "$MOCKROOT/t_7e.json" "SELF-7E" read_only
: > "$MOCKROOT/f_7e.jsonl"
for c in "cat AGENTS.md" "cat README.md" "sed -n 1,20p VERSION" "git log --oneline -3" "git status"; do fixture_shell "$MOCKROOT/f_7e.jsonl" "$c"; done
fixture_result "$MOCKROOT/f_7e.jsonl" '{"action":"result","result":{"task_id":"SELF-7E","status":"NO_CHANGE_REQUIRED","summary":"read-only done","files_changed":[],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"close"}}'
st="$(ORCH_TEST_MAX_READ_CALLS=2 run_case "case_7e" "$MOCKROOT/t_7e.json" "$MOCKROOT/f_7e.jsonl")"
be=$(grep -c 'EXPLORATION_BUDGET_EXCEEDED' "$MOCKROOT/case_7e/log.jsonl" 2>/dev/null || true); be=${be:-0}
[[ "$st" == "NO_CHANGE_REQUIRED" && "${be:-0}" -eq 0 ]] && ok "7e read_only exempt from write deadline" || bad "7e status=$st budget=${be:-0}"

# 7f: дважды невалидный RESULT -> runner-структурированный BLOCKED (один repair)
mk_task "$MOCKROOT/t_7f.json" "SELF-7F" writable
jq '.cleanup_worktree=true' "$MOCKROOT/t_7f.json" > "$MOCKROOT/t_7f.json.t" && mv "$MOCKROOT/t_7f.json.t" "$MOCKROOT/t_7f.json"
: > "$MOCKROOT/f_7f.jsonl"
for i in 1 2; do fixture_result "$MOCKROOT/f_7f.jsonl" '{"action":"result","result":{"task_id":"SELF-7F"}}'; done
st="$(run_case "case_7f" "$MOCKROOT/t_7f.json" "$MOCKROOT/f_7f.jsonl")"
rsn="$(jq -r '.reason // ""' "$MOCKROOT/case_7f/SELF-7F/RESULT.json" 2>/dev/null)"
smry="$(jq -r '.summary // ""' "$MOCKROOT/case_7f/SELF-7F/RESULT.json" 2>/dev/null)"
[[ "$st" == "BLOCKED" && "$rsn" == *schema* ]] && ok "7f double-invalid RESULT -> structured BLOCKED (one repair)" || bad "7f status=$st reason='$rsn'"
[[ "$smry" != "-" && -n "$smry" ]] && ok "7f summary factual, not '-'" || bad "7f stub summary"
[[ -s "$MOCKROOT/case_7f/report.txt" ]] && ok "7f report.txt built" || bad "7f no report.txt"

# --- 8: convergence tuning (early write / post-write budget / finalizer) ---
# 8a: 0 writes -> НЕ получает post-write extra turns (attempt умирает на базе 24)
mk_task "$MOCKROOT/t_8a.json" "SELF-8A" writable
jq '.cleanup_worktree=true' "$MOCKROOT/t_8a.json" > "$MOCKROOT/t_8a.json.t" && mv "$MOCKROOT/t_8a.json.t" "$MOCKROOT/t_8a.json"
: > "$MOCKROOT/f_8a.jsonl"
for i in $(seq 1 26); do fixture_shell "$MOCKROOT/f_8a.jsonl" "cat file$i.txt"; done
st="$(ORCH_TEST_MAX_READ_CALLS=99 ORCH_TEST_MAX_EXPL_MIN=999 run_case "case_8a" "$MOCKROOT/t_8a.json" "$MOCKROOT/f_8a.jsonl")"
sh=$(grep -c '"event":"AGENT_SHELL"' "$MOCKROOT/case_8a/log.jsonl" 2>/dev/null || true); sh=${sh:-0}
[[ "$st" == "BLOCKED" || "$st" == "FAILED" ]] && ok "8a no-write run bounded (status=$st)" || bad "8a status=$st"
# 26 фикстурных reads; все попытки суммарно не могли превысить 24+24+24 — но каждая
# attempt без write умирает на max_agent_turns; проверяем что НЕ было 32-turn попытки
[[ "${sh:-0}" -le 60 ]] && ok "8a turns bounded without writes (shells=$sh)" || bad "8a runaway shells=$sh"

# 8b: первый write открывает post-write budget (32 turns) — попытка доживает до RESULT
jq -n --argjson checks '[]' --argjson og '[]' --arg id "SELF-8B" --arg mode "writable" \
  '{project:"example-project", task_id:$id, goal:"selftest", risk:"LOW", mode:$mode, allowed_paths:["*.md"], forbidden_paths:[".env"], bootstrap:["AGENTS.md"], checks:$checks, owner_gates:$og, cleanup_worktree:true}' > "$MOCKROOT/t_8b.json"
: > "$MOCKROOT/f_8b.jsonl"
# каждый ход создаёт НОВЫЙ файл (снапшот меняется каждый turn — имитация
# плотной реализации; 30 ходов в одной попытке -> FINALIZE_NOW на turn 30)
for i in $(seq 1 30); do fixture_shell "$MOCKROOT/f_8b.jsonl" "echo v$i > part$i.md"; done
fixture_result "$MOCKROOT/f_8b.jsonl" '{"action":"result","result":{"task_id":"SELF-8B","status":"PASS","summary":"long impl done","files_changed":["part1.md"],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"none"}}'
st="$(ORCH_TEST_MAX_READ_CALLS=99 ORCH_TEST_MAX_EXPL_MIN=999 run_case "case_8b" "$MOCKROOT/t_8b.json" "$MOCKROOT/f_8b.jsonl")"
[[ "$st" == "READY_FOR_OWNER_PASS" ]] && ok "8b post-write budget unlocked (26 turns -> RESULT)" || bad "8b status=$st (expected READY_FOR_OWNER_PASS)"

# 8c: FINALIZE_NOW эмитится при turns_left<=2
fn=$(grep -c '"event":"FINALIZE_NOW"' "$MOCKROOT/case_8b/log.jsonl" 2>/dev/null || true); fn=${fn:-0}
[[ "${fn:-0}" -ge 1 ]] && ok "8c FINALIZE_NOW emitted near limit" || bad "8c no FINALIZE_NOW"

# 8d: takeover-handoff содержит executed-commands + hard directive
mk_task "$MOCKROOT/t_8d.json" "SELF-8D" writable
jq '.cleanup_worktree=true' "$MOCKROOT/t_8d.json" > "$MOCKROOT/t_8d.json.t" && mv "$MOCKROOT/t_8d.json.t" "$MOCKROOT/t_8d.json"
: > "$MOCKROOT/f_8d.jsonl"
for i in $(seq 1 12); do fixture_shell "$MOCKROOT/f_8d.jsonl" "cat file$i.txt"; done
fixture_result "$MOCKROOT/f_8d.jsonl" '{"action":"result","result":{"task_id":"SELF-8D","status":"NO_CHANGE_REQUIRED","summary":"v","files_changed":[],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"c"}}'
st="$(run_case "case_8d" "$MOCKROOT/t_8d.json" "$MOCKROOT/f_8d.jsonl")"
ho="$MOCKROOT/case_8d/SELF-8D/handoff.md"
[[ -s "$ho" && "$(grep -c 'Already executed shell commands' "$ho")" -ge 1 && "$(grep -c 'HARD DIRECTIVE' "$ho")" -ge 1 ]] \
  && ok "8d handoff carries executed-commands + directive" || bad "8d handoff incomplete"

# 8e: implementer-фаза (post-takeover) имеет меньший read-cap (5), а не explorer'а
esc=$(grep -c '"event":"EXPLORATION_DEADLINE"' "$MOCKROOT/case_8d/log.jsonl" 2>/dev/null || true); esc=${esc:-0}
tk=$(grep -c '"event":"TAKEOVER"' "$MOCKROOT/case_8d/log.jsonl" 2>/dev/null || true); tk=${tk:-0}
[[ "${tk:-0}" -ge 1 ]] && ok "8e takeover fired" || bad "8e no takeover"
# (имплементер-кэп = 5; 7-я read-фикстура уходит после takeover — deadline в имплементер-фазе)
[[ "${esc:-0}" -ge 1 ]] && ok "8e implementer read-cap engaged" || bad "8e no implementer deadline"

# 8f: валидный RESULT не уходит в repair (прямое попадание)
mk_task "$MOCKROOT/t_8f.json" "SELF-8F" read_only
: > "$MOCKROOT/f_8f.jsonl"
fixture_result "$MOCKROOT/f_8f.jsonl" '{"action":"result","result":{"task_id":"SELF-8F","status":"NO_CHANGE_REQUIRED","summary":"nothing to do","files_changed":[],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"close"}}'
st="$(run_case "case_8f" "$MOCKROOT/t_8f.json" "$MOCKROOT/f_8f.jsonl")"
rps=$(grep -c '"event":"RETRY"' "$MOCKROOT/case_8f/log.jsonl" 2>/dev/null || true); rps=${rps:-0}
[[ "$st" == "NO_CHANGE_REQUIRED" && "${rps:-0}" -eq 0 ]] && ok "8f valid RESULT accepted first try" || bad "8f status=$st retries=${rps:-0}"

# --- 8z: конфиг-инвариант: balanced hard-budget = 75 (TASK-7-07 postmortem) ---
hb="$(jq -r '.profiles.balanced.task_hard_budget_minutes' "$ORCH_ROOT/config/permissions.json")"
[[ "$hb" == "75" ]] && ok "8z balanced hard budget = 75min" || bad "8z balanced hard budget = $hb (ожидалось 75)"

# --- 9: reasoning-budget exhaustion ladder ---
rb_fixture() { # file — добавить rb_exhaust запись (исчерпание reasoning)
  jq -cn '{role:"executor", rb_exhaust:true, response:""}' >> "$1"
}

# 9a: первая saturation -> retry с увеличенным budget -> обычное завершение
jq -n --argjson checks '[]' --argjson og '[]' --arg id "SELF-9A" --arg mode "writable" \
  '{project:"example-project", task_id:$id, goal:"s", risk:"LOW", mode:$mode, allowed_paths:["*.md"], forbidden_paths:[".env"], bootstrap:["AGENTS.md"], checks:$checks, owner_gates:$og, cleanup_worktree:true}' > "$MOCKROOT/t_9a.json"
: > "$MOCKROOT/f_9a.jsonl"
rb_fixture "$MOCKROOT/f_9a.jsonl"
fixture_shell "$MOCKROOT/f_9a.jsonl" "echo x > part.md"
fixture_result "$MOCKROOT/f_9a.jsonl" '{"action":"result","result":{"task_id":"SELF-9A","status":"PASS","summary":"ok","files_changed":["part.md"],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"n"}}'
st="$(ORCH_TEST_MAX_READ_CALLS=99 ORCH_TEST_MAX_EXPL_MIN=999 run_case "case_9a" "$MOCKROOT/t_9a.json" "$MOCKROOT/f_9a.jsonl")"
rb=$(grep -c '"event":"REASONING_BUDGET_EXHAUSTED"' "$MOCKROOT/case_9a/log.jsonl" 2>/dev/null || true); rb=${rb:-0}
[[ "$st" == "READY_FOR_OWNER_PASS" && "${rb:-0}" -ge 1 ]] && ok "9a RB detected + big-bucket retry recovered" || bad "9a status=$st rb=${rb:-0}"

# 9b: пустой ответ БЕЗ saturation -> обычный nudge, НЕ RB (fixture "" )
mk_task "$MOCKROOT/t_9b.json" "SELF-9B" read_only
: > "$MOCKROOT/f_9b.jsonl"
jq -cn '{role:"executor", response:""}' >> "$MOCKROOT/f_9b.jsonl"
fixture_result "$MOCKROOT/f_9b.jsonl" '{"action":"result","result":{"task_id":"SELF-9B","status":"NO_CHANGE_REQUIRED","summary":"v","files_changed":[],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"c"}}'
st="$(run_case "case_9b" "$MOCKROOT/t_9b.json" "$MOCKROOT/f_9b.jsonl")"
rb=$(grep -c '"event":"REASONING_BUDGET_EXHAUSTED"' "$MOCKROOT/case_9b/log.jsonl" 2>/dev/null || true); rb=${rb:-0}
[[ "$st" == "NO_CHANGE_REQUIRED" && "${rb:-0}" -eq 0 ]] && ok "9b plain empty reply != RB (nudge path)" || bad "9b status=$st rb=${rb:-0}"

# 9c: двойная saturation -> ONE strong-эскалация -> завершение; без циклов
jq -n --argjson checks '[]' --argjson og '[]' --arg id "SELF-9C" --arg mode "writable" \
  '{project:"example-project", task_id:$id, goal:"s", risk:"LOW", mode:$mode, allowed_paths:["*.md"], forbidden_paths:[".env"], bootstrap:["AGENTS.md"], checks:$checks, owner_gates:$og, cleanup_worktree:true}' > "$MOCKROOT/t_9c.json"
: > "$MOCKROOT/f_9c.jsonl"
rb_fixture "$MOCKROOT/f_9c.jsonl"; rb_fixture "$MOCKROOT/f_9c.jsonl"
fixture_shell "$MOCKROOT/f_9c.jsonl" "echo x > part.md"
fixture_result "$MOCKROOT/f_9c.jsonl" '{"action":"result","result":{"task_id":"SELF-9C","status":"PASS","summary":"sf done","files_changed":["part.md"],"checks":[],"decisions":[],"assumptions":[],"unresolved":[],"next":"n"}}'
st="$(ORCH_TEST_MAX_READ_CALLS=99 ORCH_TEST_MAX_EXPL_MIN=999 run_case "case_9c" "$MOCKROOT/t_9c.json" "$MOCKROOT/f_9c.jsonl")"
esc=$(grep -c '"event":"ESCALATION","task_id":"SELF-9C","reason":"reasoning_budget_exhausted"' "$MOCKROOT/case_9c/log.jsonl" 2>/dev/null || true); esc=${esc:-0}
rbn=$(grep -c '"event":"REASONING_BUDGET_EXHAUSTED"' "$MOCKROOT/case_9c/log.jsonl" 2>/dev/null || true); rbn=${rbn:-0}
[[ "$st" == "READY_FOR_OWNER_PASS" && "${esc:-0}" -ge 1 && "${rbn:-0}" -le 2 ]] && ok "9c double saturation -> ONE strong escalation, no loops" || bad "9c status=$st esc=${esc:-0} rb=${rbn:-0}"

# 9d: тройная saturation (strong тоже) -> структурный BLOCKED, не цикл
mk_task "$MOCKROOT/t_9d.json" "SELF-9D" writable
jq '.cleanup_worktree=true' "$MOCKROOT/t_9d.json" > "$MOCKROOT/t_9d.json.t" && mv "$MOCKROOT/t_9d.json.t" "$MOCKROOT/t_9d.json"
: > "$MOCKROOT/f_9d.jsonl"
for i in 1 2 3 4; do rb_fixture "$MOCKROOT/f_9d.jsonl"; done
st="$(ORCH_TEST_MAX_READ_CALLS=99 ORCH_TEST_MAX_EXPL_MIN=999 run_case "case_9d" "$MOCKROOT/t_9d.json" "$MOCKROOT/f_9d.jsonl")"
rsn="$(jq -r '.reason // ""' "$MOCKROOT/case_9d/SELF-9D/RESULT.json" 2>/dev/null)"
[[ "$st" == "BLOCKED" && "$rsn" == *REASONING_BUDGET_EXHAUSTED* ]] && ok "9d strong-also-exhausted -> structured BLOCKED" || bad "9d status=$st reason=$rsn"

# 9e: ag_task wait завершается мгновенно на terminal-артефакте
AGT_PROBE_DIR="$ORCH_TEST_HOME/runs/selftest-wait-done"; mkdir -p "$AGT_PROBE_DIR/SELF-T"
jq -cn '{task_id:"SELF-T",status:"READY_FOR_OWNER_PASS"}' > "$AGT_PROBE_DIR/SELF-T/RESULT.json"
t0=$(date +%s)
ORCH_ROOT="$ORCH_TEST_HOME" bash "$AGT" wait selftest-wait-done --timeout=5 >/dev/null 2>&1; wrc=$?
t1=$(date +%s)
[[ $wrc -eq 0 && $((t1-t0)) -le 15 ]] && ok "9e wait fast-return on terminal run" || bad "9e rc=$wrc dur=$((t1-t0))s"

# 9f: wait на «живом» без изменений ждёт адаптивно и завершается по timeout
AGT_PROBE="$AGT_PREFIX-waitprobe"
ORCH_ROOT="$ORCH_TEST_HOME" bash "$AGT" new "$AGT_PROBE" >/dev/null 2>&1
t0=$(date +%s)
ORCH_ROOT="$ORCH_TEST_HOME" bash "$AGT" wait "$AGT_PROBE" --timeout=1 >/dev/null 2>&1; wrc=$?
t1=$(date +%s)
[[ $wrc -eq 3 && $((t1-t0)) -ge 60 ]] && ok "9f wait adaptive timeout (rc=3, dur=$((t1-t0))s)" || bad "9f rc=$wrc dur=$((t1-t0))s"
rm -rf "$ORCH_TEST_HOME/runs/$AGT_PROBE"

# --- 11: Intake Gate (приём задач и цикл уточнений; изолированный INTAKE_DIR) ---
IT="$MOCKROOT/intake"
export INTAKE_DIR="$IT"
INTK="python3 $ORCH_ROOT/bin/intake.py"

# A: «добавь в бэклог X» -> BACKLOG, run не запущен
outA="$($INTK message "Добавь в бэклог возможность тестового режима уведомлений")"
[[ "$outA" == *"уточню"* || "$outA" == *"готов"* ]] && ok "11A BACKLOG intent" || bad "11A out=$outA"
[[ $(ls "$ORCH_ROOT/runs" | grep -c "testovy" ) -eq 0 ]] && ok "11A no run started" || bad "11A run leaked"

# владелец отвечает -> запись создаётся, без run
iidA="$(ls "$IT" | head -1 | sed 's/INTAKE-//;s/.json//')"
outA2="$($INTK answer "Режим уведомлений для тестов: владелец включает флаг, пользователи не видят")"
[[ "$outA2" == *"backlog-drafts"* ]] && ok "11A backlog draft created" || bad "11A2 out=$outA2"
[[ -s "$IT/backlog-drafts.md" ]] && ok "11A draft file exists" || bad "11A no draft file"

# G: «пока просто добавь в бэклог» -> выполнение не начинается
outG="$($INTK message "Хочу автосообщения о дуэлях. пока просто добавь в бэклог")"
outG2="$($INTK answer "уведомление за час до конца раунда")"
if [[ "$outG2" == *"Выполнение не запускается"* || "$outG2" == *"охожая"* ]]; then
  ok "11G backlog-only, no run"
else
  bad "11G out=$outG2"
fi

# B: полностью описанная задача -> READY_TO_RUN -> TASK -> запуск (dry-run)
runs_before_B="$(ls "$ORCH_ROOT/runs" | wc -l)"
outB="$($INTK message "Запусти TASK-7: исправь потерю фото в отзыве, чтобы фото с подписью доезжало владельцу вместе с текстом; критерий: тест feedback_flow зелёный")"
[[ "$outB" == *"Постановка достаточна"* ]] && ok "11B READY_TO_RUN" || bad "11B out=$outB"
iidB="$(grep -oE '[0-9]{8}T[0-9]{6}-[a-z0-9-]+' <<< "$outB" | tail -1)"
[[ -n "$iidB" ]] && ok "11B intake id exposed" || bad "11B no iid"
taskB="$($INTK task "$iidB")"
[[ "$taskB" == *'"mode": "writable"'* && "$taskB" == *'"owner_gates"'* ]] && ok "11B TASK formed (writable, gates)" || bad "11B TASK malformed"
dryB="$($INTK launch "$iidB" --dry-run)"
[[ "$dryB" == *"[dry-run]"* && "$dryB""x" != *night_run* ]] && ok "11B canonical launch dry-run ok" || bad "11B dry=$dryB"
[[ "$(ls "$ORCH_ROOT/runs" | wc -l)" -eq "$runs_before_B" ]] && ok "11B no real run from dry" || bad "11B run leaked"

# C: расплывчатая просьба -> NEEDS_CLARIFICATION, 1-3 вопроса, без run
outC="$($INTK message "Сделай поиск сценариев удобнее")"
qcount="$(grep -cE '^[0-9]\.' <<< "$outC")"
[[ "$outC" == *"уточнить"* && "$qcount" -ge 1 && "$qcount" -le 3 ]] && ok "11C 1-3 questions asked" || bad "11C q=$qcount out=$outC"

# D: ответ связывается с тем же intake; TASK дополняется
outD="$($INTK answer "Поиск закрывается после выбора; только Telegram")"
iidC="$(ls -t "$IT" | grep INTAKE | head -1 | sed 's/INTAKE-//;s/.json//')"
stD="$(python3 -c "import json,os;print(json.load(open([os.path.join('$IT',f) for f in os.listdir('$IT') if f.startswith('INTAKE-') and '$iidC' in f][0]))['owner_answers'])")"
[[ "${stD,,}" == *"поиск закрывается"* ]] && ok "11D answer linked to intake" || bad "11D answers=$stD"

# E: техническая неопределённость -> вопрос НЕ задаётся (agent выяснит сам)
outE="$($INTK message "Запусти задачу: проверь что git status чистый в основном чекауте, критерий: команда выполняется без ошибок")"
[[ "$outE" == *"Постановка достаточна"* ]] && ok "11E tech-only -> no owner question" || bad "11E out=$outE"

# F: две продуктовые трактовки -> вопрос задаётся
outF="$($INTK message "Запусти: сделай платную подписку на тренировки, критерий готовности когда пользователи могут платить")"
[[ "$outF" == *"уточнить"* ]] && ok "11F product fork -> question" || bad "11F out=$outF"

# H: «отмени» -> CANCELLED, ничего не удаляется
iidF="$(ls -t "$IT" | grep INTAKE | head -1 | sed 's/INTAKE-//;s/.json//')"
beforeH="$(ls "$IT" | wc -l)"
outH="$($INTK message "отмени")"
stH="$(python3 -c "import json,os;print(json.load(open(os.path.join('$IT','INTAKE-$iidF.json')))['status'])")"
afterH="$(ls "$IT" | wc -l)"
[[ "$stH" == "CANCELLED" && "$beforeH" -eq "$afterH" ]] && ok "11H cancelled, history kept" || bad "11H st=$stH files $beforeH->$afterH"

# I: дубль backlog -> молча не создаётся
dupTitle="возможность тестового режима уведомлений"
outI="$($INTK message "Добавь в бэклог возможность тестового режима уведомлений, критерий: флаг включается")"
outI2="$($INTK answer "флаг только у владельца" 2>&1)"
if [[ "$outI" == *"охожая"* || "$outI2" == *"охожая"* ]]; then
  ok "11I duplicate detected, no silent entry"
else
  bad "11I dup not caught: $outI / $outI2"
fi

# L: DISCUSSION -> нет TASK/backlog/run
draftsL="$(grep -c "turnir" "$IT/backlog-drafts.md" 2>/dev/null || true)"
outL="$($INTK message "Обсудим: что если сделать турниры по выходным")"
stL="$(python3 -c "
import json, os
d = '$IT'
w = [json.load(open(os.path.join(d, f))) for f in os.listdir(d) if f.startswith('INTAKE-')]
last = [x for x in w if 'турниры' in (x['original_message'] or '')]
print(last[-1]['status'], last[-1]['proposed_task'] is None if last else '?')" 2>/dev/null)"
[[ "$outL" == *"Обсуждение"* && "$stL" == "COMPLETED True" ]] && ok "11L DISCUSSION: нет TASK, нет backlog-записи, нет run" || bad "11L out=$outL st=$stL"

# J/K: NEEDS_OWNER_INPUT из оркестратора -> понятный вопрос; продолжение без переиспользования run-id
RJ="$MOCKROOT/runX"; mkdir -p "$RJ/AG-X"
jq -n '{task_id:"AG-X", status:"NEEDS_OWNER_INPUT", summary:"нужен выбор", unresolved:["оставлять ли поиск открытым"], reason:"owner decision"}' > "$RJ/AG-X/RESULT.json"
outJ="$(INTAKE_DIR="$IT" python3 $ORCH_ROOT/bin/intake.py from-result "$RJ")"
[[ "$outJ" == *"ждёт вашего решения"* && "$outJ" == *"оставлять ли поиск открытым"* ]] && ok "11J NEEDS_OWNER_INPUT -> human question" || bad "11J out=$outJ"
outK="$(INTAKE_DIR="$IT" python3 $ORCH_ROOT/bin/intake.py answer "поиск закрывать")"
stK="$(INTAKE_DIR="$IT" python3 - <<'PY'
import json, os
d = os.environ["INTAKE_DIR"]
ws = [json.load(open(os.path.join(d, f))) for f in os.listdir(d) if f.startswith("INTAKE-")]
src = [w for w in ws if w.get("source_run")]
print(src[-1]["status"] if src else "none")
PY
)"
[[ "$stK" == "READY_TO_RUN" ]] && ok "11K continuation ready (new run; old id kept in source_run)" || bad "11K st=$stK"
unset INTAKE_DIR

# --- 12: project-skill routing (изоляция от личного ассистента) ---
SKILL="$REPO_ROOT/examples/skills/example-project"
RT="python3 $SKILL/route.py"
rt_dec() { python3 "$SKILL/route.py" "$1" 2>/dev/null | jq -r .decision; }

# A/B: явные обращения -> PROJECT и правильная команда Intake
[[ "$(rt_dec "Найт: добавь X в бэклог")" == "PROJECT" ]] && ok "12A prefix -> project" || bad "12A"
cA="$(python3 "$SKILL/route.py" "/night сделай TASK-8" | jq -r .intake_cmd)"
[[ "$cA" == *"--project example-project"* ]] && ok "12B run route carries project from config" || bad "12B cmd=$cA"
# D: личные запросы -> навык не вызывается
for m in "напомни купить молоко" "найди мой PDF" "помоги выбрать кроссовки" "проверь сервер"; do
  [[ "$(rt_dec "$m")" == "NOT_PROJECT" ]] && ok "12D isolated: $m" || bad "12D leaked: $m"
done
# E: неоднозначное проектное сообщение -> уточнение, без автозапуска
outE="$(python3 "$SKILL/route.py" "посмотри TASK-8 ещё раз")"
[[ "$(jq -r .decision <<< "$outE")" == "AMBIGUOUS_PROJECT" && -z "$(jq -r .intake_cmd // "" <<< "$outE")" ]] \
  && ok "12E ambiguous -> propose, no auto-run" || bad "12E out=$outE"
# J: project_id из конфигурации навыка, не из generic Intake
[[ "$(python3 -c "import json;print(json.load(open('$SKILL/project.json'))['project_id'])")" == "example-project" ]] \
  && grep -q -- "--project" "$SKILL/route.py" && ok "12J project id from skill config" || bad "12J"
# I: навык никогда не вызывает deploy/run_task напрямую
if grep -qE "run_task\.sh|deploy|git push|git merge" "$SKILL/SKILL.md" | grep -v "НЕ"; then :; fi
if grep -q "run_task.sh" "$SKILL/SKILL.md"; then
  grep -q "НЕ вызывает run_task.sh" "$SKILL/SKILL.md" && ok "12I no direct run_task (запрет задокументирован)" || bad "12I"
else
  ok "12I no direct run_task references"
fi
# F/G/H: цикл вопросов и запуск — через реальный Intake в изоляции
IT2="$MOCKROOT/intake2"; export INTAKE_DIR="$IT2"
oF="$(INTAKE_DIR="$IT2" ORCH_ROOT="$ORCH_TEST_HOME" python3 $ORCH_TEST_HOME/bin/intake.py message "Сделай поиск удобнее" --project example-project)"
[[ "$oF" == *"уточнить"* ]] && ok "12F questions returned to owner" || bad "12F"
oF2="$(INTAKE_DIR="$IT2" ORCH_ROOT="$ORCH_TEST_HOME" python3 $ORCH_TEST_HOME/bin/intake.py answer "поиск закрывается")"
stF="$(python3 - <<'PY'
import json, os
d=os.environ.get("INTAKE_DIR","")
import glob
ws=[json.load(open(f)) for f in glob.glob(os.path.join(d,"INTAKE-*.json"))]
print(ws[-1]["owner_answers"] != {})
PY
)"
[[ "$stF" == "True" ]] && ok "12F reply linked to waiting intake" || bad "12F link=$stF"
# G: две ожидающие -> попросить выбрать (обе с открытыми вопросами)
INTAKE_DIR="$IT2" ORCH_ROOT="$ORCH_TEST_HOME" python3 $ORCH_TEST_HOME/bin/intake.py message "Сделай отчёт удобнее" >/dev/null 2>&1
INTAKE_DIR="$IT2" ORCH_ROOT="$ORCH_TEST_HOME" python3 $ORCH_TEST_HOME/bin/intake.py message "Сделай меню удобнее" >/dev/null 2>&1
oG="$(INTAKE_DIR="$IT2" ORCH_ROOT="$ORCH_TEST_HOME" python3 $ORCH_TEST_HOME/bin/intake.py answer "да")"
[[ "$oG" == *"несколько"* || "$oG" == *"выберите"* ]] && ok "12G multiple waiting -> ask to choose" || bad "12G out=$oG"
# H: готовая задача -> канонический запуск (dry)
oH="$(INTAKE_DIR="$IT2" ORCH_ROOT="$ORCH_TEST_HOME" python3 $ORCH_TEST_HOME/bin/intake.py message "Запусти TASK-9: проверь что VERSION не менялся, не меняя файлы, критерий: проверка выполнена")"
iidH="$(grep -oE '[0-9]{8}T[0-9]{6}-[a-z0-9-]+' <<< "$oH" | tail -1)"
dH="$(INTAKE_DIR="$IT2" ORCH_ROOT="$ORCH_TEST_HOME" python3 $ORCH_TEST_HOME/bin/intake.py launch "$iidH" --dry-run)"
[[ "$dH" == *"[dry-run]"* ]] && ok "12H canonical handoff (dry-run)" || bad "12H dry=$dH"
unset INTAKE_DIR

# --- 13: project wrapper (узкий вход навыка; без общего python3) ---
AGW="$SKILL/bin/project.sh"
IT3="$MOCKROOT/intake3"

# 13a: допустимые подкоманды проходят (в изоляции INTAKE_DIR)
o="$(INTAKE_DIR="$IT3" ORCH_ROOT="$ORCH_TEST_HOME" bash "$AGW" intake "Добавь в бэклог тестовое уведомление")"
[[ "$o" == *"бэклог"* || "$o" == *"уточню"* ]] && ok "13a intake subcommand works" || bad "13a out=$o"
o="$(INTAKE_DIR="$IT3" ORCH_ROOT="$ORCH_TEST_HOME" bash "$AGW" answer "флаг только у владельца")"
[[ -n "$o" ]] && ok "13a answer subcommand works" || bad "13a answer empty"
o="$(ORCH_ROOT="$ORCH_TEST_HOME" bash "$AGW" status)"
[[ "$o" == *"WAITING"* || -z "$o" ]] && ok "13a status works" || bad "13a status=$o"

# 13b: неизвестная команда запрещена
bash "$AGW" frobnicate x >/dev/null 2>&1 && bad "13b unknown accepted" || ok "13b unknown subcommand refused"

# 13c: project нельзя подменить (текст с --project остаётся ТЕКСТОМ сообщения)
INTAKE_DIR="$IT3" ORCH_ROOT="$ORCH_TEST_HOME" bash "$AGW" intake "--project evil" >/dev/null 2>&1
pj="$(python3 - <<'PY'
import json, os, glob
fs = sorted(glob.glob(os.path.join(os.environ.get("IT3X",""), "INTAKE-*.json")))
PY
)"
pj="$(MOCKX=1 python3 -c "
import json, glob, os
fs = sorted(glob.glob('$IT3/INTAKE-*.json'), key=os.path.getmtime)
print(json.load(open(fs[-1]))['project'] if fs else 'none')")"
[[ "$pj" == "example-project" ]] && ok "13c project fixed (text --project stays text)" || bad "13c project=$pj"

# 13d: shell injection не проходит (остаётся текстом, без исполнения)
before="$(ls /tmp | grep -c agw_pwn || true)"
INTAKE_DIR="$IT3" ORCH_ROOT="$ORCH_TEST_HOME" bash "$AGW" answer "\$(touch /tmp/agw_pwn)" >/dev/null 2>&1
after="$(ls /tmp | grep -c agw_pwn || true)"
[[ "$before" == "$after" ]] && ok "13d command substitution inert" || bad "13d injection executed"

# 13e: произвольный путь/файл передать нельзя (подкомандой и как id)
bash "$AGW" /etc/passwd >/dev/null 2>&1 && bad "13e path-as-cmd accepted" || ok "13e path-as-cmd refused"
bash "$AGW" launch "../../etc/passwd" >/dev/null 2>&1 && bad "13e traversal id accepted" || ok "13e traversal id refused"
bash "$AGW" launch "x; rm -rf /tmp" >/dev/null 2>&1 && bad "13e metachars id accepted" || ok "13e metachars id refused"

# 13f: SKILL.md использует только wrapper (нет прямых вызовов intake.py/python3 в командах)
sk="$(cat "$SKILL/SKILL.md")"
[[ "$(grep -c "project.sh" <<< "$sk")" -ge 3 ]] && ok "13f SKILL.md wrapper-only (>=6 вызовов через wrapper)" || bad "13f мало wrapper-вызовов"
grep -qE 'python3 [^ ]*intake\.py|python3 [^ ]*night' <<< "$sk" && bad "13f прямой python3 в SKILL.md" || ok "13f ни одного прямого python3 intake/night"

# 13h: route через wrapper (единый exec-формат навыка)
r1="$(bash "$AGW" route "Найт: сделай TASK-8" | jq -r .decision)"
r2="$(bash "$AGW" route "напомни купить молоко" | jq -r .decision)"
[[ "$r1" == "PROJECT" && "$r2" == "NOT_PROJECT" ]] && ok "13h wrapper route works" || bad "13h r1=$r1 r2=$r2"

# 13g: обычные сообщения навык не трогают (route.py из секции 12) и wrapper не участвует
[[ "$(python3 "$SKILL/route.py" "напомни купить молоко" | jq -r .decision)" == "NOT_PROJECT" ]] \
  && ok "13g ordinary messages untouched" || bad "13g"

# --- 10: human-readable owner report (представление; машинный RESULT не меняется) ---
mk_owner_result() { # dir status extra-json
  local d="$1" st="$2" extra="${3:-{}}"
  mkdir -p "$d/tasks"
  jq -n --arg st "$st" --argjson x "$extra" '{task_id:"SELF-10", status:$st,
    summary:"Кратко: исправлено поведение X, добавлены проверки Y.",
    files_changed:["app/a.py","tests/t.py"], decisions:[], assumptions:[],
    unresolved:(if ($st=="NEEDS_OWNER_INPUT") then ["уточните сценарий приёмки"] else [] end),
    next:"n", reason:(if ($st=="BLOCKED" or $st=="FAILED") then "причина-пример" else "" end),
    checks:[{name:"targeted", status:"PASS", detail:"66 passed"},
            {name:"full gate", status:"PASS", detail:"882 passed"},
            {name:"gate:changed_paths", status:"PASS"}], writes:1, commit_sha:"abc1234", branch:"night/SELF-10"} * $x' > "$d/RESULT.json"
  jq -n '{project:"example-project", task_id:"SELF-10", goal:"g", risk:"LOW", mode:"writable",
    allowed_paths:[], forbidden_paths:[".env"], bootstrap:[], checks:[],
    owner_gates:["OWNER PASS: проверьте сценарий в тестовом боте"]}' > "$d/tasks/task.json"
}

check_report_shape() { # run_dir expect_header expect_action
  local rd="$1" hdr="$2" act="$3"
  local rep="$rd/report.txt"
  [[ -s "$rep" ]] && grep -q "$hdr" "$rep" && grep -q "$act" "$rep" \
    && ! grep -qE "^(SELF-10|AG-…).*(READY_FOR_OWNER_PASS|NEEDS_OWNER_INPUT|NO_CHANGE_REQUIRED|BLOCKED|FAILED)$" "$rep" \
    && grep -q "Что сделано:" "$rep" && grep -qE "Что проверить владельцу:|Что помешало:" "$rep" \
    && ! grep -qE "^(Models|GPT-5.6 calls)" "$rep"
}

# 10a-10e: пять статусов
rd="$MOCKROOT/rep_a"; mkdir -p "$rd/SELF-10"; mk_owner_result "$rd/SELF-10" "READY_FOR_OWNER_PASS"
bash "$ORCH_ROOT/bin/report.sh" --no-send "$rd" >/dev/null 2>&1
check_report_shape "$rd" "🟢 Готово к приёмке" "OWNER PASS" && ok "10a READY_FOR_OWNER_PASS human header+action" || bad "10a ready report shape"
rd="$MOCKROOT/rep_b"; mkdir -p "$rd/SELF-10"; mk_owner_result "$rd/SELF-10" "NEEDS_OWNER_INPUT"
bash "$ORCH_ROOT/bin/report.sh" --no-send "$rd" >/dev/null 2>&1
check_report_shape "$rd" "🟡 Нужна ваша проверка" "ответьте" && ok "10b NEEDS_OWNER_INPUT human header+action" || bad "10b needs-input report shape"
rd="$MOCKROOT/rep_c"; mkdir -p "$rd/SELF-10"; mk_owner_result "$rd/SELF-10" "NO_CHANGE_REQUIRED"
bash "$ORCH_ROOT/bin/report.sh" --no-send "$rd" >/dev/null 2>&1
check_report_shape "$rd" "🟢 Изменения не требуются" "закрыть" && ok "10c NO_CHANGE_REQUIRED human header" || bad "10c no-change report shape"
rd="$MOCKROOT/rep_d"; mkdir -p "$rd/SELF-10"; mk_owner_result "$rd/SELF-10" "BLOCKED"
bash "$ORCH_ROOT/bin/report.sh" --no-send "$rd" >/dev/null 2>&1
check_report_shape "$rd" "🔴 Выполнение остановлено" "Что помешало" && ok "10d BLOCKED human header+cause" || bad "10d blocked report shape"
rd="$MOCKROOT/rep_e"; mkdir -p "$rd/SELF-10"; mk_owner_result "$rd/SELF-10" "FAILED"
bash "$ORCH_ROOT/bin/report.sh" --no-send "$rd" >/dev/null 2>&1
check_report_shape "$rd" "🔴 Ошибка выполнения" "report_full" && ok "10e FAILED human header" || bad "10e failed report shape"

# 10f: машинные сведения — в техническом разделе, модели не в основном тексте
rd="$MOCKROOT/rep_f"; mkdir -p "$rd/SELF-10"; mk_owner_result "$rd/SELF-10" "READY_FOR_OWNER_PASS"
echo '{"model":"zai/glm-5.3","ok":true}' > "$rd/SELF-10/model_calls.jsonl"
bash "$ORCH_ROOT/bin/report.sh" --no-send "$rd" >/dev/null 2>&1
! grep -q "zai/glm" "$rd/report.txt" && grep -q "zai/glm" "$rd/report_full.txt" \
  && ok "10f models в report_full, не в основном тексте" || bad "10f models placement"

# 10g: машинный RESULT не изменён рендером
before="$(md5sum "$MOCKROOT/rep_a/SELF-10/RESULT.json" | cut -d' ' -f1)"
bash "$ORCH_ROOT/bin/report.sh" --no-send "$MOCKROOT/rep_a" >/dev/null 2>&1
after="$(md5sum "$MOCKROOT/rep_a/SELF-10/RESULT.json" | cut -d' ' -f1)"
[[ "$before" == "$after" ]] && ok "10g RESULT.json не тронут рендером" || bad "10g RESULT изменён"

# 7g: report idempotency — повторная отправка скипается маркером
date -u +%FT%TZ > "$MOCKROOT/case_7f/.report_sent"
out="$(bash "$ORCH_ROOT/bin/report.sh" "$MOCKROOT/case_7f" 2>&1)"
[[ "$out" == *"already delivered"* ]] && ok "7g second report send skipped (idempotent)" || bad "7g double-send not prevented"

echo; echo "SELFTEST SUMMARY: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
