#!/usr/bin/env bash
# run_task.sh — bounded executor pipeline for one TASK.
# Usage: run_task.sh <run_dir> <task.json> [profile]
# Output: <run_dir>/<task_id>/RESULT.json ; final status echoed as "FINAL_STATUS <status>"
# Execution profiles (config/permissions.json): balanced (default) | fast | economy.
# Escalation (balanced): Flash -> GLM-5.3 takeover with COMPACT handoff (no transcript),
# triggered by: N turns without meaningful write / minutes without write /
# re-exploration after implementation started / invalid-reply nudges exhausted.
set -u
ORCH_ROOT="${ORCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=bin/gates.sh
source "$ORCH_ROOT/bin/gates.sh"

RUN_DIR="${1:?run_dir}"; TASK_FILE="${2:?task.json}"
PROFILE_ARG="${3:-}"
PERMS="$ORCH_ROOT/config/permissions.json"
PROJECTS="$ORCH_ROOT/config/projects.json"
ROUTING="$ORCH_ROOT/config/routing.json"

emit() { # emit EVENT '{"k":"v"}'
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg ev "$1" --argjson d "${2:-\{\}}" \
    '{ts:$ts, event:$ev} + $d' >> "$RUN_DIR/log.jsonl" 2>/dev/null || true
}
mc() { # model call wrapper -> out file ; args passed through
  bash "$ORCH_ROOT/bin/model_call.sh" --run-dir "$TASK_DIR" $MC_EXTRA_FLAGS "$@"
}

# ---------------------------------------------------------------- load TASK

# ---------------------------------------------------------------- finalize always
# Любой terminal state (включая ранние отказы) обязан дать owner-report;
# единый путь bin/report.sh идемпотентен (.report_sent). ORCH_TEST_NO_SEND=1
# (selftest) строит report.txt без Telegram.
finalize_run() {
  local args=()
  [[ "${ORCH_TEST_NO_SEND:-0}" == "1" ]] && args+=(--no-send)
  if bash "$ORCH_ROOT/bin/report.sh" "${args[@]}" "$RUN_DIR" >> "$RUN_DIR/finalize.log" 2>&1; then
    emit REPORT_FINALIZED "$(jq -cn --arg t "${TASK_ID:-unknown}" '{task_id:$t}')"
  else
    echo "finalize: report.sh failed (see finalize.log)" >> "$RUN_DIR/finalize.log"
    emit REPORT_FINALIZE_FAILED "$(jq -cn --arg t "${TASK_ID:-unknown}" '{task_id:$t}')"
  fi
}

TASK_JSON="$(cat "$TASK_FILE")"
TASK_ID="$(echo "$TASK_JSON" | jq -r '.task_id')"
MODE="$(echo "$TASK_JSON" | jq -r '.mode')"
RISK="$(echo "$TASK_JSON" | jq -r '.risk')"
PROJECT="$(echo "$TASK_JSON" | jq -r '.project')"
TASK_DIR="$RUN_DIR/$TASK_ID"
mkdir -p "$TASK_DIR"; chmod 700 "$TASK_DIR"
echo "$TASK_JSON" | jq . > "$TASK_DIR/task.resolved.json"

echo "$TASK_JSON" > "$TASK_DIR/_task.schema_in.json"
V="$(validate_schema "$TASK_DIR/_task.schema_in.json" "$ORCH_ROOT/contracts/TASK.schema.json")"
if [[ "$V" != "OK" ]]; then
  emit TASK_SCHEMA_INVALID "$(jq -cn --arg t "$TASK_ID" '{task_id:$t}')"
  jq -n --arg t "${TASK_ID:-unknown}" '{task_id:$t, status:"FAILED", summary:"queued TASK failed schema validation", reason:"TASK_JSON schema invalid", files_changed:[], checks:[], decisions:[], assumptions:[], unresolved:["TASK_JSON invalid"], next:"fix TASK JSON in queue", next_action:"fix TASK JSON in queue", evidence:["_task.schema_in.json"], tests:[], writes:0, commit_sha:null}' \
    > "$TASK_DIR/RESULT.json"
  emit TASK_FINISHED "$(jq -cn --arg t "${TASK_ID:-unknown}" --arg s "FAILED" '{task_id:$t,status:$s}')"
  finalize_run; echo "FINAL_STATUS FAILED"; exit 0
fi

# ---------------------------------------------------------------- profile
PROFILE="${PROFILE_ARG:-$(jq -r '.execution_profile // "balanced"' "$PERMS")}"
pj() { jq -r --arg p "$PROFILE" --arg k "$1" '.profiles[$p][$k] // .profiles.balanced[$k]' "$PERMS"; }
EXEC_MODEL="$(pj executor_model)"
TAKEOVER_MODEL="$(pj takeover_model)"
P_MAX_TURNS="$(pj max_agent_turns)"
P_FIRST_WRITE_MIN="$(pj first_write_target_minutes)"
P_HARD_MIN="$(pj task_hard_budget_minutes)"
P_ESC_TURNS="$(pj escalate_after_turns_without_write)"
P_ESC_MIN="$(pj escalate_after_minutes_without_write)"
P_ESC_READS="$(pj escalate_after_reads_post_write)"
P_NUDGES="$(pj max_invalid_nudges)"
P_HIST_BYTES="$(pj history_compact_bytes)"
# --- exploration budget (real-run postmortem) ;
# writable-режим не может тратить весь бюджет на чтение. ORCH_TEST_* —
# детерминированные override'ы для selftest (см. bin/selftest.sh секция 7).
P_MAX_READ_CALLS="$(pj max_read_calls_before_write)"
P_MAX_EXPL_MIN="$(pj max_exploration_minutes)"
P_MAX_REPEAT_READS="$(pj max_repeat_reads)"
P_MAX_COMPACTIONS="$(pj max_compactions_before_escalation)"

TAKEOVER_USED=0
TASK_WALL_START=$(date +%s)
COMPACT_COUNT=0
# capability/cost routing: модели из routing.json roles.*, не из профилей
ROLE_MODEL() { jq -r --arg ro "$1" --arg k "model" '.roles[$ro][$k] // empty' "$ROUTING"; }
EXPLORER_MODEL="$(ROLE_MODEL explorer)"
IMPLEMENTER_MODEL="$(ROLE_MODEL implementer)"
STRONG_FINALIZER_MODEL="$(ROLE_MODEL strong_finalizer)"
REVIEWER_MODEL="$(ROLE_MODEL reviewer)"
EXEC_MODEL="${EXPLORER_MODEL:-$(pj executor_model)}"
TAKEOVER_MODEL="${IMPLEMENTER_MODEL:-$(pj takeover_model)}"
SF_MODEL="${STRONG_FINALIZER_MODEL:-$TAKEOVER_MODEL}"
P_MAX_READ_IMP="$(pj max_read_calls_implementer)"
P_POST_WRITE_EXTRA="$(pj post_write_extra_turns)"
P_MAX_READ_CALLS="${ORCH_TEST_MAX_READ_CALLS:-$P_MAX_READ_CALLS}"
P_MAX_READ_IMP="${ORCH_TEST_MAX_READ_CALLS:-$P_MAX_READ_IMP}"
P_MAX_EXPL_MIN="${ORCH_TEST_MAX_EXPL_MIN:-$P_MAX_EXPL_MIN}"
P_MAX_REPEAT_READS="${ORCH_TEST_MAX_REPEAT_READS:-$P_MAX_REPEAT_READS}"
P_MAX_COMPACTIONS="${ORCH_TEST_MAX_COMPACTIONS:-$P_MAX_COMPACTIONS}"
# selftest-шов для no-write deadline (first_write_target_minutes): без него
# ветку нельзя проверить детерминированно (реальные минуты ждать нельзя)
P_FIRST_WRITE_MIN="${ORCH_TEST_FIRST_WRITE_MIN:-$P_FIRST_WRITE_MIN}"
MC_EXTRA_FLAGS=""
# reasoning-budget ladder: один big-retry и одна strong-эскалация на RUN
RB_BIG_USED=0; RB_SF_USED=0
EXEC_MAXTOK="${ORCH_EXEC_MAXTOK:-16384}"

# ---------------------------------------------------------------- status emitter (staged/atomic: single writer, watchdog reads only)
emit_status() { # $1 stage  $2 extra-note
  python3 - "$TASK_DIR" "$TASK_ID" "$1" "$PROFILE" "$EXEC_MODEL" \
    "${attempt_no:-0}" "${turns_no:-0}" "$P_MAX_TURNS" "$P_HARD_MIN" \
    "${LAST_INPUT_CHARS:-0}" "${MEANINGFUL_WRITES:-0}" "${RETRY_COUNT:-0}" "${2:-}" "$TASK_WALL_START" <<'PYST'
import json, sys, os, time
TASK_WALL_START = int(sys.argv[14])
td, task, stage, profile, model, attempt, turns, maxt, hard_min, inp, writes, retries, note = sys.argv[1:14]
calls = 0
mc = os.path.join(td, "model_calls.jsonl")
if os.path.exists(mc):
    calls = sum(1 for _ in open(mc))
st = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "task": task, "stage": stage, "profile": profile, "executor": model,
    "attempt": int(attempt), "turns": int(turns), "max_turns": int(maxt),
    "wall_seconds": int(time.time() - TASK_WALL_START),
    "hard_budget_seconds": int(hard_min) * 60,
    "last_input_chars": int(inp), "meaningful_writes": int(writes),
    "total_model_calls": calls, "retries": int(retries), "note": note,
}
tmp = os.path.join(td, "status.json.tmp")
json.dump(st, open(tmp, "w"))
os.replace(tmp, os.path.join(td, "status.json"))
with open(os.path.join(os.path.dirname(td), "status.log"), "a") as sl:
    sl.write(f"{task} | {stage} | profile={profile} model={model} turns={turns}/{maxt} "
             f"wall={st['wall_seconds']}s writes={writes} calls={calls} retries={retries} {note}\n")
PYST
}

# ---------------------------------------------------------------- registry
REG="$(jq -r --arg p "$PROJECT" '.[$p] // empty' "$PROJECTS")"
if [[ -z "$REG" ]]; then
  jq -n --arg t "$TASK_ID" '{task_id:$t, status:"FAILED", summary:"project not in registry", reason:"unknown project", files_changed:[], checks:[], decisions:[], assumptions:[], unresolved:["unknown project '"$PROJECT"'"], next:"register project", next_action:"register project", evidence:[], tests:[], writes:0, commit_sha:null}' > "$TASK_DIR/RESULT.json"
  emit PROJECT_UNKNOWN; emit TASK_FINISHED "$(jq -cn --arg t "$TASK_ID" --arg s "FAILED" '{task_id:$t,status:$s}')"
  finalize_run; echo "FINAL_STATUS FAILED"; exit 0
fi
REPO="$(echo "$REG" | jq -r '.repo')"
GUARD_DENY_ROOTS="$(echo "$REG" | jq -r '.guard_roots // [] | join(" ")')"
export GUARD_DENY_ROOTS
# проектно-ограниченные точные разрешения (staging deploy и т.п.); без поля
# в реестре — пусто, guard работает как раньше
ORCH_PROJECT_ACTIONS="$(echo "$REG" | jq -c '.project_actions // {}')"
export ORCH_PROJECT_ACTIONS
WT_ROOT="$(echo "$REG" | jq -r '.worktree_root')"
DEFAULT_BRANCH="$(echo "$REG" | jq -r '.default_branch')"
TEST_CMD="$(echo "$REG" | jq -r '.test_command')"
TEST_VENV_DIR="$(echo "$REG" | jq -r '.test_venv_python // empty')"
export TEST_VENV_DIR
# agent PATH gets the project venv (python3/pytest resolve to it)
export ORCH_TEST_VENV="$TEST_VENV_DIR"
FORBIDDEN_GLOBS="$(echo "$REG" | jq -r '.forbidden_paths | join(" ")') $(echo "$TASK_JSON" | jq -r '.forbidden_paths | join(" ")')"
ALLOWED_GLOBS="$(echo "$TASK_JSON" | jq -r '.allowed_paths | join(" ")')"

DEPLOY_ENABLED="$(jq -r '.DEPLOY_ENABLED' "$PERMS")"

# ---------------------------------------------------------------- jail setup
BRANCH=""; JAIL=""; WT=""
TS="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ "$MODE" == "writable" ]]; then
  if [[ "$DEPLOY_ENABLED" != "false" ]]; then
    jq -n --arg t "$TASK_ID" '{task_id:$t, status:"BLOCKED", summary:"writable run refused: DEPLOY_ENABLED is not false", reason:"DEPLOY_ENABLED safety precondition", files_changed:[], checks:[], decisions:[], assumptions:[], unresolved:["DEPLOY_ENABLED must be confirmed false before writable runs"], next:"owner decision", next_action:"owner decision", evidence:[], tests:[], writes:0, commit_sha:null}' > "$TASK_DIR/RESULT.json"
    emit WRITABLE_REFUSED; emit TASK_FINISHED "$(jq -cn --arg t "$TASK_ID" --arg s "BLOCKED" '{task_id:$t,status:$s}')"
    finalize_run; echo "FINAL_STATUS BLOCKED"; exit 0
  fi
  BRANCH="night/${TASK_ID}-${TS}"
  WT="$WT_ROOT/${TASK_ID}-${TS}"
  mkdir -p "$WT_ROOT"
  if ! git -C "$REPO" worktree add -b "$BRANCH" "$WT" "$DEFAULT_BRANCH" >"$TASK_DIR/worktree.log" 2>&1; then
    jq -n --arg t "$TASK_ID" '{task_id:$t, status:"BLOCKED", summary:"worktree creation failed", reason:"git worktree add failed", files_changed:[], checks:[], decisions:[], assumptions:[], unresolved:["git worktree add failed"], next:"check worktree root", next_action:"check worktree root", evidence:["worktree.log"], tests:[], writes:0, commit_sha:null}' > "$TASK_DIR/RESULT.json"
    emit WORKTREE_FAILED; emit TASK_FINISHED "$(jq -cn --arg t "$TASK_ID" --arg s "BLOCKED" '{task_id:$t,status:$s}')"
    finalize_run; echo "FINAL_STATUS BLOCKED"; exit 0
  fi
  JAIL="$WT"
  emit WORKTREE_CREATED "$(jq -cn --arg t "$TASK_ID" --arg b "$BRANCH" --arg w "$WT" --arg base "$DEFAULT_BRANCH" '{task_id:$t,branch:$b,worktree:$w,base:$base}')"
else
  JAIL="$REPO"
fi

REPO_HEAD_BEFORE="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"

# ---------------------------------------------------------------- context
build_context() { # -> $TASK_DIR/prompt_ctx.txt
  local f cap=16000
  : > "$TASK_DIR/prompt_ctx.txt"
  {
    echo "JAIL (your only working directory): $JAIL"
    echo "MODE: $MODE  RISK: $RISK  PROJECT: $PROJECT  PROFILE: $PROFILE"
    echo "PRODUCTION CHECKOUT (never touch): $REPO"
    echo "PYTEST: python3 resolves to the project venv — 'python3 -m pytest' works directly."
    echo
    echo "=== TASK ==="
    echo "$TASK_JSON" | jq .
    echo
    echo "=== BOOTSTRAP CONTEXT (canonical files, truncated) ==="
  } >> "$TASK_DIR/prompt_ctx.txt"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    {
      echo "--- $f ---"
      head -c "$cap" "$JAIL/$f" 2>/dev/null || echo "(unreadable)"
      [[ $(wc -c < "$JAIL/$f" 2>/dev/null || echo 0) -gt $cap ]] && echo "...[truncated]"
      echo
    } >> "$TASK_DIR/prompt_ctx.txt"
  done < <(echo "$TASK_JSON" | jq -r '.bootstrap[]')
}

start_attempt() { # $1=phase [$2=handoff file]
  : > "$TASK_DIR/history.txt"
  if [[ -n "${2:-}" && -s "$2" ]]; then
    # takeover: compact handoff REPLACES the full bootstrap exploration
    {
      echo "=== COMPACT HANDOFF (from previous executor; do NOT re-explore the repo) ==="
      cat "$2"
      echo
      echo "=== CONTINUE from 'Remaining work'. Verify state only where the handoff is ambiguous."
    } > "$TASK_DIR/prompt_ctx.txt"
  else
    build_context
  fi
  {
    echo
    echo "=== ATTEMPT PHASE: $1 ==="
    if [[ -s "$TASK_DIR/failure_evidence.txt" ]]; then
      echo "FAILURE EVIDENCE from previous attempt (fix this):"
      head -c 4000 "$TASK_DIR/failure_evidence.txt"
      echo
    fi
    echo "Begin now. Reply with one JSON action."
  } >> "$TASK_DIR/prompt_ctx.txt"
}

append_history() { # $1=action_text $2=observation_text
  {
    echo ">>> YOUR ACTION: $1"
    echo "OBSERVATION:"
    printf '%s' "$2" | head -c 4000
    echo
  } >> "$TASK_DIR/history.txt"
}

# history compaction: cap accumulated transcript inside an attempt
compact_history() {
  local size; size="$(wc -c < "$TASK_DIR/history.txt" 2>/dev/null || echo 0)"
  if (( size > P_HIST_BYTES )); then
    COMPACT_COUNT=$((COMPACT_COUNT+1))
    { head -c 6000 "$TASK_DIR/history.txt"
      echo; echo "[...history compacted ($((size-30000)) chars dropped); latest state is what matters...]"; echo
      tail -c 24000 "$TASK_DIR/history.txt"
    } > "$TASK_DIR/history.txt.tmp" && mv "$TASK_DIR/history.txt.tmp" "$TASK_DIR/history.txt"
    emit HISTORY_COMPACTED "$(jq -cn --arg n "$size" '{before:$n}')"
  fi
}

# extract first JSON object from a response file -> echoes object or empty
extract_json() {
  python3 - "$1" <<'PYEOF'
import json, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
i = raw.find('{')
if i < 0: sys.exit(0)
dec = json.JSONDecoder()
try:
    obj, _ = dec.raw_decode(raw[i:])
    print(json.dumps(obj))
except Exception:
    sys.exit(0)
PYEOF
}

# meaningful write snapshot: git status fingerprint of the jail
write_snapshot() { git -C "$JAIL" status --porcelain 2>/dev/null | sort | md5sum | cut -d' ' -f1; }

# ------------------------------------------------------- compact handoff builder
build_handoff() { # -> $TASK_DIR/handoff.md
  python3 - "$TASK_DIR" "$JAIL" "$TASK_JSON" "$EXEC_MODEL" <<'PYEOF'
import json, subprocess, sys, os
td, jail, task_s, prev_model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
task = json.loads(task_s)
def git(args):
    try: return subprocess.run(["git","-C",jail]+args, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception: return ""
status = git(["status","--porcelain"])
diff = git(["diff"])[:8000]
untracked = [l[3:] for l in status.splitlines() if l.startswith("??")]
def head(path, n=60):
    p = os.path.join(jail, path)
    try:
        return "\n".join(open(p, encoding="utf-8", errors="replace").read().splitlines()[:n])
    except Exception: return "(missing)"
def contains(path, needle):
    p = os.path.join(jail, path)
    try: return needle in open(p, encoding="utf-8", errors="replace").read()
    except Exception: return False
# Real-run postmortem: чеклист/контракты были ЗАХАРДКОЖЕНЫ под AG-095
# (квота/VERSION 2.9.0) и дезинформировали takeover любой другой задачи.
# Handoff строится ТОЛЬКО из фактического TASK.json + состояния worktree.
lines = []
lines.append("## Context")
lines.append(f"- TASK: {task['task_id']} ({task['mode']}, risk {task['risk']})")
lines.append(f"- TASK GOAL (authoritative, follow it):\n\n{task.get('goal','')[:6000]}\n")
lines.append(f"- Previous executor: {prev_model} — replaced due to stalled progress. Do NOT re-explore broadly; the state below is authoritative.")
lines.append(f"- JAIL: {jail}; pytest: 'python3 -m pytest ...' (venv already on PATH).")
lines.append(f"- ALLOWED_PATHS: {json.dumps(task.get('allowed_paths', []))}; FORBIDDEN: {json.dumps(task.get('forbidden_paths', []))}")
lines.append("- Guard denials are FATAL. If the goal is genuinely impossible/ambiguous, finish with status NEEDS_OWNER_INPUT and precise unresolved[] — do not guess.")
lines.append("")
lines.append("## Current git status (uncommitted)")
lines.append("```\n" + (status or "(clean)") + "\n```")
lines.append("")
lines.append("## Existing working-tree diff (capped)")
lines.append("```diff\n" + (diff or "(no tracked changes)") + "\n```")
lines.append("")
for uf in untracked[:4]:
    lines.append(f"## Untracked file: {uf} (head)")
    lines.append("```\n" + head(uf, 50) + "\n```")
lines.append("")
cmds = []
try:
    import re as _re
    for l in open(os.path.join(td, "history.txt"), encoding="utf-8", errors="replace"):
        m = _re.search(r'"command":\s*"([^"]{0,160})', l)
        if m and len(cmds) < 400: cmds.append(m.group(1))
except Exception: pass
lines.append("## Already executed shell commands (do NOT repeat them)")
for c in cmds[-25:]:
    lines.append(f"- {c}")
lines.append("")
lines.append("## HARD DIRECTIVE")
lines.append("You have AT MOST 4 read-only commands left. Start WRITING (failing test or minimal fix in allowed_paths) in your next replies. If root cause is unclear, write a minimal diagnostic/instrumentation instead of more grep/sed/cat.")
lines.append("")
lines.append("## Task checks (from TASK.json)")
for c in task.get("checks", []):
    lines.append(f"- [ ] {c}")
lines.append("- [ ] реализация/изменения только в allowed_paths")
lines.append("- [ ] targeted tests")
lines.append("- [ ] git add -A && git commit (single commit, feature branch) — если были изменения")
lines.append("")
lines.append("## Remaining work")
lines.append("Continue the TASK GOAL steps, then finish with {\"action\":\"result\"}. Do not re-read files already summarized here; open a narrow range only if the handoff is ambiguous.")
open(os.path.join(td, "handoff.md"), "w").write("\n".join(lines))
print("handoff built")
PYEOF
}

# ---------------------------------------------------------------- agent attempt
# returns: 0 ok (RESULT valid -> attempt_result.json)
#          1 failure (reason in failure_evidence.txt)
#          2 stop requested (STOP file)
#          200 escalation to takeover model requested
#          125 PERMISSION_VIOLATION
agent_attempt() { # $1 = phase label
  rm -f "$TASK_DIR/attempt_result.json"
  start_attempt "$1" "${HANDOFF_FILE:-}"
  local turns=0 invalid_replies=0
  local turns_since_write=0 reads_post_write=0 writes=0
  local read_calls=0 expl_deadline_noted=0 finalize_noted=0
  # per-phase read cap: implementer-фаза (taкeover) получает ещё меньше чтений
  local phase_read_cap="$P_MAX_READ_CALLS"
  [[ "$EXEC_MODEL" == "$IMPLEMENTER_MODEL" || "$EXEC_MODEL" == "$SF_MODEL" ]] && phase_read_cap="$P_MAX_READ_IMP"
  emit ATTEMPT_START "$(jq -cn --arg t "$TASK_ID" --arg role "$([[ "$EXEC_MODEL" == "$SF_MODEL" ]] && echo strong_finalizer || { [[ "$EXEC_MODEL" == "$IMPLEMENTER_MODEL" && "$TAKEOVER_USED" -eq 1 ]] && echo implementer || echo explorer; })" --arg model "$EXEC_MODEL" --arg a "$attempt_no" --arg ph "$1" '{task_id:$t,role:$role,provider:($model|split("/")[0]),model:$model,attempt:$a,phase:$ph,why_selected:("capability routing: routing.json roles")}')"
  local -A read_fp_count=()
  local expl_start; expl_start=$(date +%s)
  local stage_start; stage_start=$(date +%s)
  local last_write_ts=$stage_start
  local prev_snap cur_snap
  prev_snap="$(write_snapshot)"
  turns_no=0
  local eff_max="$P_MAX_TURNS"
  while (( turns < eff_max )); do
    # ---- owner-requested graceful stop at orchestration boundary
    if [[ -f "$RUN_DIR/STOP" ]]; then
      echo "ORCHESTRATOR_EFFICIENCY_ABORT: STOP file present at turn boundary" > "$TASK_DIR/failure_evidence.txt"
      emit EXEC_ABORTED "$(jq -cn --arg t "$TASK_ID" --arg ph "$1" '{task_id:$t,phase:$ph}')"
      return 2
    fi
    # ---- wall-clock hard budget
    local now=$(date +%s)
    if (( now - TASK_WALL_START > P_HARD_MIN * 60 )); then
      echo "NEEDS_REPLAN: task hard budget ${P_HARD_MIN}min exceeded" > "$TASK_DIR/failure_evidence.txt"
      emit HARD_BUDGET_EXCEEDED "$(jq -cn --arg t "$TASK_ID" --arg n "$(( (now-TASK_WALL_START)/60 ))" '{task_id:$t,wall_min:$n}')"
      return 1
    fi
    # post-write budget: +N turns доступны ТОЛЬКО при meaningful work
    if (( writes > 0 )) || [[ -n "$(git -C "$JAIL" status --porcelain 2>/dev/null | head -c1)" ]]; then
      eff_max=$(( P_MAX_TURNS + P_POST_WRITE_EXTRA ))
    fi
    turns=$((turns+1)); turns_no=$turns
    # RESULT RESERVE: последние 2 хода — только финализация
    if (( eff_max - turns <= 2 && finalize_noted == 0 )); then
      finalize_noted=1
      { echo ">>> SYSTEM NOTE: FINALIZE_NOW — fewer than 3 turns left.";
        echo "Next reply MUST be either a targeted test run or your FINAL {"action":"result"} JSON. No more exploration."; echo; } >> "$TASK_DIR/history.txt"
      emit FINALIZE_NOW "$(jq -cn --arg t "$TASK_ID" --arg left "$(( eff_max - turns ))" '{task_id:$t,turns_left:$left}')"
    fi
    compact_history
    {
      cat "$ORCH_ROOT/prompts/executor_system.md"
      echo
      echo "=== TASK CONTEXT ==="
      cat "$TASK_DIR/prompt_ctx.txt"
      echo
      echo "=== CONVERSATION SO FAR ==="
      cat "$TASK_DIR/history.txt"
      [[ -s "$TASK_DIR/history.txt" ]] && echo "Continue. Reply with exactly one JSON action."
    } > "$TASK_DIR/prompt.txt"
    LAST_INPUT_CHARS="$(wc -c < "$TASK_DIR/prompt.txt")"
    mc --role executor --model "$EXEC_MODEL" \
       --system-file "$ORCH_ROOT/prompts/executor_system.md" \
       --prompt-file "$TASK_DIR/prompt.txt" \
       --out-file "$TASK_DIR/resp.txt" --max-tokens "$EXEC_MAXTOK"
    local mrc=$?
    if [[ $mrc -eq 45 ]]; then
      # REASONING_BUDGET_EXHAUSTED: обычный JSON-repair той же моделью/лимитом
      # бессмыслен. Лестница: (1) ОДИН retry с 28672; (2) ОДНА strong-эскалация
      # (progress не требуется); (3) структурный BLOCKED. Без provider-циклов.
      local rbf="$TASK_DIR/rb_event.json"
      [[ -s "$rbf" ]] || echo '{"reason":"rb"}' > "$rbf"
      emit REASONING_BUDGET_EXHAUSTED "$(jq -c --arg t "$TASK_ID" --argjson br "$RB_BIG_USED" '. + {task_id:$t, big_retry_available:($br==0)}' "$rbf" 2>/dev/null || jq -cn --arg t "$TASK_ID" '{task_id:$t}')"
      rm -f "$rbf"
      if [[ $RB_BIG_USED -eq 0 ]]; then
        RB_BIG_USED=1; EXEC_MAXTOK=28672
        { echo ">>> SYSTEM NOTE: previous reply burned its whole output budget on reasoning. Retry with a larger budget: answer with EXACTLY ONE short JSON action NOW, minimal reasoning."; echo; } >> "$TASK_DIR/history.txt"
        turns=$((turns-1))   # повтор того же хода, не сжигает бюджет
        continue
      fi
      if [[ $RB_SF_USED -eq 0 ]]; then
        RB_SF_USED=1
        { echo "REASONING_BUDGET_EXHAUSTED: even at max_tokens=$EXEC_MAXTOK content is empty — escalating to strong executor"; } > "$TASK_DIR/failure_evidence.txt"
        return 201
      fi
      { echo "REASONING_BUDGET_EXHAUSTED: strong executor also exhausted (max_tokens=$EXEC_MAXTOK)"; } > "$TASK_DIR/failure_evidence.txt"
      return 1
    fi
    if [[ $mrc -ne 0 ]]; then
      echo "model call failed rc=$mrc (see model_calls.jsonl)" > "$TASK_DIR/failure_evidence.txt"
      return 1
    fi
    local obj; obj="$(extract_json "$TASK_DIR/resp.txt")"
    if [[ -z "$obj" ]]; then
      invalid_replies=$((invalid_replies+1))
      if (( invalid_replies <= P_NUDGES )); then
        {
          echo ">>> SYSTEM NOTE: your previous reply was empty or not a valid JSON action."
          echo "Reply with EXACTLY ONE JSON object: {\"action\":\"shell\",\"command\":\"...\"} or {\"action\":\"result\",\"result\":{...}}."
          echo
        } >> "$TASK_DIR/history.txt"
        emit AGENT_NUDGE "$(jq -cn --arg t "$TASK_ID" --arg n "$invalid_replies" '{task_id:$t,nudge:$n}')"
        continue
      fi
      { echo "executor reply was not a valid JSON action (after $invalid_replies nudges):"; head -c 1000 "$TASK_DIR/resp.txt"; } > "$TASK_DIR/failure_evidence.txt"
      return 1
    fi
    local action; action="$(echo "$obj" | jq -r '.action // "none"')"
    case "$action" in
      shell)
        local cmd; cmd="$(echo "$obj" | jq -r '.command // ""')"
        emit AGENT_SHELL "{\"task_id\":\"$TASK_ID\",\"cmd_head\":\"$(printf '%s' "$cmd" | head -c 120 | tr '"' "'")\"}"
        run_guarded "$MODE" "$JAIL" "$(jq -r '.command_timeout_seconds' "$PERMS")" "$cmd" "$TASK_DIR/cmd_out.txt"
        local grc=$?
        # audit: разрешённое проектное действие (точное совпадение с реестром)
        if [[ -n "${GUARD_MATCHED_ACTION:-}" ]]; then
          emit PROJECT_ACTION_ALLOWED "$(jq -cn --arg t "$TASK_ID" --arg a "$GUARD_MATCHED_ACTION" '{task_id:$t,action:$a}')"
        fi
        if [[ $grc -eq 125 ]]; then
          { echo "PERMISSION_VIOLATION: guard denied command (FATAL, no retry):"; echo "$cmd"; } > "$TASK_DIR/failure_evidence.txt"
          emit PERMISSION_VIOLATION "$(jq -cn --arg t "$TASK_ID" --arg c "$(printf '%s' "$cmd" | head -c 120)" '{task_id:$t,cmd_head:$c}')"
          return 125
        fi
        append_history "$(echo "$obj" | head -c 300)" "(rc=$grc) $(cat "$TASK_DIR/cmd_out.txt" 2>/dev/null)"
        # ---- meaningful write / progress tracking
        cur_snap="$(write_snapshot)"
        if [[ "$cur_snap" != "$prev_snap" ]]; then
          writes=$((writes+1)); MEANINGFUL_WRITES=$((MEANINGFUL_WRITES+1))
          turns_since_write=0; reads_post_write=0; last_write_ts=$(date +%s)
          prev_snap="$cur_snap"
          emit MEANINGFUL_WRITE "$(jq -cn --arg t "$TASK_ID" --arg n "$writes" '{task_id:$t,n:$n}')"
        else
          turns_since_write=$((turns_since_write+1))
          case "$cmd" in
            *pytest*) turns_since_write=0 ;; # test iteration = progress
            cat*|sed\ *|grep*|ls*|find*|head*|tail*|wc*|rg*|git\ show*|git\ diff*|git\ log*|git\ status*)
              # exploration-книга: повторное чтение = отсутствие progress
              if [[ "$MODE" == "writable" && $writes -eq 0 ]]; then
                read_calls=$((read_calls+1))
                local fp; fp="$(printf '%s' "$cmd" | tr -d '0-9' | md5sum | cut -d' ' -f1)"
                read_fp_count[$fp]=$(( ${read_fp_count[$fp]:-0} + 1 ))
                if (( ${read_fp_count[$fp]} > P_MAX_REPEAT_READS )); then
                  emit REPEAT_READ "$(jq -cn --arg t "$TASK_ID" --arg n "${read_fp_count[$fp]}" '{task_id:$t,count:$n}')"
                  { echo ">>> SYSTEM NOTE: this exact read command was already executed ${read_fp_count[$fp]}x. Re-reading is NOT progress."; echo "Use the output you already have; move to a write/edit of allowed files or produce the result."; echo; } >> "$TASK_DIR/history.txt"
                fi
              fi
              [[ $writes -gt 0 ]] && reads_post_write=$((reads_post_write+1)) ;;
          esac
        fi
        emit_status "EXECUTING" "phase=$1"
        # ---- balanced escalation checks
        local mins_since_write=$(( ($(date +%s) - last_write_ts) / 60 ))
        local stage_min=$(( ($(date +%s) - stage_start) / 60 ))
        if [[ "$TAKEOVER_USED" -eq 0 && "$EXEC_MODEL" != "$TAKEOVER_MODEL" ]]; then
          if (( turns_since_write >= P_ESC_TURNS )); then
            emit ESCALATION "$(jq -cn --arg t "$TASK_ID" --arg r "turns_without_write=$turns_since_write" '{task_id:$t,reason:$r}')"
            return 200
          fi
          if (( stage_min >= P_FIRST_WRITE_MIN && writes == 0 )); then
            emit ESCALATION "$(jq -cn --arg t "$TASK_ID" --arg r "no_write_in_${stage_min}min" '{task_id:$t,reason:$r}')"
            return 200
          fi
          if (( mins_since_write >= P_ESC_MIN )); then
            emit ESCALATION "$(jq -cn --arg t "$TASK_ID" --arg r "stall_${mins_since_write}min" '{task_id:$t,reason:$r}')"
            return 200
          fi
          if (( writes > 0 && reads_post_write >= P_ESC_READS )); then
            emit ESCALATION "$(jq -cn --arg t "$TASK_ID" --arg r "reexploration_after_write=$reads_post_write" '{task_id:$t,reason:$r}')"
            return 200
          fi
        fi
        # ---- exploration budget (writable, работа ещё не начата) ----------
        # deadline НЕ применяется к read_only-задачам; критерий — ПУСТОЕ дерево
        # worktree (а не локальный writes этой попытки): repair/takeover-попытка
        # поверх уже начатой реализации не считается exploration (реальный кейс).
        local tree_has_work=""
        [[ -n "$(git -C "$JAIL" status --porcelain 2>/dev/null | head -c1)" ]] && tree_has_work=1
        if [[ "$MODE" == "writable" && -z "$tree_has_work" ]]; then
          local expl_min=$(( ($(date +%s) - expl_start) / 60 ))
          local over=0 local why=""
          if (( read_calls >= phase_read_cap )); then over=1; why="read_calls=$read_calls>=$phase_read_cap"; fi
          if (( expl_min >= P_MAX_EXPL_MIN )); then over=1; why="exploration_${expl_min}min>=$P_MAX_EXPL_MIN"; fi
          if (( COMPACT_COUNT >= P_MAX_COMPACTIONS )); then over=1; why="compactions=$COMPACT_COUNT>=$P_MAX_COMPACTIONS"; fi
          if (( over == 1 )); then
            if (( expl_deadline_noted == 0 )); then
              # одна жёсткая директива: план → немедленный write; следующее
              # read-only без write завершает попытку (takeover при наличии)
              expl_deadline_noted=1
              emit EXPLORATION_DEADLINE "$(jq -cn --arg t "$TASK_ID" --arg r "$why" '{task_id:$t,reason:$r}')"
              { echo ">>> SYSTEM NOTE: EXPLORATION BUDGET EXCEEDED ($why). You have read enough.";
                echo "Next reply MUST be either (a) a shell command that EDITS an allowed file (start implementing),";
                echo "or (b) your final {\"action\":\"result\"} with honest status.";
                echo "Any further read-only command without a write will TERMINATE this attempt."; echo; } >> "$TASK_DIR/history.txt"
            else
              if [[ $TAKEOVER_USED -eq 0 && "$EXEC_MODEL" != "$TAKEOVER_MODEL" ]]; then
                emit ESCALATION "$(jq -cn --arg t "$TASK_ID" --arg r "exploration_budget:$why" '{task_id:$t,reason:$r}')"
                return 200
              fi
              { echo "EXPLORATION_BUDGET_EXCEEDED: $why — executor did not move to implementation after deadline directive"; } > "$TASK_DIR/failure_evidence.txt"
              emit EXPLORATION_BUDGET_EXCEEDED "$(jq -cn --arg t "$TASK_ID" --arg r "$why" '{task_id:$t,reason:$r}')"
              return 1
            fi
          fi
        fi
        ;;
      result)
        echo "$obj" | jq '.result' > "$TASK_DIR/attempt_result.json" 2>/dev/null
        local v; v="$(validate_schema "$TASK_DIR/attempt_result.json" "$ORCH_ROOT/contracts/RESULT.schema.json")"
        if [[ "$v" != "OK" ]]; then
          { echo "executor RESULT failed schema validation: $v"; head -c 1000 "$TASK_DIR/attempt_result.json"; } > "$TASK_DIR/failure_evidence.txt"
          rm -f "$TASK_DIR/attempt_result.json"
          return 1
        fi
        return 0
        ;;
      *)
        invalid_replies=$((invalid_replies+1))
        if (( invalid_replies <= P_NUDGES )); then
          {
            echo ">>> SYSTEM NOTE: unknown action in your reply. Allowed actions: shell | result."
            echo "Reply with EXACTLY ONE JSON object."
            echo
          } >> "$TASK_DIR/history.txt"
          emit AGENT_NUDGE "$(jq -cn --arg t "$TASK_ID" --arg n "$invalid_replies" '{task_id:$t,nudge:$n}')"
          continue
        fi
        { echo "executor replied with unknown action (after $invalid_replies nudges): $(echo "$obj" | head -c 300)"; } > "$TASK_DIR/failure_evidence.txt"
        return 1
        ;;
    esac
  done
  echo "agent turn budget exceeded ($P_MAX_TURNS turns, no RESULT produced)" > "$TASK_DIR/failure_evidence.txt"
  return 1
}

# ---------------------------------------------------------------- gates
run_gates() { # -> $TASK_DIR/gate_evidence.txt ; 0 pass / 1 fail
  local ev="$TASK_DIR/gate_evidence.txt"; : > "$ev"
  local rc_all=0
  ALLOWED_GLOBS="$ALLOWED_GLOBS" FORBIDDEN_GLOBS="$FORBIDDEN_GLOBS" \
    gate_changed_paths "$JAIL" "$MODE" "$DEFAULT_BRANCH" >> "$ev" 2>&1 || rc_all=1
  gate_git_diff_check "$JAIL" >> "$ev" 2>&1 || rc_all=1
  echo "$TASK_JSON" | jq -c '.checks' > "$TASK_DIR/_checks.json"
  gate_run_checks "$JAIL" "$TASK_DIR/_checks.json" "$MODE" "$(jq -r '.command_timeout_seconds' "$PERMS")" "$TASK_DIR" >> "$ev" 2>&1 || rc_all=1
  if [[ "$(echo "$TASK_JSON" | jq -r '.requires_full_offline_gate // false')" == "true" ]]; then
    TEST_VENV_DIR="$TEST_VENV_DIR" gate_full_offline "$JAIL" "$TEST_CMD" "$TASK_DIR/full_gate.log" >> "$ev" 2>&1 || rc_all=1
  fi
  if [[ "$MODE" == "read_only" ]]; then
    gate_git_status_clean "$JAIL" >> "$ev" 2>&1 || rc_all=1
  fi
  (( rc_all == 0 )) && return 0 || return 1
}

# ---------------------------------------------------------------- review
run_review() { # $1=extra evidence file or "" -> review.json ; 0 approve / 1 reject / 2 error
  local evfile="${1:-}"
  {
    cat "$ORCH_ROOT/prompts/reviewer_system.md"
    echo "=== TASK ==="; echo "$TASK_JSON" | jq .
    echo "=== EXECUTOR RESULT ==="; cat "$TASK_DIR/attempt_result.json"
    echo "=== GATE EVIDENCE ==="; cat "$TASK_DIR/gate_evidence.txt"
    if [[ -n "$evfile" && -s "$evfile" ]]; then echo "=== FAILURE/REVIEW EVIDENCE ==="; head -c 4000 "$evfile"; fi
    echo "=== DIFF ==="
    if [[ "$MODE" == "writable" ]]; then
      git -C "$JAIL" diff "$DEFAULT_BRANCH...HEAD" | head -c 20000
      git -C "$JAIL" status --porcelain | head -c 2000
    else
      echo "(read-only task, no diff)"
    fi
  } > "$TASK_DIR/review_prompt.txt"
  mc --role review --model "$(jq -r '.roles.reviewer.model // .roles.review_high.primary // .roles.review_medium.primary' "$ROUTING")" \
     --system-file "$ORCH_ROOT/prompts/reviewer_system.md" \
     --prompt-file "$TASK_DIR/review_prompt.txt" \
     --out-file "$TASK_DIR/review_raw.txt" --max-tokens 2048
  local rc=$?
  if [[ $rc -ne 0 ]]; then return 2; fi
  extract_json "$TASK_DIR/review_raw.txt" > "$TASK_DIR/review.json"
  local verdict; verdict="$(jq -r '.verdict // ""' "$TASK_DIR/review.json" 2>/dev/null)"
  [[ "$verdict" == "APPROVE" ]] && return 0 || return 1
}

# ---------------------------------------------------------------- main flow
phase_label="INITIAL"
emit TASK_STARTED "$(jq -cn --arg t "$TASK_ID" --arg m "$MODE" --arg r "$RISK" --arg j "$JAIL" --arg pr "$PROFILE" --arg ex "$EXEC_MODEL" '{task_id:$t,mode:$m,risk:$r,jail:$j,profile:$pr,executor:$ex}')"
attempt_no=0; turns_no=0; MEANINGFUL_WRITES=0; RETRY_COUNT=0
final_status=""; violation=0; gates_ok=0
strong_review_done=0; invalid_repair_done=0
HANDOFF_FILE=""
emit_status "STARTED" "profile=$PROFILE"

while :; do
  attempt_no=$((attempt_no+1))
  agent_attempt "$phase_label"; arc=$?
  if [[ $arc -eq 2 ]]; then final_status="ABORTED"; break; fi
  if [[ $arc -eq 201 ]]; then
    # ---- reasoning-budget escalation: смена модели допустима БЕЗ meaningful
    # progress (это иная причина, чем stalled exploration)
    EXEC_MODEL="$SF_MODEL"
    case "$SF_MODEL" in openai/gpt-5.6*|*/gpt-5.6*) MC_EXTRA_FLAGS="--trigger" ;; esac
    EXEC_MAXTOK=28672
    build_handoff > /dev/null
    HANDOFF_FILE="$TASK_DIR/handoff.md"
    phase_label="REASONING_ESCALATION:$EXEC_MODEL"
    emit ESCALATION "$(jq -cn --arg t "$TASK_ID" --arg r "reasoning_budget_exhausted" '{task_id:$t,reason:$r}')"
    emit TAKEOVER "$(jq -cn --arg t "$TASK_ID" --arg m "$EXEC_MODEL" '{task_id:$t,model:$m,reason:"reasoning_budget_exhausted"}')"
    emit_status "TAKEOVER" "model=$EXEC_MODEL reason=reasoning_budget"
    continue
  fi
  if [[ $arc -eq 200 ]]; then
    # ---- model takeover with compact handoff (once); no transcript transfer
    TAKEOVER_USED=1
    EXEC_MODEL="$TAKEOVER_MODEL"
    build_handoff > /dev/null
    HANDOFF_FILE="$TASK_DIR/handoff.md"
    phase_label="TAKEOVER:$EXEC_MODEL"
    emit TAKEOVER "$(jq -cn --arg t "$TASK_ID" --arg m "$EXEC_MODEL" --arg h "$HANDOFF_FILE" '{task_id:$t,model:$m,handoff:$h}')"
    emit_status "TAKEOVER" "model=$EXEC_MODEL"
    continue
  fi
  if [[ $arc -eq 125 ]]; then violation=1; break; fi
  if [[ $arc -eq 0 ]]; then
    if run_gates; then
      gates_ok=1
    else
      gates_ok=0
      cp "$TASK_DIR/gate_evidence.txt" "$TASK_DIR/failure_evidence.txt"
    fi
    if [[ $gates_ok -eq 1 ]]; then
      # честные терминальные ответы без claims работы принимаются напрямую:
      # review-цикл — только для результатов, заявляющих выполненную работу
      # (обычное присваивание: это верхний уровень скрипта, local вне
      # функции не присваивает и ломал пропуск review — регрессия 0.1.2)
      attempt_st="$(jq -r '.status // ""' "$TASK_DIR/attempt_result.json" 2>/dev/null)"
      if [[ "$attempt_st" == "NEEDS_OWNER_INPUT" || "$attempt_st" == "NO_CHANGE_REQUIRED" || "$attempt_st" == "BLOCKED" ]]; then
        emit REVIEW_SKIPPED "$(jq -cn --arg t "$TASK_ID" --arg s "$attempt_st" '{task_id:$t,terminal_status:$s}')"
        break
      fi
      if [[ "$RISK" == "MEDIUM" || "$RISK" == "HIGH" ]]; then
        emit_status "REVIEWING" "gates=pass"
        run_review ""; rrc=$?
        if [[ $rrc -eq 1 ]]; then
          cp "$TASK_DIR/review.json" "$TASK_DIR/failure_evidence.txt"
        elif [[ $rrc -eq 0 ]]; then
          break
        fi
      else
        break
      fi
    fi
  fi

  # ---- retry policy (§8)
  if [[ $strong_review_done -eq 1 ]]; then
    final_status="BLOCKED"
    emit BUDGET_EXHAUSTED
    break
  fi
  if [[ ! -s "$TASK_DIR/attempt_result.json" && $invalid_repair_done -eq 0 ]]; then
    invalid_repair_done=1
    phase_label="REPAIR_INVALID_RESULT"
    RETRY_COUNT=$((RETRY_COUNT+1))
    emit RETRY "$(jq -cn --arg t "$TASK_ID" --arg ph "$phase_label" '{task_id:$t,phase:$ph}')"
    continue
  fi
  if [[ $attempt_no -le 1 ]]; then
    phase_label="REPAIR"
    RETRY_COUNT=$((RETRY_COUNT+1))
    emit RETRY "$(jq -cn --arg t "$TASK_ID" --arg ph "$phase_label" '{task_id:$t,phase:$ph}')"
    continue
  fi
  strong_review_done=1
  emit_status "STRONG_REVIEW" "evidence-driven"
  run_review "$TASK_DIR/failure_evidence.txt"; src_=$?
  if [[ $src_ -eq 0 && $gates_ok -eq 1 && -s "$TASK_DIR/attempt_result.json" ]]; then
    break
  fi
  local_remediation="$(jq -r '.remediation // ""' "$TASK_DIR/review.json" 2>/dev/null)"
  if [[ -z "$local_remediation" ]]; then
    final_status="BLOCKED"
    emit STRONG_REVIEW_BLOCKED
    break
  fi
  echo "STRONG REVIEWER REMEDIATION (bounded): $local_remediation" > "$TASK_DIR/failure_evidence.txt"
  phase_label="BOUNDED_REMEDIATION"
  SF_HAD_PROGRESS=0
  (( MEANINGFUL_WRITES > 0 )) && SF_HAD_PROGRESS=1
  [[ -n "$(git -C "$JAIL" status --porcelain 2>/dev/null | head -c1)" ]] && SF_HAD_PROGRESS=1
  if [[ $SF_HAD_PROGRESS -eq 1 && "$SF_MODEL" != "$EXEC_MODEL" ]]; then
    EXEC_MODEL="$SF_MODEL"
    case "$SF_MODEL" in openai/gpt-5.6*|*/gpt-5.6*) MC_EXTRA_FLAGS="--trigger" ;; esac
    build_handoff > /dev/null
    HANDOFF_FILE="$TASK_DIR/handoff.md"
    emit STRONG_FINALIZER "$(jq -cn --arg t "$TASK_ID" --arg m "$SF_MODEL" '{task_id:$t,model:$m,note:"bounded; meaningful progress present"}')"
  fi
  RETRY_COUNT=$((RETRY_COUNT+1))
  emit RETRY "$(jq -cn --arg t "$TASK_ID" --arg ph "$phase_label" '{task_id:$t,phase:$ph}')"
done

if [[ $violation -eq 1 ]]; then
  final_status="PERMISSION_VIOLATION"
elif [[ -z "$final_status" ]]; then
  local_ogates="$(echo "$TASK_JSON" | jq -r '.owner_gates | length')"
  if [[ -s "$TASK_DIR/attempt_result.json" ]]; then
    st="$(jq -r '.status' "$TASK_DIR/attempt_result.json")"
    case "$st" in
      PASS|READY_FOR_OWNER_PASS)
        if [[ "$local_ogates" -gt 0 ]]; then final_status="NEEDS_OWNER_INPUT"; else final_status="READY_FOR_OWNER_PASS"; fi ;;
      OWNER_GATE|NEEDS_OWNER_INPUT) final_status="NEEDS_OWNER_INPUT" ;;
      FAIL|FAILED) final_status="FAILED" ;;
      NO_CHANGE_REQUIRED) final_status="NO_CHANGE_REQUIRED" ;;
      BLOCKED) final_status="BLOCKED" ;;
      *) final_status="BLOCKED" ;;
    esac
  else
    fe="$(head -c 80 "$TASK_DIR/failure_evidence.txt" 2>/dev/null)"
    case "$fe" in
      NEEDS_REPLAN*|ORCHESTRATOR_EFFICIENCY_ABORT*|EXPLORATION_BUDGET_EXCEEDED*) final_status="BLOCKED" ;;
      *) final_status="FAILED" ;;
    esac
  fi
fi

# ---------------------------------------------------------------- assemble final RESULT
merge_final() {
  python3 - "$TASK_DIR" "$final_status" "$TASK_ID" "$MODE" "$RISK" "$attempt_no" "$PROFILE" "$EXEC_MODEL" <<'PYEOF'
import json, sys, os
d, status, tid, mode, risk, attempts, profile, model = sys.argv[1:9]
res = None
p = os.path.join(d, "attempt_result.json")
if os.path.exists(p) and os.path.getsize(p) > 2:
    try: res = json.load(open(p))
    except Exception: res = None
model_result = isinstance(res, dict) and bool(res)
if not model_result:
    # runner-synthesized structured BLOCKED/FAILED: никаких заглушек "-",
    # RESULT обязан нести факты (real-run postmortem).
    res = {}
fe = ""
fep = os.path.join(d, "failure_evidence.txt")
if os.path.exists(fep):
    fe = open(fep).read().strip().splitlines()
    fe = fe[0] if fe else ""
reason = fe or (res.get("reason") or "")
if not reason:
    reason = {
        "READY_FOR_OWNER_PASS": "executor result accepted by gates/review",
        "NO_CHANGE_REQUIRED": "executor verified: no code change needed",
        "NEEDS_OWNER_INPUT": "owner decisions required (owner_gates)",
    }.get(status, "")
res.setdefault("task_id", tid)
res["status"] = status
res.setdefault("summary", ("Runner-synthesized %s (model produced no valid RESULT): %s" % (status, reason)) if not model_result else res.get("summary") or "-")
res["reason"] = reason
# evidence: артефакты прогона, доступные владельцу
ev_files = []
for cand in ("failure_evidence.txt", "gate_evidence.txt", "cmd_out.txt",
             "review.json", "handoff.md", "prompt_ctx.txt"):
    q = os.path.join(d, cand)
    if os.path.exists(q) and os.path.getsize(q) > 0:
        ev_files.append(cand)
run_dir = os.path.dirname(d)
lg = os.path.join(run_dir, "log.jsonl")
if os.path.exists(lg):
    ev_files.append("../log.jsonl")
res.setdefault("evidence", ev_files)
res.setdefault("tests", [])
res.setdefault("writes", 0)
res.setdefault("commit_sha", None)
res["next_action"] = res.get("next_action") or {
    "READY_FOR_OWNER_PASS": "owner review of the task worktree diff, then OWNER PASS/GO decision",
    "NO_CHANGE_REQUIRED": "close the backlog item with this run as evidence",
    "NEEDS_OWNER_INPUT": "answer owner_gates in unresolved[]; then re-run with a new run-id",
    "BLOCKED": "inspect failure_evidence.txt; re-plan task (new run-id)",
    "FAILED": "inspect failure_evidence.txt and gate_evidence.txt; fix and re-run",
    "PERMISSION_VIOLATION": "inspect the denied command; adjust task contract or executor prompt",
}.get(status, "inspect run evidence")
# runner-known facts затирают пустые значения модели
wf = os.path.join(d, "_writes.count")
if os.path.exists(wf):
    try: res["writes"] = max(int(res["writes"] or 0), int(open(wf).read().strip() or 0))
    except Exception: pass
wtj = os.path.join(d, "_worktree.json")
if os.path.exists(wtj):
    wj = json.load(open(wtj))
    res.update(wj)
    try:
        import subprocess
        sha = subprocess.run(["git", "-C", wj["worktree"], "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        base = subprocess.run(["git", "-C", wj["worktree"], "rev-parse", "--short", wj.get("base_branch", "main")],
                              capture_output=True, text=True, timeout=10).stdout.strip()
        if sha and sha != base:
            res["commit_sha"] = sha if res.get("commit_sha") in (None, "") else res["commit_sha"]
    except Exception:
        pass
res.setdefault("next", res["next_action"])
for k, v in (("next_action", res["next_action"]),):
    res[k] = v
if not model_result:
    res["summary"] = res["summary"][:500]
for k in ("files_changed","checks","decisions","assumptions","unresolved"):
    res.setdefault(k, [])
if status == "NEEDS_OWNER_INPUT":
    gates = []
    try: gates = json.load(open(os.path.join(d, "_owner_gates.json")))
    except Exception: pass
    res["unresolved"] = sorted(set(res.get("unresolved", [])) | set(gates)) or gates
ev = []
ge = os.path.join(d, "gate_evidence.txt")
if os.path.exists(ge):
    ev = [l.strip() for l in open(ge) if l.strip()]
for line in ev:
    name_status, _, detail = line.partition("|")
    gname, _, gst = name_status.strip().partition(":")
    if not gst:
        gname, gst = gname, ("PASS" if "PASS" in line else "FAIL")
    res["checks"].append({"name": f"gate:{gname}", "status": gst, "detail": detail[:300]})
mc = os.path.join(d, "model_calls.jsonl")
calls = []
if os.path.exists(mc):
    calls = [json.loads(l) for l in open(mc) if l.strip()]
res["attempts"] = attempts
res["model_calls"] = calls
res["risk"] = risk
res["mode"] = mode
res["execution_profile"] = profile
res["executor_model_final"] = model
json.dump(res, open(os.path.join(d, "RESULT.json"), "w"), indent=1, ensure_ascii=False)
print("OK")
PYEOF
}

echo "$TASK_JSON" | jq -c '.owner_gates' > "$TASK_DIR/_owner_gates.json"
echo "$MEANINGFUL_WRITES" > "$TASK_DIR/_writes.count"
if [[ "$MODE" == "writable" ]]; then
  jq -n --arg b "$BRANCH" --arg w "$WT" --arg base "$DEFAULT_BRANCH" \
    '{branch:$b, worktree:$w, base_branch:$base}' > "$TASK_DIR/_worktree.json"
fi
merge_final
FV="$(validate_schema "$TASK_DIR/RESULT.json" "$ORCH_ROOT/contracts/RESULT.schema.json")"
if [[ "$FV" != "OK" ]]; then
  emit FINAL_RESULT_INVALID "$(jq -cn --arg e "$(printf '%s' "$FV" | head -c 200)" '{err:$e}')"
  jq -n --arg t "$TASK_ID" '{task_id:$t, status:"FAILED", summary:"orchestrator failed to assemble valid RESULT", reason:"RESULT assembly schema error", files_changed:[], checks:[], decisions:[], assumptions:[], unresolved:["RESULT assembly bug"], next:"inspect run evidence", next_action:"inspect run evidence", evidence:["failure_evidence.txt","gate_evidence.txt"], tests:[], writes:0, commit_sha:null}' > "$TASK_DIR/RESULT.json"
  final_status="FAILED"
fi

# ---------------------------------------------------------------- cleanup
if [[ "$MODE" == "writable" && "$(echo "$TASK_JSON" | jq -r '.cleanup_worktree // false')" == "true" && "$final_status" != "PERMISSION_VIOLATION" ]]; then
  git -C "$REPO" worktree remove --force "$WT" >> "$TASK_DIR/worktree.log" 2>&1
  git -C "$REPO" branch -D "$BRANCH" >> "$TASK_DIR/worktree.log" 2>&1
  emit WORKTREE_CLEANED "$(jq -cn --arg t "$TASK_ID" '{task_id:$t}')"
fi

REPO_HEAD_AFTER="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
REPO_DIRTY="$(git -C "$REPO" status --porcelain 2>/dev/null | head -c 500)"
if [[ "$REPO_HEAD_BEFORE" != "$REPO_HEAD_AFTER" || -n "$REPO_DIRTY" ]]; then
  emit PRODUCTION_CHECKOUT_CHANGED "$(jq -cn --arg b "$REPO_HEAD_BEFORE" --arg a "$REPO_HEAD_AFTER" --arg d "$REPO_DIRTY" '{head_before:$b,head_after:$a,dirty:$d}')"
fi

emit_status "FINISHED" "status=$final_status"
emit TASK_FINISHED "$(jq -cn --arg t "$TASK_ID" --arg s "$final_status" '{task_id:$t,status:$s}')"

finalize_run

echo "FINAL_STATUS $final_status"
