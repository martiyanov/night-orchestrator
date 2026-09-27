#!/usr/bin/env bash
# report.sh — human-readable owner report from RESULT.json + TASK, sent via Telegram.
# Usage: report.sh [--no-send] <run_dir>
#   --no-send — построить текст без Telegram (selftest/диагностика)
# Файлы:
#   report.txt      — человеческий текст (он же уходит в Telegram)
#   report_full.txt — технические сведения (модели/счётчики) для диагностики
# Идемпотентность: повторный вызов НЕ отправляет отчёт дважды (маркер
# $RUN_DIR/.report_sent ставится только после успешной доставки).
# Кнопки [✅ Принять][❌ Вернуть][📋 Подробнее]: подготовлены, ВЫКЛЮчены по
# умолчанию; включаются env ORCH_REPORT_BUTTONS=1. Нажатия ни к чему не
# приводят (callback-обработчика нет) — OWNER PASS/GO остаются словами
# владельца, автоматического merge/deploy НЕТ.
# Bot token read at send time from openclaw.json (never logged). Chat id from config/report.json.
set -u
ORCH_ROOT="${ORCH_ROOT:-$HOME/.openclaw/night-orchestrator}"
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

python3 - "$RUN_DIR" > "$REPORT" <<'PYEOF'
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

    # --- 5. следующее действие
    lines.append("Следующее действие:")
    lines.append(NEXT_ACTION.get(st, "см. report_full.txt"))
    lines.append("")

    # --- 6. технические сведения (кратко; модели — только тут)
    tech = [f"run: {run_id}"]
    if res.get("branch"): tech.append(f"branch: {res['branch']}")
    if res.get("commit_sha"): tech.append(f"commit: {res['commit_sha']}")
    lines.append("Технические сведения:")
    lines.append("; ".join(tech))
    blocks.append("\n".join(lines))

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
# botToken source is configurable (ORCH_REPORT_TOKEN_CMD or openclaw.json);: {"source":"file","provider":"filekeys","id":"/providers/telegram/botToken"}
TOKEN="${ORCH_REPORT_TOKEN:-$(python3 - <<'PYEOF'
import json, os
cfg = json.load(open(os.path.expanduser("~/.openclaw/openclaw.json")))
bt = cfg["channels"]["telegram"]["botToken"]
if isinstance(bt, dict) and bt.get("source") == "file":
    provs = json.load(open(os.path.expanduser("~/.config/openclaw/secrets/providers.json")))["providers"]
    parts = bt["id"].strip("/").split("/")  # e.g. ["providers","telegram","botToken"]
    node = provs
    for p in parts[1:]:
        node = node[p]
    print(node)
else:
    print(bt)
PYEOF
)}"
if [[ -z "$TOKEN" ]]; then echo "report: no bot token"; exit 1; fi

SEND_ARGS=(--data-urlencode "chat_id=${CHAT_ID}" --data-urlencode "text@${REPORT}")
if [[ "${ORCH_REPORT_BUTTONS:-0}" == "1" ]]; then
  SEND_ARGS+=(--data-urlencode 'reply_markup={"inline_keyboard":[[{"text":"✅ Принять","callback_data":"report:accept"},{"text":"❌ Вернуть","callback_data":"report:reject"},{"text":"📋 Подробнее","callback_data":"report:details"}]]}')
fi
resp="$(curl -sS -m 30 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" "${SEND_ARGS[@]}" -w '\n%{http_code}')"
rc=$?
printf '%s\n' "$resp" > "$RUN_DIR/tg_send_response.json"
ok="$(printf '%s' "$resp" | head -n -1 | jq -r '.ok // false' 2>/dev/null)"
jq -cn --arg ts "$(date -u +%FT%TZ)" --arg ok "$ok" '{ts:$ts, event:"REPORT_SENT", ok:($ok=="true")}' >> "$RUN_DIR/log.jsonl" 2>/dev/null
[[ "$ok" == "true" ]] && { date -u +%FT%TZ > "$RUN_DIR/.report_sent"; echo "report: delivered to $CHAT_ID"; exit 0; }
echo "report: telegram send failed rc=$rc resp=$(printf '%s' "$resp" | head -c 300)"
exit 1
