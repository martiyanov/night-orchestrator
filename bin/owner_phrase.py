#!/usr/bin/env python3
"""owner_phrase.py — детерминированный маршрутизатор owner-фраз (v2, PROACTIVE-UX-RELEASE-FLOW-2).

Приоритет обработки сообщения (см. SKILL): 1) callback orch1:*; 2) lifecycle
owner intent (ЗДЕСЬ); 3) ожидающие уточнения intake; 4) обычный intake.

Intent-набор (явные формулировки; решения — из lifecycle state
(release_flow/owner_action), не из текста):
  accept_release — «принимаю релиз», «релиз проверен», «этот релиз принимаю»
  accept         — «принимаю изменения», «всё проверил, принимаю»,
                   «влей проверенную версию»
  prepare        — «готовь релиз», «подготовь релиз/выпуск», «можно готовить
                   релиз», «сделай релизный коммит»
  deploy         — «выложи в рабочий бот», «разрешаю выложить»,
                   «выкатывай в production», «выпускай»
  none           — обычная задача («запусти X», «разработай …») → intake

Выход: INTENT=…(+человеческий текст)+блок ===EXECUTE=== с ТОЧНОЙ командой
(исполнять дословно) либо вопрос. Модуль state-only: side effects только
внутри EXECUTE-команд (release_flow/owner_action — детерминированные,
идемпотентные, stale-safe). Внутренние имена действий не показываются.
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

ACCEPT_RELEASE_PAT = re.compile(
    r"(принима(ю|ем|ешь)|принять|принят\w*|подтвержда\w*|проверен\w*|проверил\w*"
    r"|проверила\w*)[^\n]{0,40}(релиз\w*|выпуск\w*|release)"
    r"|(релиз\w*|выпуск\w*|release)[^\n]{0,40}(принимаю|принят|проверен)", re.I)
ACCEPT_PAT = re.compile(
    r"(принима(ю|ем|ешь)|принять|принят\w*)\s+(изменени\w*|версию\w*|результат\w*)"
    r"|всё\s+проверил\w*[,.]?\s*принимаю"
    r"|влей(те)?\s+\S|влива(й|йте)|слей(те)?\s+\S"
    r"|owner\s*pass", re.I)
PREPARE_PAT = re.compile(
    r"(подготовь\w*|готовь\w*|готовим|подготовк\w*|готовить\w*)[^\n]{0,40}"
    r"(релиз\w*|выпуск\w*|release)"
    r"|можно\s+готовить\s+релиз|сделай\s+релизный\s+коммит|release\s*prep", re.I)
DEPLOY_PAT = re.compile(
    r"(выложи\w*|выкладывай|разреша\w*\s+выложить|можно\s+выкладывать"
    r"|выпусти\w*|выпускай\w*|выкатывай\w*|публикуй\w*|задеплой\w*|деплой\w*)"
    r"[^\n]{0,120}(рабоч\w+\s+бот|в\s+прод\w*|production)"
    r"|owner\s*go|выложить[^\n]{0,120}рабоч\w+\s+бот"
    r"|^\s*(выпускай|выкатывай|деплой|задеплой|разрешаю\s+выложить|можно\s+выкладывать)[!.]?\s*$", re.I)


def _die(msg):
    print("owner_phrase: REFUSED: %s" % msg, file=sys.stderr)
    sys.exit(2)


def _emit(intent, text, execute=None):
    print("INTENT=%s" % intent)
    if text:
        print(text)
    if execute:
        print("===EXECUTE===")
        print(execute)
        print("===END===")
    return 0


def _rel_state(project):
    """JSON lifecycle-состояние из release_flow.py (state-only)."""
    r = subprocess.run(
        [sys.executable, os.path.join(ORCH_ROOT, "bin", "release_flow.py"),
         "state", "--project", project, "--json"],
        capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def _awaiting_runs(project):
    """Прогоны в состоянии «ждёт приёмки кода» (owner_action-семантика)."""
    out = []
    if not os.path.isdir(RUNS_DIR):
        return out
    import glob
    for rdir in sorted(glob.glob(os.path.join(RUNS_DIR, "*"))):
        if not os.path.isdir(rdir):
            continue
        res = None
        for rp in sorted(glob.glob(os.path.join(rdir, "*", "RESULT.json"))):
            res = rp
            break
        if not res:
            continue
        try:
            r = json.load(open(res, encoding="utf-8"))
        except Exception:
            continue
        sha = r.get("commit_sha") or ""
        proj = None
        for tf in sorted(glob.glob(os.path.join(rdir, "tasks", "*.json"))) + \
                sorted(glob.glob(os.path.join(rdir, "*", "tasks", "*.json"))):
            try:
                proj = json.load(open(tf, encoding="utf-8")).get("project")
            except Exception:
                pass
            if proj:
                break
        if proj != project or len(sha) != 40:
            continue
        if os.path.isfile(os.path.join(rdir, ".owner_decision.json")):
            continue
        if r.get("status") in ("READY_FOR_OWNER_PASS", "PASS"):
            out.append((os.path.basename(rdir), sha))
    return out


def _accept_sha_executed(project):
    st = _rel_state(project) or {}
    return st.get("accepted_code_sha")


def handle(text, project):
    low = text.lower()
    hits = [p for p, pat in (("accept_release", ACCEPT_RELEASE_PAT),
                             ("accept", ACCEPT_PAT),
                             ("prepare", PREPARE_PAT),
                             ("deploy", DEPLOY_PAT)) if pat.search(low)]
    if not hits:
        return _emit("none", "")
    if len(hits) > 1:
        return _emit("question",
                     "Похоже, здесь несколько решений сразу. Скажите их по "
                     "одному: сначала приёмка, затем подготовка выпуска, "
                     "затем выкладка.")
    intent = hits[0]
    rel = _rel_state(project) or {}
    state = rel.get("state")

    if intent == "accept_release":
        rc = rel.get("release_candidate_sha")
        if state == "E" and rc:
            return _emit(
                "accept_release",
                "Принимаю выпуск (коммит %s)." % rc[:7],
                execute="%s %s/bin/release_flow.py accept --project %s --sha %s"
                        % (sys.executable, ORCH_ROOT, project, rc[:7]))
        if state in ("F", "G", "H"):
            return _emit("accept_release",
                         "Выпуск уже принят (коммит %s). Скажите «выложи в "
                         "рабочий бот», чтобы обновить рабочего бота."
                         % ((rel.get("release_candidate_sha") or "")[:7]))
        if state == "D":
            return _emit("question",
                         "Выпуск ещё не подготовлен. Сказать «готовь релиз»?")
        return _emit("question", "Принимать выпуск нечего: выпуска нет.")

    if intent == "accept":
        awaiting = _awaiting_runs(project)
        if awaiting:
            if len(awaiting) > 1:
                listing = "\n".join("- %s (%s)" % (r, s[:7]) for r, s in awaiting)
                return _emit("question",
                             "Ждущих приёмки прогонов несколько — какой "
                             "принять?\n" + listing)
            rid, sha = awaiting[0]
            return _emit(
                "accept",
                "Принимаю: изменения прогона %s вливаются в основную ветку "
                "(точный коммит %s)." % (rid, sha[:7]),
                execute="bash %s/bin/owner_action.sh handle orch1:pass:%s"
                        % (ORCH_ROOT, rid))
        if state == "H" and rel.get("main_sha") and rel.get("production_sha") \
                and rel["main_sha"] != rel["production_sha"]:
            # main-поток: код в основной ветке, проверен на staging, но приёмка
            # формально не зафиксирована — детерминированная фиксация
            return _emit(
                "accept",
                "Фиксирую приёмку кода основной ветки (коммит %s) — он уже "
                "проверен вами на staging." % rel["main_sha"][:7],
                execute="%s %s/bin/release_flow.py accept-main --project %s"
                        % (sys.executable, ORCH_ROOT, project))
        if state == "D":
            return _emit("question",
                         "Прогонов в приёмке нет: принятый код уже в основной "
                         "ветке. Дальше — подготовка выпуска («готовь релиз»).")
        if state in ("E", "F", "G", "H"):
            return _emit("question",
                         "Принимать код уже нечего — он в основной ветке. "
                         "Текущий шаг выпуска подскажет «статус выпуска».")
        return _emit("question", "Принимать нечего: нет прогонов, ждущих "
                                 "вашей приёмки.")

    if intent == "prepare":
        awaiting = _awaiting_runs(project)
        if awaiting:
            return _emit("question",
                         "Сначала приёмка: есть прогон(ы), ждущие вашего "
                         "решения по коду. Подготовка выпуска — после неё.")
        if state == "D":
            return _emit(
                "prepare",
                "Готовлю выпуск из принятого кода (%s): один релизный коммит "
                "(версия + черновик заметок), канонические проверки, точный "
                "SHA выпуска. Рабочий бот не трогаю."
                % (rel.get("accepted_code_sha") or "")[:7],
                execute="%s %s/bin/release_flow.py prepare --project %s"
                        % (sys.executable, ORCH_ROOT, project))
        if state in ("E", "F", "G"):
            rc = rel.get("release_candidate_sha") or ""
            nxt = "Принять выпуск?" if state == "E" else \
                "Выпуск принят — «выложи в рабочий бот»."
            return _emit("prepare",
                         "Выпуск уже подготовлен (коммит %s). %s"
                         % (rc[:7], nxt))
        if state == "H":
            return _emit("prepare",
                         "Всё выпущено и работает в рабочем боте — готовить "
                         "нечего.")
        return _emit("question",
                     "Готовить выпуск нечего: нет принятого кода после "
                     "последнего выпуска.")

    # deploy
    rc = rel.get("release_candidate_sha")
    if state == "G" and rc:
        return _emit(
            "deploy",
            "Выкладываю принятый выпуск (коммит %s) в рабочий бот."
            % rc[:7],
            execute="%s %s/bin/release_flow.py deploy --project %s --sha %s"
                    % (sys.executable, ORCH_ROOT, project, rc[:7]))
    if state == "F":
        return _emit("question",
                     "Выпуск принят, но основная ветка ушла вперёд — "
                     "выкладывать нельзя. Скажите «статус выпуска».")
    if state == "E":
        return _emit("question",
                     "Выпуск подготовлен (коммит %s), но ещё не принят. "
                     "Сначала «принимаю релиз»." % (rc or "")[:7])
    if state == "D":
        return _emit("question",
                     "Сначала подготовить выпуск («готовь релиз»), принять "
                     "его — затем выкладка.")
    if state == "H":
        return _emit("deploy",
                     "В рабочем боте уже текущий выпуск — выкладывать нечего.")
    # проект без release-конфигурации: старый run-путь owner_action
    awaiting, accepted = _legacy_accepted(project)
    if len(accepted) == 1:
        rid, sha = accepted[0]
        main_sha = rel.get("main_sha")
        if main_sha and sha == main_sha:
            return _emit(
                "deploy",
                "Выкладываю принятую версию %s в рабочий бот." % sha[:7],
                execute="bash %s/bin/owner_action.sh handle orch1:deploy:%s"
                        % (ORCH_ROOT, rid))
    if awaiting:
        return _emit("question", "Сначала приёмка кода — выкладывать можно "
                                 "только принятую версию.")
    return _emit("question", "Выкладывать можно только принятую версию: "
                             "приёмки ещё не было.")


def _legacy_accepted(project):
    """run-поток для проектов без release-конфига (семантика owner_action)."""
    awaiting = _awaiting_runs(project)
    accepted = []
    if not os.path.isdir(AUTH_DIR):
        return awaiting, accepted
    reg = os.path.join(ORCH_ROOT, "config", "projects.json")
    try:
        prof = json.load(open(reg, encoding="utf-8"))[project]
    except Exception:
        return awaiting, accepted
    acc_name = next((n for n, s in (prof.get("project_actions") or {}).items()
                     if isinstance(s, dict) and s.get("ux_role") == "accept"),
                    "owner_accept")
    dep_name = next((n for n, s in (prof.get("project_actions") or {}).items()
                     if isinstance(s, dict) and s.get("ux_role") == "production"),
                    "production_go")
    acc_sha = {a["sha"] for a in map(_load, _auth_files()) if a and
               a.get("project") == project and a.get("action") == acc_name and
               a.get("status") == "executed"}
    dep_sha = {a["sha"] for a in map(_load, _auth_files()) if a and
               a.get("project") == project and a.get("action") == dep_name and
               a.get("status") == "executed"}
    import glob
    for rdir in sorted(glob.glob(os.path.join(RUNS_DIR, "*"))):
        res = next(iter(sorted(glob.glob(os.path.join(rdir, "*", "RESULT.json")))), None)
        if not res:
            continue
        try:
            r = json.load(open(res, encoding="utf-8"))
        except Exception:
            continue
        sha = r.get("commit_sha") or ""
        if len(sha) == 40 and sha in acc_sha and sha not in dep_sha:
            accepted.append((os.path.basename(rdir), sha))
    return awaiting, accepted


def _auth_files():
    import glob
    return sorted(glob.glob(os.path.join(AUTH_DIR, "AUTH-*.json"))) \
        if os.path.isdir(AUTH_DIR) else []


def _load(p):
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:
        return None


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
