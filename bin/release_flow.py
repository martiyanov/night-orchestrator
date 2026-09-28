#!/usr/bin/env python3
"""release_flow.py — детерминированный lifecycle выпуска (PROACTIVE-UX-RELEASE-FLOW-2).

Первоклассные состояния (вычисляются ТОЛЬКО из structured state:
authorizations/git/registry — никогда из текста):

  A DEVELOPMENT            код ещё делается (run-уровень: awaiting owner)
  B STAGING_READY          тестовая версия готова (run READY_FOR_OWNER_PASS)
  C CODE_ACCEPTED          владелец принял staging-код (owner_accept executed)
  D RELEASE_NEEDED         принятый код в main, но VERSION/RELEASE_NOTES нет
  E RELEASE_CANDIDATE_READY есть точный release SHA (release-коммит после accept)
  F RELEASE_ACCEPTED       владелец подтвердил exact release SHA
  G PRODUCTION_READY       можно выполнить production_go exact SHA (main==RC)
  H PRODUCTION_DONE        рабочий бот обновлён (production_go executed RC)

SHA-модель (никогда не подменяются друг другом):
  accepted_code_sha / main_sha / release_candidate_sha / production_sha.

Действия (owner-side, детерминированные; guard НЕ участвует и НЕ меняется):
  state    — состояние + квартет SHA + допустимые шаги (человек + JSON)
  prepare  — PREPARE_RELEASE: один release-коммит (VERSION+NOTES draft),
             канонический гейт, точный RC SHA; только из D; идемпотентно;
             app-код не трогает; stale-safe; production не трогает
  accept   — приёмка exact release SHA (release_accept authorization)
  deploy   — production_go exact RC (требует F и main==RC)
  handle   — dispatcher orch1:release-* callbacks (stale/already-safe)

Права: prepare не требует отдельной owner_auth, потому что не является
повышением риска (правит только release-файлы, не деплоит, обратим одним
коммитом) и запускается ТОЛЬКО явной командой владельца/кнопкой через
этот детерминированный примитив — не executor'ом. Deploy по-прежнему
требует точной авторизации exact RC (release_accept) + prior + SHA-гейт.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

ORCH_ROOT = os.environ.get("ORCH_ROOT") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AUTH_DIR = os.environ.get("ORCH_AUTH_DIR") or os.path.join(ORCH_ROOT, "authorizations")
REG = os.path.join(ORCH_ROOT, "config", "projects.json")
RELEASE_LOG = os.path.join(ORCH_ROOT, "release_log.jsonl")

RE_CB = re.compile(
    r"^orch1:release-(prepare|accept|deploy|defer|details|status):(now|[0-9a-f]{7}|x)$")


def _die(msg):
    print("release_flow: REFUSED: %s" % msg, file=sys.stderr)
    sys.exit(2)


def _now():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def _audit(event, data):
    try:
        with open(RELEASE_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": _now(), "event": event, "data": data},
                               ensure_ascii=False) + "\n")
    except OSError:
        pass


def _git(repo, *args, check=False):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True,
                       text=True, timeout=60)
    if check and r.returncode != 0:
        _die("git %s: %s" % (" ".join(args[:2]), (r.stderr or "").strip()[:200]))
    return r.stdout.strip() if r.returncode == 0 else ""


def _profile(project):
    try:
        return json.load(open(REG, encoding="utf-8"))[project]
    except Exception:
        _die("проект отсутствует в реестре: %s" % project)


def _release_cfg(prof):
    cfg = prof.get("release")
    return cfg if isinstance(cfg, dict) else None


def _auths(project):
    out = []
    if not os.path.isdir(AUTH_DIR):
        return out
    for f in sorted(os.listdir(AUTH_DIR)):
        if f.startswith("AUTH-") and f.endswith(".json"):
            try:
                a = json.load(open(os.path.join(AUTH_DIR, f), encoding="utf-8"))
            except Exception:
                continue
            if a.get("project") == project:
                out.append(a)
    return out


def _role_action(prof, role):
    for name, spec in (prof.get("project_actions") or {}).items():
        if isinstance(spec, dict) and spec.get("ux_role") == role:
            return name
    return None


def _last_executed_sha(auths, action):
    xs = sorted((a for a in auths if a.get("action") == action
                 and a.get("status") == "executed"),
                key=lambda a: a.get("executed_at") or "")
    return xs[-1]["sha"] if xs else None


def _bump(version, step):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", version)
    if not m:
        _die("не semver VERSION: %r" % version)
    a, b, c = map(int, m.groups())
    return "%d.%d.0" % (a, b + 1) if step == "minor" else "%d.%d.%d" % (a, b, c + 1)


class Flow:
    def __init__(self, project):
        self.project = project
        self.prof = _profile(project)
        self.repo = (self.prof.get("repo") or "").replace("~", os.path.expanduser("~"))
        self.branch = self.prof.get("default_branch") or "main"
        self.cfg = _release_cfg(self.prof)
        self.auths = _auths(project)
        self.accept_action = _role_action(self.prof, "accept") or "owner_accept"
        self.deploy_action = _role_action(self.prof, "production") or "production_go"
        self.production_sha = _last_executed_sha(self.auths, self.deploy_action)
        self.accepted_code_sha = _last_executed_sha(self.auths, self.accept_action)
        self.main_sha = _git(self.repo, "rev-parse", self.branch) if self.repo else ""

    def _descendant(self, a, b):
        r = subprocess.run(["git", "-C", self.repo, "merge-base",
                            "--is-ancestor", a, b], capture_output=True)
        return r.returncode == 0

    def _rc_commit(self):
        """Последний коммит после production_sha, тронувший первый version_file."""
        if not (self.cfg and self.repo):
            return ""
        vf = (self.cfg.get("version_files") or ["VERSION"])[0]
        rng = "%s..%s" % (self.production_sha, self.branch) if self.production_sha else self.branch
        return _git(self.repo, "log", "-1", "--format=%H", rng, "--", vf)

    def resolve(self):
        """-> dict состояния (буква/имя/SHA-квартет/допустимые шаги)."""
        self.auths = _auths(self.project)  # свежие факты (внутри одного процесса)
        self.production_sha = _last_executed_sha(self.auths, self.deploy_action)
        self.accepted_code_sha = _last_executed_sha(self.auths, self.accept_action)
        self.main_sha = _git(self.repo, "rev-parse", self.branch) if self.repo else ""
        rc = self._rc_commit()
        rc_valid = bool(rc and self.accepted_code_sha
                        and self._descendant(self.accepted_code_sha, rc))
        rel_accepted = any(a.get("action") == "release_accept"
                           and a.get("status") == "executed"
                           and a.get("sha") == rc for a in self.auths) if rc_valid else False
        # H: всё ПРИНЯТОЕ уже содержится в проде (новый принятый код → D/E/F)
        all_released = bool(self.accepted_code_sha and self.production_sha
                            and self._descendant(self.accepted_code_sha,
                                                 self.production_sha))
        if all_released:
            state, name = "H", "PRODUCTION_DONE"
        elif rel_accepted and self.main_sha == rc:
            state, name = "G", "PRODUCTION_READY"
        elif rel_accepted:
            state, name = "F", "RELEASE_ACCEPTED"
        elif rc_valid:
            state, name = "E", "RELEASE_CANDIDATE_READY"
        elif self.accepted_code_sha:
            state, name = "D", "RELEASE_NEEDED"
        else:
            state, name = "A", "DEVELOPMENT"
        allowed = {"D": ["prepare"], "E": ["accept_release"], "F": ["deploy"],
                   "G": ["deploy"], "H": []}.get(state, [])
        if state == "F":
            allowed = ["deploy_after_sync"]  # main ушёл вперёд RC
        return {
            "state": state, "state_name": name,
            "accepted_code_sha": self.accepted_code_sha,
            "main_sha": self.main_sha,
            "release_candidate_sha": rc if rc_valid else None,
            "production_sha": self.production_sha,
            "allowed": allowed,
        }

    # ------------------------------------------------------------- prepare --
    def prepare(self, step=None, notes_ru=None, notes_en=None, task_id=None):
        st = self.resolve()
        if st["state"] == "H":
            return self._offer_done(st)
        if st["state"] in ("E", "F"):
            return self._offer_candidate(st, already=True)
        if st["state"] != "D":
            return self._refuse_state(st)
        # stale: после принятого кода в main только разрешённая мета-дрейф
        drift = [f for f in _git(self.repo, "diff", "--name-only",
                                 self.accepted_code_sha, self.branch).splitlines() if f]
        allow = self.cfg.get("drift_allow") or []
        bad = [f for f in drift if not any(f.startswith(p) or f == p.rstrip("/")
                                           for p in allow)]
        if bad:
            return self._print_human(
                "❌ Основная ветка изменилась после принятого кода (например: %s). "
                "Сначала повторная приёмка — подготовка выпуска остановлена." % ", ".join(bad[:3]),
                st)
        if _git(self.repo, "status", "--porcelain"):
            return self._print_human(
                "❌ Рабочее дерево основной ветки не чистое — остановился.", st)
        cur_branch = _git(self.repo, "rev-parse", "--abbrev-ref", "HEAD")
        if cur_branch != self.branch:
            return self._print_human(
                "❌ Основной чекаут не на ветке %s (сейчас %s) — остановился."
                % (self.branch, cur_branch or "?"), st)
        version = open(os.path.join(self.repo, (self.cfg.get("version_files")
                                                or ["VERSION"])[0]),
                       encoding="utf-8").read().strip()
        new_ver = _bump(version, step or self.cfg.get("default_step") or "minor")
        notes = self._draft_notes(new_ver, notes_ru, notes_en, task_id)
        self._write_version(new_ver)
        self._insert_notes(new_ver, notes)
        gate = self.cfg.get("gate_command") or self.prof.get("test_command")
        if gate:
            rc_proc = subprocess.run(gate, shell=True, cwd=self.repo,
                                     capture_output=True, text=True, timeout=3600)
            if rc_proc.returncode != 0:
                _git(self.repo, "checkout", "--",
                     *(self.cfg.get("version_files") or ["VERSION"]),
                     self.cfg.get("notes_file", "NOTES.py"))
                _audit("RELEASE_GATE_FAILED", {"project": self.project,
                                               "version": new_ver})
                return self._print_human(
                    "❌ Канонические проверки не прошли — release-коммит не создан, "
                    "файлы восстановлены.", st)
        _git(self.repo, "add", *((self.cfg.get("version_files") or ["VERSION"])
                                 + [self.cfg.get("notes_file", "NOTES.py")] ))
        subj = task_id or new_ver
        _git(self.repo, "commit", "-q", "-m", "release: %s — %s" % (new_ver, subj),
             check=True)
        remote = self.cfg.get("push_remote", "origin")
        if remote:
            _git(self.repo, "push", remote, self.branch, check=True)
        rc_sha = _git(self.repo, "rev-parse", "HEAD")
        _audit("RELEASE_PREPARED", {"project": self.project, "version": new_ver,
                                    "rc_sha": rc_sha})
        return self._offer_candidate(self.resolve(), version=new_ver)

    def _draft_notes(self, ver, notes_ru, notes_en, task_id):
        if notes_ru and notes_en:
            return notes_ru, notes_en
        title = ""
        if task_id:
            todo = os.path.join(self.repo, "state", "TODO.md")
            if os.path.isfile(todo):
                m = re.search(r"^###\s+%s\b.*?$.*?-\s*\*\*Title:\*\*\s*(.+)$"
                              % re.escape(task_id), open(todo, encoding="utf-8").read(), re.M | re.S)
                if m:
                    title = m.group(1).strip()
        ru = notes_ru or ("<b>%s</b>: %s (черновик — отредактируйте до приёмки)."
                          % (ver, title or "новая версия"))
        en = notes_en or ("<b>%s</b>: %s (draft — edit before acceptance)."
                          % (ver, title or "new version"))
        return ru, en

    def _write_version(self, new_ver):
        p = os.path.join(self.repo, (self.cfg.get("version_files") or ["VERSION"])[0])
        open(p, "w", encoding="utf-8").write(new_ver + "\n")

    def _insert_notes(self, ver, notes):
        ru, en = notes
        p = os.path.join(self.repo, self.cfg.get("notes_file", "NOTES.py"))
        lines = open(p, encoding="utf-8").read().split("\n")
        anchor = self.cfg.get("notes_anchor", "RELEASE_NOTES")
        entry = ('    "%s": {"ru": (%s,), "en": (%s,)},'
                 % (ver, json.dumps(ru, ensure_ascii=False),
                    json.dumps(en, ensure_ascii=False)))
        for i, l in enumerate(lines):
            if anchor in l:
                lines.insert(i + 1, entry)
                open(p, "w", encoding="utf-8").write("\n".join(lines))
                return
        _die("якорь заметок не найден в %s" % p)

    # -------------------------------------------------------------- accept --
    def accept(self, sha7):
        st = self.resolve()
        rc = st["release_candidate_sha"]
        if not rc:
            return self._refuse_state(st)
        full = self._resolve_full(sha7 or rc[:7])
        if full != rc:
            return self._print_human(
                "Это предложение уже устарело: выпуск сменился. Текущий "
                "кандидат — %s." % rc[:7], st)
        if any(a.get("action") == "release_accept" and a.get("sha") == rc
               and a.get("status") == "executed" for a in _auths(self.project)):
            return self._offer_accepted(self.resolve(), already=True)
        subprocess.run(["python3", os.path.join(ORCH_ROOT, "bin", "owner_auth.py"),
                        "create", "--project", self.project, "--action", "release_accept",
                        "--sha", rc, "--source-note", "release flow"],
                       capture_output=True, text=True, timeout=15, check=True)
        subprocess.run(["python3", os.path.join(ORCH_ROOT, "bin", "owner_auth.py"),
                        "consume", "--project", self.project, "--action",
                        "release_accept", "--sha", rc, "--result", "accepted"],
                       capture_output=True, text=True, timeout=15, check=True)
        _audit("RELEASE_ACCEPTED", {"project": self.project, "rc_sha": rc})
        return self._offer_accepted(self.resolve())

    def _resolve_full(self, sha7):
        return _git(self.repo, "rev-parse", sha7)

    # -------------------------------------------------------------- deploy --
    def deploy(self, sha7=None):
        st = self.resolve()
        rc = st["release_candidate_sha"]
        if not rc:
            return self._refuse_state(st)
        if sha7 and self._resolve_full(sha7) != rc:
            return self._print_human(
                "Это предложение уже устарело: состояние задачи изменилось. "
                "Текущий кандидат — %s." % rc[:7], st)
        if any(a.get("action") == self.deploy_action and a.get("sha") == rc
               and a.get("status") == "executed" for a in _auths(self.project)):
            return self._offer_done(st)
        if not any(a.get("action") == "release_accept" and a.get("sha") == rc
                   and a.get("status") == "executed" for a in _auths(self.project)):
            return self._offer_candidate(st)
        if self.main_sha != rc:
            return self._print_human(
                "Основная ветка ушла вперёд принятого выпуска (%s → %s): "
                "сначала sync/повторная подготовка. Покажу статус по запросу."
                % (rc[:7], self.main_sha[:7]), st)
        spec = (self.prof.get("project_actions") or {}).get(self.deploy_action)
        if not spec:
            return self._print_human("❌ Для проекта не настроена выкладка.", st)
        argv = spec.get("argv") or []
        sha_env = (spec.get("owner_auth") or {}).get("sha_env") or \
            (spec.get("env_from_model") or [{}])[0].get("name") or "DEPLOY_SHA"
        env = dict(os.environ)
        for k, v in (spec.get("env_fixed") or {}).items():
            env[k] = v.replace("~", os.path.expanduser("~"))
        env[sha_env] = rc
        log = os.path.join(ORCH_ROOT, "release_deploy.log")
        with open(log, "a", encoding="utf-8") as lf:
            lf.write("== %s deploy %s\n" % (_now(), rc))
            r = subprocess.run(argv, cwd=self.repo, env=env, stdout=lf,
                               stderr=subprocess.STDOUT, timeout=1800)
        if r.returncode != 0:
            _audit("RELEASE_DEPLOY_FAILED", {"project": self.project, "rc": rc,
                                             "rc_code": r.returncode})
            return self._print_human(
                "🔴 Не получилось выполнить выкладку (лог: release_deploy.log). "
                "Разрешение не израсходовано — можно повторить.", st)
        subprocess.run(["python3", os.path.join(ORCH_ROOT, "bin", "owner_auth.py"),
                        "create", "--project", self.project,
                        "--action", self.deploy_action, "--sha", rc,
                        "--requires-prior-action", "release_accept",
                        "--source-note", "release flow"],
                       capture_output=True, text=True, timeout=15, check=True)
        subprocess.run(["python3", os.path.join(ORCH_ROOT, "bin", "owner_auth.py"),
                        "consume", "--project", self.project,
                        "--action", self.deploy_action, "--sha", rc,
                        "--result", "deployed rc=%s" % rc],
                       capture_output=True, text=True, timeout=15, check=True)
        _audit("RELEASE_DEPLOYED", {"project": self.project, "rc_sha": rc})
        ver = open(os.path.join(self.repo, (self.cfg.get("version_files")
                                            or ["VERSION"])[0]),
                   encoding="utf-8").read().strip() if self.cfg else ""
        return self._offer_done(self.resolve(), version=ver)

    # --------------------------------------------------------------- offers --
    def _print_human(self, text, st):
        print(text)
        self._machine(st)
        return 0

    def _machine(self, st):
        print("===LIFECYCLE===")
        print(json.dumps(st, ensure_ascii=False))
        print("===END===")

    def _refuse_state(self, st):
        names = {"A": "разработка ещё идёт", "B": "тестовая версия не принята",
                 "C": "код принят", "D": "нужно подготовить выпуск",
                 "E": "выпуск подготовлен", "F": "выпуск принят",
                 "G": "готов к выкладке", "H": "уже в рабочем боте"}
        return self._print_human(
            "Это сейчас недоступно: текущее состояние — %s." % names.get(st["state"], "?"), st)

    def _offer_candidate(self, st, already=False, version=None):
        rc = st["release_candidate_sha"]
        ver = version or self._version_at(rc)
        head = ("Выпуск %s уже подготовлен." % ver) if already else \
               ("Выпуск %s подготовлен." % ver)
        print(head)
        print("Проверки прошли.")
        print("Коммит: %s" % rc[:7])
        print()
        print("Принять этот выпуск?")
        self._offer({
            "text": "%s\nПроверки прошли.\nКоммит: %s\n\nПринять этот выпуск?"
                    % (head, rc[:7]),
            "buttons": [
                {"label": "✅ Принять выпуск", "action": {"type": "callback",
                 "value": "orch1:release-accept:%s" % rc[:7]}},
                {"label": "🔧 Вернуть на доработку", "action": {"type": "callback",
                 "value": "orch1:release-defer:x"}},
                {"label": "📋 Подробнее", "action": {"type": "callback",
                 "value": "orch1:release-details:x"}}]})
        self._machine(st)
        return 0

    def _offer_accepted(self, st, already=False):
        rc = st["release_candidate_sha"]
        print("Выпуск %s принят.%s" % (self._version_at(rc),
                                       " (ранее)" if already else ""))
        print()
        print("Выложить его в рабочий бот?")
        self._offer({
            "text": "Выпуск %s принят.\n\nВыложить его в рабочий бот?"
                    % self._version_at(rc),
            "buttons": [
                {"label": "🚀 Выложить в рабочий бот", "action": {"type": "callback",
                 "value": "orch1:release-deploy:%s" % rc[:7]}},
                {"label": "⏸ Позже", "action": {"type": "callback",
                 "value": "orch1:release-defer:x"}},
                {"label": "📋 Подробнее", "action": {"type": "callback",
                 "value": "orch1:release-details:x"}}]})
        self._machine(st)
        return 0

    def _offer_done(self, st, version=None):
        rc = st["release_candidate_sha"] or st["production_sha"]
        ver = version or self._version_at(rc)
        print("✅ Готово. Версия %s работает в рабочем боте." % ver)
        self._machine(st)
        return 0

    def _version_at(self, sha):
        if not (sha and self.repo):
            return "?"
        out = _git(self.repo, "show", "%s:%s" % (sha[:7],
                     (self.cfg.get("version_files") or ["VERSION"])[0]))
        return out.strip() or "?"

    @staticmethod
    def _offer(block):
        print("===NEXT_OFFER===")
        print(json.dumps(block, ensure_ascii=False))
        print("===END_OFFER===")

    # ---------------------------------------------------------------- state --
    def print_state(self, as_json=False):
        st = self.resolve()
        if as_json:
            print(json.dumps(st, ensure_ascii=False, indent=1))
            return 0
        names = {"A": "разработка", "B": "тестовая версия готова",
                 "C": "код принят", "D": "нужна подготовка выпуска",
                 "E": "выпуск подготовлен", "F": "выпуск принят",
                 "G": "готов к выкладке", "H": "в рабочем боте"}
        print("Состояние выпуска: %s." % names.get(st["state"], st["state"]))
        print("Код, принятый на staging: %s" % (st["accepted_code_sha"][:7] if st["accepted_code_sha"] else "—"))
        print("Текущая основная ветка: %s" % (st["main_sha"][:7] if st["main_sha"] else "—"))
        print("Кандидат на выпуск: %s" % (st["release_candidate_sha"][:7] if st["release_candidate_sha"] else "—"))
        print("В рабочем боте: %s" % (st["production_sha"][:7] if st["production_sha"] else "—"))
        self._machine(st)
        return 0

    # --------------------------------------------------------------- handle --
    def handle(self, cb):
        if not RE_CB.match(cb):
            _die("недопустимый callback: %s" % cb)
        act, token = cb.split(":")[1], cb.split(":")[2]
        act = act[len("release-"):]
        if act == "prepare":
            return self.prepare()
        if act == "accept":
            return self.accept(token)
        if act == "deploy":
            return self.deploy(token)
        if act == "defer":
            st = self.resolve()
            print("Хорошо — отложили. Вернуться можно фразой «готовь релиз» "
                  "или «выложи в рабочий бот».")
            self._machine(st)
            return 0
        # details / status
        return self.print_state()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cmd", choices=["state", "prepare", "accept", "deploy", "handle"])
    ap.add_argument("--project", required=True)
    ap.add_argument("--sha")
    ap.add_argument("--step", choices=["minor", "patch"])
    ap.add_argument("--notes-ru"), ap.add_argument("--notes-en")
    ap.add_argument("--task-id")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if not re.match(r"^[a-z0-9_-]{1,64}$", a.project or ""):
        _die("project: %r" % a.project)
    flow = Flow(a.project)
    if a.cmd == "state":
        return flow.print_state(as_json=a.json)
    if a.cmd == "prepare":
        return flow.prepare(step=a.step, notes_ru=a.notes_ru,
                            notes_en=a.notes_en, task_id=a.task_id)
    if a.cmd == "accept":
        return flow.accept(a.sha)
    if a.cmd == "deploy":
        return flow.deploy(a.sha)
    if a.cmd == "handle":
        if not a.sha:
            _die("укажите callback как --sha '<orch1:release-…>'")
        return flow.handle(a.sha)
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
