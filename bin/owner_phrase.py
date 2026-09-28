#!/usr/bin/env python3
"""owner_phrase.py — детерминированный маршрутизатор owner-lifecycle фраз
(PROACTIVE-UX-RELEASE-ROUTING-1).

Проблема-класс: явное решение владельца по жизненному циклу («принимаю
изменения», «влей проверенную версию», «разрешаю выложить в рабочий бот»)
НЕ является новой задачей. Раньше такая фраза могла быть переформулирована
LLM в «запусти выпуск …», уйти в intake как обычная RUN-задача и погибнуть
на guard (либо, хуже, выполнить deploy в автономном прогоне).

Здесь — только детерминированные правила (регэкспы явных формулировок +
structured state: прогоны/authorizations/git), никакого свободного
парсинга. Выход:
  INTENT=none      — не lifecycle-фраза: обычный путь intake (как раньше)
  INTENT=accept    — приёмка: одна candidacy-дуэль → EXECUTE orch1:pass
  INTENT=deploy    — выкладка: dispatch orch1:deploy / release-flow ответ
  INTENT=question  — неоднозначно (несколько кандидатов) → вопрос владельцу
Блок ===EXECUTE=== содержит ТОЧНУЮ команду (агент выполняет её дословно,
ничего не изобретая); при её отсутствии — только человеческий текст/вопрос.
Внутренние имена действий владельцу не показываются.

Никаких side effects: модуль только читает состояние (runs/auth/git).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

ORCH_ROOT = os.environ.get("ORCH_ROOT") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNS_DIR = os.environ.get("ORCH_RUNS_DIR") or os.path.join(ORCH_ROOT, "runs")
AUTH_DIR = os.environ.get("ORCH_AUTH_DIR") or os.path.join(ORCH_ROOT, "authorizations")

# Явные формулировки решений владельца (RU; ложных срабатываний на обычные
# задачи «запусти/сделай X» нет — маркеры задач в intake отсутствуют здесь).
ACCEPT_PAT = re.compile(
    r"(принима(ю|ем|ешь)|принять|принят\w*)\s+(изменени\w*|версию\w*|результат\w*)"
    r"|влей(те)?\s+\S|влива(й|йте)|слей(те)?\s+\S"
    r"|owner\s*pass", re.I)
DEPLOY_PAT = re.compile(
    r"(выложи\w*|выкладывай|разреша\w*\s+выложить|можно\s+выкладывать"
    r"|выпусти\w*|публикуй\w*|задеплой\w*|деплой\w*)"
    r"[^\n]{0,120}(рабоч\w+\s+бот|в\s+прод\w*|production)"
    r"|owner\s*go|выложить[^\n]{0,120}рабоч\w+\s+бот", re.I)


def _die(msg):
    print("owner_phrase: REFUSED: %s" % msg, file=sys.stderr)
    sys.exit(2)


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def _load_auths(project):
    out = []
    if not os.path.isdir(AUTH_DIR):
        return out
    for f in sorted(os.listdir(AUTH_DIR)):
        if not (f.startswith("AUTH-") and f.endswith(".json")):
            continue
        try:
            a = json.load(open(os.path.join(AUTH_DIR, f), encoding="utf-8"))
        except Exception:
            continue
        if a.get("project") == project:
            out.append(a)
    return out


def _short(sha):
    return sha[:7] if sha else "?"


def _run_states(project):
    """[(run_id, state)] по тем же правилам, что owner_action.sh:
    awaiting_accept (READY_FOR_OWNER_PASS/PASS без решения и без executed
    accept) и accepted_not_deployed."""
    awaiting, accepted = [], []
    if not os.path.isdir(RUNS_DIR):
        return awaiting, accepted
    auths = _load_auths(project)
    accept_sha = {a["sha"] for a in auths
                  if a.get("action") == _accept_action_name(project)
                  and a.get("status") == "executed"}
    deploy_sha = {a["sha"] for a in auths
                  if a.get("action") == _deploy_action_name(project)
                  and a.get("status") == "executed"}
    for rid in sorted(os.listdir(RUNS_DIR)):
        rdir = os.path.join(RUNS_DIR, rid)
        if not os.path.isdir(rdir):
            continue
        res_path = None
        for d in sorted(os.listdir(rdir)):
            p = os.path.join(rdir, d, "RESULT.json")
            if os.path.isfile(p):
                res_path = p
                break
        if not res_path:
            continue
        try:
            res = json.load(open(res_path, encoding="utf-8"))
        except Exception:
            continue
        tdir = os.path.join(rdir, "tasks")
        project_ok = False
        if os.path.isdir(tdir):
            for tf in sorted(os.listdir(tdir)):
                if tf.endswith(".json"):
                    project_ok = project_ok or (
                        json.load(open(os.path.join(tdir, tf), encoding="utf-8"))
                        .get("project") == project)
        if not project_ok:
            continue
        st = res.get("status")
        sha = res.get("commit_sha") or ""
        if len(sha) != 40:
            continue
        if os.path.isfile(os.path.join(rdir, ".owner_decision.json")):
            continue
        if st in ("READY_FOR_OWNER_PASS", "PASS") and sha not in accept_sha:
            awaiting.append((rid, sha))
        elif sha in accept_sha and sha not in deploy_sha:
            accepted.append((rid, sha))
    return awaiting, accepted


def _accept_action_name(project):
    return _registry_role(project, "accept") or "owner_accept"


def _deploy_action_name(project):
    return _registry_role(project, "production") or "production_go"


def _registry_role(project, role):
    reg = os.path.join(ORCH_ROOT, "config", "projects.json")
    try:
        acts = json.load(open(reg, encoding="utf-8"))[project].get("project_actions") or {}
    except Exception:
        return None
    for name, spec in acts.items():
        if isinstance(spec, dict) and spec.get("ux_role") == role:
            return name
    return None


def _git(repo, *args):
    try:
        r = subprocess.run(["git", "-C", repo, *args], capture_output=True,
                           text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def _release_state(project):
    """(main_head, last_deployed, release_ready, unreleased_n) — для
    детерминированного ответа о выкладке без run-контекста."""
    reg = os.path.join(ORCH_ROOT, "config", "projects.json")
    try:
        prof = json.load(open(reg, encoding="utf-8"))[project]
    except Exception:
        _die("проект отсутствует в реестре: %s" % project)
    repo = (prof.get("repo") or "").replace("~", os.path.expanduser("~"))
    branch = prof.get("default_branch") or "main"
    main_head = _git(repo, "rev-parse", branch)
    auths = _load_auths(project)
    deploys = sorted((a for a in auths
                      if a.get("action") == _deploy_action_name(project)
                      and a.get("status") == "executed"),
                     key=lambda a: a.get("executed_at") or "")
    last_deployed = deploys[-1]["sha"] if deploys else ""
    if not main_head:
        return "", last_deployed, False, 0
    if main_head == last_deployed:
        return main_head, last_deployed, True, 0
    rng = "%s..%s" % (last_deployed, main_head) if last_deployed else ""
    unreleased = _git(repo, "rev-list", "--count", branch) if not rng else \
        _git(repo, "rev-list", "--count", rng)
    try:
        unreleased_n = int(unreleased or "0")
    except ValueError:
        unreleased_n = 0
    if last_deployed:
        touched = _git(repo, "log", "-1", "--oneline", rng, "--", "VERSION")
        version = _read(os.path.join(repo, "VERSION")).strip()
        notes = _read(os.path.join(repo, "app", "i18n.py"))
        release_ready = bool(touched) and bool(version) and \
            ('"%s"' % version) in notes
    else:
        release_ready = False
    return main_head, last_deployed, release_ready, unreleased_n


def _emit(intent, text, execute=None):
    print("INTENT=%s" % intent)
    print(text)
    if execute:
        print("===EXECUTE===")
        print(execute)
        print("===END===")
    return 0


def handle(text, project):
    low = text.lower()
    is_accept = bool(ACCEPT_PAT.search(low))
    is_deploy = bool(DEPLOY_PAT.search(low))
    if is_accept and is_deploy:
        return _emit("question",
                     "Похоже, вы решили и принять изменения, и выложить их в "
                     "рабочий бот. Это два отдельных шага: сначала приёмка, "
                     "затем выкладка. Скажите их по очереди.")
    if not (is_accept or is_deploy):
        return _emit("none", "")

    if is_accept:
        awaiting, _ = _run_states(project)
        if not awaiting:
            main_head, last_dep, ready, n = _release_state(project)
            if main_head and main_head != last_dep:
                return _emit(
                    "question",
                    "Ждущих приёмки прогонов нет: изменения TRAINING-PROGRESS-1 "
                    "уже в основной ветке (staging проверен). Для релиза "
                    "нужен релизный коммит (VERSION + заметки) — подготовить?")
            return _emit("question",
                         "Принимать нечего: нет прогонов, ждущих вашей "
                         "приёмки.")
        if len(awaiting) > 1:
            listing = "\n".join("- %s (%s)" % (r, _short(s)) for r, s in awaiting)
            return _emit("question",
                         "Ждущих приёмки прогонов несколько — какой принять?\n"
                         + listing)
        rid, sha = awaiting[0]
        return _emit(
            "accept",
            "Принимаю: изменения прогона %s вливаются в основную ветку "
            "(точный коммит %s)." % (rid, _short(sha)),
            execute="bash %s/bin/owner_action.sh handle orch1:pass:%s" % (ORCH_ROOT, rid))

    # deploy intent
    awaiting, accepted = _run_states(project)
    main_head, last_dep, ready, n = _release_state(project)
    sha_line = ("Код, проверенный на staging: %s; текущая основная ветка: %s; "
                "в рабочем боте: %s."
                % (_short(accepted[0][1]) if accepted else "—",
                   _short(main_head), _short(last_dep)))
    if len(accepted) == 1 and main_head and accepted[0][1] == main_head:
        rid, sha = accepted[0]
        return _emit(
            "deploy",
            "Выкладываю принятую версию %s в рабочий бот.\n%s"
            % (_short(sha), sha_line),
            execute="bash %s/bin/owner_action.sh handle orch1:deploy:%s"
                    % (ORCH_ROOT, rid))
    if main_head and last_dep and main_head != last_dep and not ready:
        return _emit(
            "question",
            "В основной ветке есть невыпущенные изменения (%d коммитов), но "
            "релизного коммита (VERSION + заметки) ещё нет — выкладывать "
            "поэтому пока нечего. Подтвердите — подготовлю релизный коммит "
            "контролируемым релиз-флоу (не автономным прогоном).\n%s"
            % (n, sha_line))
    if main_head and main_head == last_dep:
        return _emit("question",
                     "В рабочем боте уже текущая версия основной ветки (%s) — "
                     "выкладывать нечего." % _short(main_head))
    if accepted:
        return _emit(
            "question",
            "Принятая версия (%s) не совпадает с текущей основной веткой "
            "(%s) — предложение могло устареть. Скажите «статус» — покажу "
            "актуальное состояние." % (_short(accepted[0][1]), _short(main_head)))
    return _emit(
        "question",
        "Выкладывать можно только принятую версию: приёмки ещё не было.\n%s"
        % sha_line)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--project", required=True)
    ap.add_argument("--text", required=True)
    a = ap.parse_args()
    if not re.match(r"^[a-z0-9_-]{1,64}$", a.project or ""):
        _die("project: %r" % a.project)
    if len(a.text) > 4000:
        _die("текст слишком длинный")
    return handle(a.text, a.project)


if __name__ == "__main__":
    sys.exit(main() or 0)
