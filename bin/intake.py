#!/usr/bin/env python3
"""Intake Gate — приём задач обычным языком и цикл уточнений.

Детерминированный движок (без LLM): классификация намерения, оценка полноты
постановки, 1–3 уточняющих вопроса по продуктовым неопределённостям,
черновики backlog, формирование TASK и канонический запуск. Ядро Night
Orchestrator v1 не затрагивается. Специфики конкретных проектов/чатов не
зашито: проект — из config/projects.json, пути — от ORCH_ROOT.

Команды:
  message  <текст> [--project P] [--chat-id ID]   обработать сообщение владельца
  answer   <текст или intake_id: текст>            ответ владельца на вопросы
  cancel   [intake_id]                             отмена/«пока не делай»
  defer    [intake_id]                             «вернёмся позже»
  to-backlog [intake_id]                           «положи в бэклог»
  from-result <run_dir>                            NEEDS_OWNER_INPUT -> intake
  status   [intake_id]                             состояние
  list                                              ожидающие/активные
  task     <intake_id> [--out FILE]                показать TASK
  launch   <intake_id> [--dry-run]                 создать run + TASK (+запуск)

Хранение: $ORCH_ROOT/intake/INTAKE-*.json; черновики backlog — intake/backlog-drafts.md.
"""
import json
import os
import re
import subprocess
import sys
import datetime

_default_root = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ORCH_ROOT = os.environ.get("ORCH_ROOT", _default_root)
INTAKE_DIR = os.environ.get("INTAKE_DIR", os.path.join(ORCH_ROOT, "intake"))
DEFAULT_PROJECT = os.environ.get("INTAKE_PROJECT", "example-project")

# ---------------------------------------------------------------- утилиты --

def now_iso():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

def slugify(text, limit=24):
    translit = {"а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"e","ж":"zh","з":"z","и":"i",
                "й":"y","к":"k","л":"l","м":"m","н":"n","о":"o","п":"p","р":"r","с":"s","т":"t",
                "у":"u","ф":"f","х":"h","ц":"ts","ч":"ch","ш":"sh","щ":"sch","ъ":"","ы":"y","ь":"",
                "э":"e","ю":"yu","я":"ya"}
    s = "".join(translit.get(c, c) for c in text.lower())
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return (s or "msg")[:limit].strip("-")

def project_repo(project):
    reg = os.path.join(ORCH_ROOT, "config", "projects.json")
    try:
        return json.load(open(reg))[project]["repo"]
    except Exception:
        return None

# --------------------------------------------------------- классификация ----
# Смысловые маркеры намерения (не одиночные ключевые слова: правило = класс
# маркеров + контекст явности). Порядок приоритета: управление > RUN > BACKLOG.

RUN_MARKERS = [
    r"\bзапусти\w*\b", r"\bсделай\b", r"\bвыполни\w*\b", r"\bисправь\b",
    r"\bреализуй\w*\b", r"\bпроверь\b", r"\bпочини\b", r"\bдобавь\s+фун\w+",
    r"^run\b", r"\bзапускай\b",
]
BACKLOG_MARKERS = [
    r"\bв\s+бэклог\w*\b", r"\bв\s+backlog\b", r"\bзапиши\s+идею\b",
    r"\bзапомним\b", r"\bзапиши\s+задач\w*\b", r"\bдобавь\s+в\s+бэклог\w*",
    r"\bbacklog\b", r"\bбэклог\w*\b(?=.*\b(идея|заметк|запиши|добавь|положи)\b)",
]
DISCUSS_MARKERS = [
    r"\bобсудим\b", r"\bподумаем\b", r"\bкак\s+ты\s+думаешь\b", r"\bидея\s+такая\b",
    r"\bчто\s+если\b", r"\bпосоветуй\b", r"\bмнение\b",
]
CANCEL_MARKERS = [r"^\s*(отмени|отмена)\b", r"\bпока\s+не\s+делай\b", r"\bне\s+запускай\b"]
DEFER_MARKERS = [r"\bверн\w*\s+позже\b", r"\bпотом\b(?=.*\b(верн|займ)\w*)", r"\bотложи\b"]
TO_BACKLOG_LIVE = [r"\bположи\s+в\s+бэклог\w*\b", r"\bв\s+бэклог\s+пока\b"]

def matches(text, patterns):
    return any(re.search(p, text, re.IGNORECASE) for p in patterns)

# Продуктовые неопределённости, меняющие результат (спрашиваем) — против
# технических, которые исполнитель выяснит сам (не спрашиваем).
PRODUCT_GAPS = [
    (r"\b(удобнее|лучше|улучш\w+|непонятно|не\s+нравится|проще)\b",
     "Что именно сейчас неудобно и какой сценарий считать правильным?"),
    (r"\b(всем|пользовател\w+|кому)\b.*\b(доступ\w*|виден|видят)\b",
     "Кому должна быть доступна функция: всем или сначала ограниченной группе?"),
    (r"\b(платн\w+|цен\w+|монетизац\w+|stars|звёзд\w+|звезд\w+)\b",
     "Это платная функция или бесплатная на этом этапе?"),
    (r"\b(удал\w+|стереть|очист\w+|destructive|безвозвратн\w+)\b",
     "Подтвердите: допустимо ли безвозвратное удаление данных, и для кого?"),
    (r"\b(текст\s+сообщения|формулировк\w+|публичн\w+|рассылк\w+|анонс\w*)\b",
     "Какой публичный текст считаем правильным? Пришлите формулировку."),
]
TECH_ONLY = [
    r"\b(где\s+(лежит|находится)|какой\s+файл|какая\s+функция|какие\s+тесты)",
    r"\b(worktree|git\s+status|pytest)\b",
]

def completeness(text):
    """Грубая оценка полноты постановки: цель + критерий/область."""
    has_goal = len(text) > 25
    has_criteria = bool(re.search(r"\b(чтобы|должен|ожидается|критери\w+|провер\w+|готово\s+когда)\b", text, re.I))
    return has_goal and has_criteria

def open_questions_for(text, known, already_asked=()):
    """Вопросы только по открытым гэпам; уже заданные/отвеченные не повторяются."""
    asked = {a.strip() for a in already_asked}
    qs = []
    for pat, q in PRODUCT_GAPS:
        if re.search(pat, text, re.I) and q not in known and q not in asked:
            qs.append(q)
    if not completeness(text) and not matches(text, TECH_ONLY):
        default_q = "Что именно должно измениться и как поймём, что готово?"
        if default_q not in asked and default_q not in qs:
            qs.append(default_q)
    return qs[:3]

def classify(text):
    if matches(text, CANCEL_MARKERS):   return "CANCEL"
    if matches(text, DEFER_MARKERS):    return "DEFER"
    if matches(text, TO_BACKLOG_LIVE):  return "TO_BACKLOG"
    if matches(text, BACKLOG_MARKERS):  return "BACKLOG"
    if matches(text, RUN_MARKERS):      return "RUN"
    if matches(text, DISCUSS_MARKERS):  return "DISCUSSION"
    return "DISCUSSION"

# ------------------------------------------------------------- хранилище ---

def intake_path(iid):
    return os.path.join(INTAKE_DIR, f"INTAKE-{iid}.json")

def load_intake(iid):
    p = intake_path(iid)
    if not os.path.exists(p):
        sys.exit(f"intake не найден: {iid}")
    return json.load(open(p))

def save_intake(st):
    st["updated_at"] = now_iso()
    os.makedirs(INTAKE_DIR, exist_ok=True)
    tmp = intake_path(st["intake_id"]) + ".tmp"
    json.dump(st, open(tmp, "w"), ensure_ascii=False, indent=1)
    os.replace(tmp, intake_path(st["intake_id"]))

def new_intake(text, project, chat=None):
    iid = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%S") + "-" + slugify(text)
    return {
        "intake_id": iid, "project": project, "original_message": text,
        "classification": "DISCUSSION", "known_facts": [], "open_questions": [],
        "owner_answers": {}, "proposed_task": None, "backlog_draft": None,
        "status": "NEW", "chat": chat, "source_run": None,
        "created_at": now_iso(), "updated_at": now_iso(),
    }

def waiting_intakes():
    out = []
    if not os.path.isdir(INTAKE_DIR):
        return out
    for f in sorted(os.listdir(INTAKE_DIR)):
        if not f.startswith("INTAKE-") or not f.endswith(".json"):
            continue
        st = json.load(open(os.path.join(INTAKE_DIR, f)))
        if st["status"] == "WAITING_OWNER":
            out.append(st)
    return out

def pick_waiting(explicit_id=None):
    ws = waiting_intakes()
    if explicit_id:
        for w in ws:
            if w["intake_id"] == explicit_id or w["intake_id"].endswith(explicit_id):
                return w, None
        return None, f"ожидающий intake '{explicit_id}' не найден"
    if len(ws) == 1:
        return ws[0], None
    if not ws:
        return None, None
    names = "\n".join(f"- {w['intake_id']} ({(w['original_message'] or '')[:60]})" for w in ws)
    return None, ("ожидающих уточнения несколько — выберите задачу:\n" + names)

# --------------------------------------------------------- backlog-дубли --

def backlog_file_notes(project):
    """Похожие записи: черновики intake + бэклог проекта (read-only)."""
    notes = []
    drafts = os.path.join(INTAKE_DIR, "backlog-drafts.md")
    if os.path.exists(drafts):
        notes += [l for l in open(drafts, encoding="utf-8") if l.startswith("## ")]
    repo = project_repo(project)
    if repo:
        todo = os.path.join(repo, "state", "TODO.md")
        if os.path.exists(todo):
            notes += [l for l in open(todo, encoding="utf-8") if l.startswith("### ")]
    return notes

def find_duplicate(title, project):
    words = {w for w in re.findall(r"[a-zа-яё0-9]{4,}", title.lower())}
    for note in backlog_file_notes(project):
        score = sum(1 for w in re.findall(r"[a-zа-яё0-9]{4,}", note.lower()) if w in words)
        if len(words) >= 2 and score >= 2:
            return note.strip()
    return None

# --------------------------------------------------------- вывод человеку --

def reply(status_line, questions=None, extra=None):
    print(status_line)
    if questions:
        n = len(questions)
        print(f"\nПеред продолжением нужно уточнить ({n} "
              f"{'вопрос' if n == 1 else 'вопроса'}):")
        for i, q in enumerate(questions, 1):
            print(f"{i}. {q}")
        print("\nОтветьте обычным текстом — я продолжу тот же контекст задачи.")
    if extra:
        print(extra)

# --------------------------------------------------------------- команды ---

def cmd_message(text, project, chat):
    kind = classify(text)
    if kind == "CANCEL":
        w, err = pick_waiting()
        if w:
            w["status"] = "CANCELLED"; save_intake(w)
            return reply(f"✖ Задача «{(w['original_message'] or '')[:60]}» отменена. История сохранена.")
        return reply("Нечего отменять: ожидающих задач нет.")
    if kind == "DEFER":
        w, _ = pick_waiting()
        if w:
            w["status"] = "DEFERRED"; save_intake(w)
            return reply("⏸ Задача отложена (вернёмся позже). История сохранена.")
        return reply("Откладывать нечего.")
    if kind == "TO_BACKLOG":
        w, _ = pick_waiting()
        if w:
            w["classification"] = "BACKLOG"; w["status"] = "READY_TO_BACKLOG"
            save_intake(w)
            return reply("📝 Переведено в бэклог. Выполнение не запускается.")
    st = new_intake(text, project, chat)
    if kind == "DISCUSSION":
        st["classification"] = "DISCUSSION"; st["status"] = "COMPLETED"
        st["known_facts"].append("режим: обсуждение, без задачи")
        save_intake(st)
        return reply("💬 Обсуждение (ничего не запускаю и в бэклог не пишу).",
                     None, "Скажите «запусти …» или «добавь в бэклог …», когда решите.")
    if kind == "BACKLOG":
        st["classification"] = "BACKLOG"
        qs = open_questions_for(text, st["known_facts"])
        if qs:
            st["status"] = "WAITING_OWNER"
            st["open_questions"] = [{"qid": f"q{i+1}", "text": q, "asked": True} for i, q in enumerate(qs)]
            save_intake(st)
            return reply("📝 Понял: сохранить в бэклог. Для качественной записи уточню.", qs)
        st["status"] = "READY_TO_BACKLOG"; save_intake(st)
        return finalize_backlog(st)
    if kind == "RUN":
        st["classification"] = "RUN"
        qs = open_questions_for(text, st["known_facts"])
        if qs:
            st["status"] = "WAITING_OWNER"
            st["open_questions"] = [{"qid": f"q{i+1}", "text": q, "asked": True} for i, q in enumerate(qs)]
            save_intake(st)
            return reply("▶ Задача на выполнение. Пока не хватает пары деталей.", qs)
        st["status"] = "READY_TO_RUN"; save_intake(st)
        return reply("▶ Постановка достаточна. Скажите «запускай» (или launch "
                     f"{st['intake_id']}), либо откройте TASK: task {st['intake_id']}.")
    save_intake(st)
    return reply("💬 Принято как обсуждение.")

def finalize_backlog(st):
    dup = find_duplicate(st["original_message"], st["project"])
    if dup:
        st["status"] = "DEFERRED"; save_intake(st)
        return reply("Похожая запись уже есть — новую молча не создаю:",
                     None, f"{dup}\n\nДополнить её? Скажите «дополни запись …».")
    title = (st["original_message"] or "")[:80]
    draft = (
        f"\n## {title} ({now_iso()[:10]}, intake {st['intake_id']})\n"
        f"- Проблема/идея: {st['original_message']}\n"
        f"- Зачем: уточняется владельцем при переносе в бэклог проекта\n"
        f"- Факты: {'; '.join(st['known_facts']) or '—'}\n"
        f"- Ответы владельца: {json.dumps(st['owner_answers'], ensure_ascii=False) if st['owner_answers'] else '—'}\n"
    )
    os.makedirs(INTAKE_DIR, exist_ok=True)
    open(os.path.join(INTAKE_DIR, "backlog-drafts.md"), "a", encoding="utf-8").write(draft)
    st["backlog_draft"] = draft.strip(); st["status"] = "COMPLETED"; save_intake(st)
    return reply("📝 Черновик backlog-записи готов (intake/backlog-drafts.md). "
                 "Выполнение не запускается. Перенос в бэклог репозитория — отдельный шаг.")

def cmd_answer(text):
    explicit = None
    m = re.match(r"^([0-9]{8}T[0-9]{6}-[a-z0-9-]+)\s*[:\-]\s*(.+)$", text, re.S)
    if m:
        explicit, text = m.group(1), m.group(2)
    w, err = pick_waiting(explicit)
    if err:
        return reply("⚠ " + err)
    if not w:
        return reply("Нет задачи, ждущей вашего ответа. Сформулируйте задачу заново.")
    answered = 0
    for q in w["open_questions"]:
        if not q.get("answer"):
            q["answer"] = text; w["owner_answers"][q["qid"]] = text; answered += 1
    w["known_facts"].append(f"ответ владельца: {text[:300]}")
    remaining = [q for q in w["open_questions"] if not q.get("answer")]
    if remaining:
        save_intake(w)
        return reply("Записал. Остался вопрос:",
                     [q["text"] for q in remaining])
    # всё отвечено
    if w["classification"] == "BACKLOG":
        w["status"] = "READY_TO_BACKLOG"; save_intake(w)
        return finalize_backlog(w)
    if w.get("source_run"):
        w["status"] = "READY_TO_RUN"; save_intake(w)
        return reply("✅ Ответ принят в контекст задачи. Предлагаю продолжение "
                     f"новым прогоном (launch {w['intake_id']}); прежний run-id не переиспользуется. "
                     "Если ответ меняет требования сильно — сначала посмотрите TASK (task …).")
    # RUN: проверить, не вскрылись ли новые продуктовые вопросы (без повторов)
    asked = tuple(q["text"] for q in w["open_questions"])
    qs = open_questions_for(w["original_message"] + " " + text, w["known_facts"], asked)
    if qs:
        w["status"] = "WAITING_OWNER"
        w["open_questions"] += [{"qid": f"q{len(w['open_questions'])+i+1}", "text": q, "asked": True} for i, q in enumerate(qs)]
        save_intake(w)
        return reply("Почти готово. Ещё важное:", qs)
    w["status"] = "READY_TO_RUN"; save_intake(w)
    return reply("▶ Постановка достаточна. Запускайте: launch "
                 f"{w['intake_id']} (или task {w['intake_id']} — посмотреть TASK).")

def next_run_id(st):
    base = datetime.datetime.utcnow().strftime("%Y%m%d") + "-" + slugify(st["original_message"], 18)
    n, rid = 1, f"{base}-01"
    runs = os.path.join(ORCH_ROOT, "runs")
    while os.path.exists(os.path.join(runs, rid)):
        n += 1; rid = f"{base}-{n:02d}"
    return rid

def project_profile(project):
    """Проектные умолчания TASK — из реестра (не зашиты в код): Night
    Orchestrator остаётся универсальным исполнителем для любого проекта."""
    try:
        return json.load(open(os.path.join(ORCH_ROOT, "config", "projects.json")))[project]
    except Exception:
        return {}

def build_task(st):
    prof = project_profile(st["project"])
    facts = "; ".join([st["original_message"]] + st["known_facts"])
    answers = "; ".join(f"{k}: {v}" for k, v in st["owner_answers"].items())
    goal = st["original_message"]
    if answers:
        goal += "\n\nПодтверждённые факты и ответы владельца:\n- " + "\n- ".join(
            [f for f in st["known_facts"]] + [f"{k}: {v}" for k, v in st["owner_answers"].items()])
    goal += ("\n\nЦикл: критерии → минимальное исследование → при баге сначала падающий тест → "
             "минимальная реализация → целевые тесты → полный офлайн-набор проверок → итоговый RESULT. "
             "Технические детали выяснить самостоятельно (только чтение). Не выдумывать продуктовые решения.")
    # read-only, когда владелец явно сказал «не меняет файлы / только проверить»:
    # подтверждённый факт из постановки, не догадка движка
    text_all = st["original_message"] + " " + json.dumps(st["owner_answers"], ensure_ascii=False)
    verify_only = bool(re.search(r"(не\s+меня\w+|без\s+изменени|только\s+провер|ничего\s+не\s+меня\w*)", text_all, re.I))
    writable = st["classification"] == "RUN" and not verify_only
    return {
        "project": st["project"], "task_id": re.sub(r"[^A-Za-z0-9_.-]", "-", st["intake_id"].split("-", 1)[1]).upper()[:24] or "TASK-1",
        "goal": goal, "risk": "MEDIUM" if writable else "LOW",
        "mode": "writable" if writable else "read_only",
        "allowed_paths": [],
        "forbidden_paths": prof.get("forbidden_paths", [".env", ".env.*"]),
        "bootstrap": prof.get("bootstrap", []),
        "checks": [], "owner_gates": ["OWNER PASS: приёмка результата владельцем"],
        "_source_intake": st["intake_id"], "_source_run": st.get("source_run"),
        "_answers": answers, "_facts": facts,
    }

def cmd_task(iid, out=None):
    st = load_intake(iid)
    task = st.get("proposed_task") or build_task(st)
    if out:
        json.dump(task, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        return reply(f"TASK записан: {out}")
    print(json.dumps(task, ensure_ascii=False, indent=1))

def cmd_launch(iid, dry=False):
    st = load_intake(iid)
    if st["status"] not in ("READY_TO_RUN",):
        return reply(f"Запуск возможен только из READY_TO_RUN (сейчас {st['status']}).")
    task = st.get("proposed_task") or build_task(st)
    rid = next_run_id(st)
    task_clean = {k: v for k, v in task.items() if not k.startswith("_")}
    if dry:
        return reply(f"[dry-run] run-id: {rid}\n" + json.dumps(task_clean, ensure_ascii=False, indent=1))
    ag = os.path.join(ORCH_ROOT, "bin", "task.sh")
    r = subprocess.run(["bash", ag, "new", rid], capture_output=True, text=True)
    if r.returncode != 0:
        return reply("Не удалось создать run: " + r.stderr.strip())
    task_file = os.path.join(ORCH_ROOT, "runs", rid, "tasks", "task.json")
    json.dump(task_clean, open(task_file, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    st["proposed_task"] = task; st["status"] = "COMPLETED"
    st["known_facts"].append(f"запущен run {rid}"); save_intake(st)
    night = os.path.join(ORCH_ROOT, "bin", "night_run.sh")
    subprocess.Popen(["bash", night, os.path.join(ORCH_ROOT, "runs", rid)],
                     stdout=open(os.path.join(ORCH_ROOT, "runs", rid, "night_run.out"), "w"),
                     stderr=subprocess.STDOUT, start_new_session=True)
    return reply(f"▶ Запущен канонический прогон {rid}. Отчёт придёт сюда; "
                 f"ждать: task.sh wait {rid}.")

def cmd_from_result(run_dir):
    import glob as _g
    cands = [os.path.join(run_dir, "RESULT.json")] + sorted(_g.glob(os.path.join(run_dir, "*", "RESULT.json")))
    rp = next((c for c in cands if os.path.exists(c)), None)
    if not rp:
        sys.exit(f"RESULT.json не найден в {run_dir}")
    res = json.load(open(rp))
    run_id = os.path.basename(run_dir.rstrip("/"))
    if res.get("status") != "NEEDS_OWNER_INPUT":
        return reply(f"Статус {res.get('status')} — вопросов владельцу нет.")
    qs = [u for u in (res.get("unresolved") or []) if u][:3] or ["Смотрите подробности в отчёте прогона."]
    st = new_intake(f"[продолжение {run_id}] " + (res.get("summary") or "")[:200], res.get("project", DEFAULT_PROJECT))
    st["classification"] = "RUN"; st["source_run"] = run_id
    st["status"] = "WAITING_OWNER"
    st["open_questions"] = [{"qid": f"q{i+1}", "text": q, "asked": True} for i, q in enumerate(qs)]
    st["known_facts"].append(f"из RESULT {run_id}: reason={res.get('reason') or '—'}")
    save_intake(st)
    return reply("🟡 Прогон ждёт вашего решения:", qs,
                 f"Ответьте текстом — продолжу задачу {st['intake_id']} новым прогоном.")

def cmd_status(iid=None):
    if iid:
        st = load_intake(iid)
        return reply(json.dumps(st, ensure_ascii=False, indent=1))
    for w in waiting_intakes():
        print(f"WAITING {w['intake_id']}: {(w['original_message'] or '')[:70]}")

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__); sys.exit(2)
    cmd, rest = args[0], args[1:]
    if cmd == "message":
        text = " ".join(rest)
        project = DEFAULT_PROJECT; chat = None
        if "--project" in args:
            i = args.index("--project"); project = args[i + 1]; text = " ".join(a for a in rest if not a.startswith("--"))
        if "--chat-id" in args:
            chat = {"chat_id": args[args.index("--chat-id") + 1]}
        cmd_message(text, project, chat)
    elif cmd == "answer":
        cmd_answer(" ".join(rest))
    elif cmd == "cancel":
        cmd_message("отмени", DEFAULT_PROJECT, None)
    elif cmd == "defer":
        cmd_message("вернёмся позже", DEFAULT_PROJECT, None)
    elif cmd == "to-backlog":
        cmd_message("положи в бэклог", DEFAULT_PROJECT, None)
    elif cmd == "from-result":
        cmd_from_result(rest[0])
    elif cmd == "status":
        cmd_status(rest[0] if rest else None)
    elif cmd == "list":
        cmd_status()
    elif cmd == "task":
        out = None
        if "--out" in rest:
            i = rest.index("--out"); out = rest[i + 1]; rest = rest[:i] + rest[i + 2:]
        cmd_task(rest[0], out)
    elif cmd == "launch":
        cmd_launch(rest[0], dry="--dry-run" in rest)
    else:
        print(__doc__); sys.exit(2)

if __name__ == "__main__":
    main()
