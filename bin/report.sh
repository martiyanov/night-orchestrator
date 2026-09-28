#!/usr/bin/env bash
# report.sh — human-readable owner report from RESULT.json + TASK, sent via Telegram.
# Usage: report.sh [--no-send] <run_dir>
#   --no-send — построить текст без Telegram (selftest/диагностика)
# Файлы:
#   report.txt      — человеческий текст (он же уходит в Telegram)
#   report_full.txt — технические сведения (модели/счётчики) для диагностики
# Идемпотентность: повторный вызов НЕ отправляет отчёт дважды (маркер
# $RUN_DIR/.report_sent ставится только после успешной доставки).
# Кнопки следующего шага (callback_data "orch1:<action>:<run_id>"): допустимые
# действия вычисляются из статуса RESULT детерминированно; ВЫКЛЮчены по
# умолчанию, включаются config/report.json (.buttons: true) или env
# ORCH_REPORT_BUTTONS=1. Нажатие кнопки доставляется платформе владельца
# (OpenClaw передаёт неопознанный callback агенту текстом); проектный навык
# ПЕРЕПРОВЕРЯЕТ состояние прогона перед действием (report-time состояние может
# устареть). OWNER PASS/GO остаются решениями владельца: нажатие кнопки = то
# же явное решение, merge/deploy выполняются только штатными скриптами,
# автоматического обхода НЕТ. Артефакты: report_actions.json (машинный список
# предложенных действий, пишется всегда), reply_markup.json (кнопки для
# отправки, только когда включены).
# Chat id из config/report.json; токен — см. блок доставки ниже (никогда не логируется).
set -u
ORCH_ROOT="${ORCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NO_SEND=0
if [[ "${1:-}" == "--no-send" ]]; then NO_SEND=1; shift; fi
RUN_DIR="${1:?run_dir}"
REPORT_CFG="$ORCH_ROOT/config/report.json"
CHAT_ID="$(jq -r '.chat_id' "$REPORT_CFG")"

if [[ -f "$RUN_DIR/.report_sent" ]]; then
  echo "report: already delivered ($(cat "$RUN_DIR/.report_sent")); skip (idempotent)"
  exit 0
fi

REPORT="$RUN_DIR/report.txt"
FULL="$RUN_DIR/report_full.txt"

# кнопки следующего шага: env ORCH_REPORT_BUTTONS переопределяет
# config/report.json (.buttons); по умолчанию выключены
CFG_BUTTONS="$(jq -r '.buttons // false' "$REPORT_CFG" 2>/dev/null || echo false)"
ORCH_BUTTONS_ENABLED="${ORCH_REPORT_BUTTONS:-$CFG_BUTTONS}"
export ORCH_BUTTONS_ENABLED

ORCH_ROOT="$ORCH_ROOT" python3 - "$RUN_DIR" > "$REPORT" <<'PYEOF'
import json, os, re, sys

run_dir = sys.argv[1]
run_id = os.path.basename(run_dir.rstrip("/"))

HUMAN_STATUS = {
    "READY_FOR_OWNER_PASS": "🟢 Готово к приёмке",
    "NO_CHANGE_REQUIRED":  "🟢 Изменения не требуются",
    "NEEDS_OWNER_INPUT":   "🟡 Нужна ваша проверка",
    "BLOCKED":             "🔴 Выполнение остановлено",
    "FAILED":              "🔴 Ошибка выполнения",
    "PERMISSION_VIOLATION":"🔴 Нарушение правил исполнения",
    "PASS": "🟢 Готово к приёмке", "OWNER_GATE": "🟡 Нужна ваша проверка", "FAIL": "🔴 Ошибка выполнения",
}
NEXT_ACTION = {
    "READY_FOR_OWNER_PASS": "Проверьте сценарии выше. Если всё работает — дайте OWNER PASS (словами в чате); затем merge/push по обычному процессу. Production — отдельным OWNER GO.",
    "NO_CHANGE_REQUIRED":   "Задачу можно закрыть: изменения не требуются, этот прогон — подтверждение.",
    "NEEDS_OWNER_INPUT":    "Прочитайте «Что проверить» и ответьте в чате; после вашего ответа задача продолжится новым прогоном.",
    "BLOCKED":              "Загляните в раздел «Что помешало». Обычно нужно уточнить постановку — затем новый прогон с новым run-id.",
    "FAILED":               "Посмотрите report_full.txt и evidence прогона; постановку или исполнение нужно поправить.",
    "PERMISSION_VIOLATION":"Исполнитель попытался выполнить запрещённое действие — детали в evidence; нужен разбор постановки.",
}

buttons_on = str(os.environ.get("ORCH_BUTTONS_ENABLED", "false")).strip().lower() in ("1", "true", "yes", "on")
# Допустимые следующие действия — только из фактического состояния прогона
# (детерминированно; нажатие кнопки = то же явное решение владельца, что и словами).
L_PASS, L_FIX, L_DET = "✅ Принять изменения", "🔧 Вернуть на доработку", "📋 Подробнее"
L_STG = "🧪 Выложить тестовую версию"
ACTIONS_BY_STATUS = {
    "READY_FOR_OWNER_PASS": [("pass", L_PASS), ("fix", L_FIX), ("details", L_DET)],
}
DETAILS_ONLY = [("details", L_DET)]
STATUS_PRIORITY = ["READY_FOR_OWNER_PASS", "NEEDS_OWNER_INPUT", "FAILED",
                   "BLOCKED", "PERMISSION_VIOLATION", "NO_CHANGE_REQUIRED"]

def registry_actions(project):
    root = os.environ.get("ORCH_ROOT", "")
    try:
        reg = json.load(open(os.path.join(root, "config", "projects.json")))
        return ((reg.get(project) or {}).get("project_actions")) or {}
    except Exception:
        return {}

def role_name(actions, role):
    for k, v in actions.items():
        if isinstance(v, dict) and v.get("ux_role") == role:
            return k
    return None

def staging_done(run_dir, stage_name, sha):
    log = os.path.join(run_dir, "log.jsonl")
    if not stage_name or not os.path.exists(log):
        return False
    try:
        for line in open(log, encoding="utf-8"):
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("event") in ("PROJECT_ACTION_ALLOWED", "PROJECT_ACTION_EXECUTED") \
               and e.get("action") == stage_name \
               and (not e.get("sha") or e.get("sha") == sha):
                return True
    except Exception:
        pass
    return False

def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return None

def task_for(task_dir):
    for f in sorted(os.listdir(task_dir)) if os.path.isdir(task_dir) else []:
        if f.endswith(".json"):
            t = load(os.path.join(task_dir, f))
            if isinstance(t, dict) and "goal" in t:
                return t
    return {}

def bullets(items, limit=5):
    return "\n".join(f"• {x}" for x in items[:limit])

def tests_numbers(res):
    """Числа тестов из checks[].detail — честно: только то, что доказано."""
    nums = []
    for c in res.get("checks", []):
        d = (c.get("detail") or "") + " " + (c.get("name") or "")
        m = re.search(r"(\d+)\s*passed", d)
        if m and m.group(1) not in [n for n in nums]:
            nums.append(m.group(1))
    return sorted(nums, key=int, reverse=True)

task_statuses = []
metas = []
blocks = []
for d in sorted(os.listdir(run_dir)):
    td = os.path.join(run_dir, d)
    rp = os.path.join(td, "RESULT.json")
    if not os.path.isdir(td) or not os.path.exists(rp):
        continue
    res = load(rp) or {}
    task = task_for(os.path.join(td, "tasks"))
    tid = res.get("task_id", d)
    st = res.get("status", "UNKNOWN")
    task_statuses.append(st)

    # --- 1. заголовок: только человеческий статус
    lines = [f"{tid} — {HUMAN_STATUS.get(st, '⚠️ ' + st)}", ""]

    # --- 2. что сделано: из summary/файлов исполнителя; без выдумывания
    done = []
    summary = (res.get("summary") or "").strip()
    if summary and summary != "-":
        first = re.split(r"(?<=[.!?])\s", summary)
        done = [(s.strip()[:280] + "…") if len(s.strip()) > 280 else s.strip() for s in first if s.strip()][:3]
    files = res.get("files_changed") or []
    if files and len(done) < 3:
        done.append(f"затронуто файлов: {len(files)} ({', '.join(files[:3])}{'…' if len(files) > 3 else ''})")
    if not done:
        done = ["(исполнитель не дал описания результата — см. report_full.txt и evidence)"]
    lines += ["Что сделано:"] + [f"• {x}" for x in done[:5]] + [""]

    # --- 3. проверки: только доказанные факты
    checks = []
    nums = tests_numbers(res)
    if len(nums) >= 2:
        checks.append(f"✓ целевые тесты: {nums[-1]} passed")
        checks.append(f"✓ полный набор: {nums[0]} passed")
    elif nums:
        checks.append(f"✓ тесты: {nums[0]} passed")
    gate_pass = [c.get("name") for c in res.get("checks", []) if str(c.get("name", "")).startswith("gate:") and c.get("status") == "PASS"]
    if gate_pass:
        checks.append(f"✓ служебные проверки прогонов ({len(gate_pass)})")
    if st != "PERMISSION_VIOLATION":
        checks.append("✓ нарушений правил исполнения нет")
        checks.append("✓ рабочий контур (production) не затрагивался")
    else:
        checks.append("✗ было запрещённое действие — см. evidence")
    lines += ["Проверки:"] + checks + [""]

    # --- 4. что проверить владельцу (или что помешало)
    ok_like = st in ("NEEDS_OWNER_INPUT", "READY_FOR_OWNER_PASS", "NO_CHANGE_REQUIRED", "OWNER_GATE", "PASS")
    lines.append("Что проверить владельцу:" if ok_like else "Что помешало:")
    if ok_like:
        todo = [str(u).strip() for u in (res.get("unresolved") or [])
                if str(u).strip() and not str(u).startswith(("OWNER GATE:", "OWNER PASS:"))]
        if not todo:
            todo = [re.sub(r"^OWNER (PASS|GATE):\s*", "", str(g)) for g in (task.get("owner_gates") or [])]
        if not todo:
            todo = ["прогоните сценарии задачи в тестовом боте и подтвердите результат"]
    else:
        todo = [str(res.get("reason") or res.get("unresolved") and res["unresolved"][0] or "см. report_full.txt и evidence")]
    lines += [f"{i+1}. {x[:220]}" for i, x in enumerate(todo[:3])]
    lines.append("")

    # --- 5. следующее действие (lifecycle-aware: B/C-состояния PROACTIVE-UX-1)
    lines.append("Следующее действие:")
    block_actions = ACTIONS_BY_STATUS.get(st, DETAILS_ONLY)
    if st in ("READY_FOR_OWNER_PASS", "PASS", "OWNER_GATE"):
        proj = task.get("project") or ""
        reg = registry_actions(proj)
        stage_name = role_name(reg, "staging")
        sha = res.get("commit_sha") or ""
        if stage_name and not staging_done(run_dir, stage_name, sha):
            state = "B"
            block_actions = [("staging", L_STG), ("details", L_DET)]
            lines.append("Проверки прошли успешно. Тестовая версия ещё не выкладывалась — "
                         "можно выложить её кнопкой «🧪» и проверить." if buttons_on else
                         "Тестовая версия ещё не выкладывалась; штатный staging deploy — "
                         "проектное действие прогона.")
        else:
            state = "C"
            if buttons_on:
                lines.append("Если тестовая версия проверена и всё работает — нажмите "
                             "«✅ Принять изменения» (изменения будут влиты в основную ветку). "
                             "Выкладка в рабочий бот — отдельным шагом после слияния.")
            else:
                lines.append(NEXT_ACTION.get(st, "см. report_full.txt"))
    else:
        state = "F"
        lines.append(NEXT_ACTION.get(st, "см. report_full.txt"))
    lines.append("")

    # --- 6. технические сведения (кратко; модели — только тут)
    tech = [f"run: {run_id}"]
    if res.get("branch"): tech.append(f"branch: {res['branch']}")
    if res.get("commit_sha"): tech.append(f"commit: {res['commit_sha']}")
    lines.append("Технические сведения:")
    lines.append("; ".join(tech))
    blocks.append("\n".join(lines))
    block_meta = {"status": st, "state": state, "project": task.get("project") or res.get("project"),
                  "sha": res.get("commit_sha") or "", "branch": res.get("branch") or "",
                  "actions": [{"action": a, "label": l} for a, l in block_actions]}
    metas.append((d, block_meta))

# допустимые следующие действия (машинный артефакт) + кнопки для отправки
primary = next((s for s in STATUS_PRIORITY if s in task_statuses),
               task_statuses[0] if task_statuses else None)
meta = next((m for _, m in metas if m["status"] == primary), {"state": None, "actions": []})
actions = []
for a in meta["actions"]:
    cb = "orch1:%s:%s" % (a["action"], run_id)
    if len(cb.encode("utf-8")) <= 64:  # лимит Telegram callback_data
        actions.append({"action": a["action"], "label": a["label"], "callback_data": cb})
with open(os.path.join(run_dir, "report_actions.json"), "w") as f:
    json.dump({"run_id": run_id, "primary_status": primary, "state": meta.get("state"),
               "project": meta.get("project"), "sha": meta.get("sha"), "branch": meta.get("branch"),
               "buttons_enabled": buttons_on, "actions": actions},
              f, ensure_ascii=False, indent=1)
if buttons_on and actions:
    markup = {"inline_keyboard": [[{"text": a["label"], "callback_data": a["callback_data"]}
                                   for a in actions]]}
    with open(os.path.join(run_dir, "reply_markup.json"), "w") as f:
        json.dump(markup, f, ensure_ascii=False)

print("\n\n".join(blocks) if blocks else f"Night run {run_id}: результатов нет (см. лог прогона)")
PYEOF

# полный технический отчёт (диагностика; не уходит в Telegram)
{
  echo "Night Orchestrator run $(basename "$RUN_DIR") — technical"
  for r in "$RUN_DIR"/*/RESULT.json; do
    [[ -e "$r" ]] || continue
    echo; echo "== $(jq -r '.task_id' "$r") :: $(jq -r '.status' "$r") =="
    jq -c '{reason, evidence, writes, attempts, executor_model_final, commit_sha, branch}' "$r" 2>/dev/null
  done
  models_line="$(cat "$RUN_DIR"/*/model_calls.jsonl 2>/dev/null | jq -r 'select(.ok) | .model' | sort | uniq -c | awk '{printf "%s: %s calls; ", $2, $1}')"
  gpt_calls="$(cat "$RUN_DIR"/*/model_calls.jsonl 2>/dev/null | grep -c 'gpt-5.6' || true)"
  echo; echo "Models: ${models_line:-—}; GPT-5.6 calls: ${gpt_calls:-0}"
} > "$FULL"

echo "--- report.txt (владельцу) ---"; cat "$REPORT"; echo "---"

if [[ "$NO_SEND" == "1" ]]; then
  echo "report: built (no-send mode); Telegram delivery skipped"
  exit 0
fi

# ---- send via Telegram -----------------------------------------------------
# доставка отчёта: токен из ORCH_REPORT_TOKEN или config/report.json (report_token_cmd);
# Источник токена доставки: env ORCH_REPORT_TOKEN (значение) ИЛИ команда
# report_token_cmd из config/report.json (вывод команды; ключи не логируются).
# Без источника доставка пропускается с пояснением (сборка отчёта не страдает).
TOKEN="${ORCH_REPORT_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$ORCH_ROOT/config/report.json" ]; then
  _cmd="$(jq -r '.report_token_cmd // ""' "$ORCH_ROOT/config/report.json")"
  [ -n "$_cmd" ] && TOKEN="$($_cmd 2>/dev/null || true)"
fi
if [ -z "$TOKEN" ]; then
  echo "report: токен доставки не настроен (ORCH_REPORT_TOKEN или config/report.json:report_token_cmd); доставка пропущена" >&2
  exit 0
fi

SEND_ARGS=(--data-urlencode "chat_id=${CHAT_ID}" --data-urlencode "text@${REPORT}")
[[ -s "$RUN_DIR/reply_markup.json" ]] && \
  SEND_ARGS+=(--data-urlencode "reply_markup@${RUN_DIR}/reply_markup.json")
resp="$(curl -sS -m 30 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" "${SEND_ARGS[@]}" -w '\n%{http_code}')"
rc=$?
printf '%s\n' "$resp" > "$RUN_DIR/tg_send_response.json"
ok="$(printf '%s' "$resp" | head -n -1 | jq -r '.ok // false' 2>/dev/null)"
jq -cn --arg ts "$(date -u +%FT%TZ)" --arg ok "$ok" '{ts:$ts, event:"REPORT_SENT", ok:($ok=="true")}' >> "$RUN_DIR/log.jsonl" 2>/dev/null
[[ "$ok" == "true" ]] && { date -u +%FT%TZ > "$RUN_DIR/.report_sent"; echo "report: delivered to $CHAT_ID"; exit 0; }
echo "report: telegram send failed rc=$rc resp=$(printf '%s' "$resp" | head -c 300)"
exit 1
