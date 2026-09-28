#!/usr/bin/env python3
"""owner_auth.py — машинное состояние owner authorizations (OWNER-ACTIONS-1).

Authorization = явное разрешение владельца на ОДНО действие (action) над
ОДНИМ SHA в ОДНОМ проекте. Источник — слова/кнопка владельца (intake/навык);
здесь только детерминированное состояние.

Гарантии:
  - привязка к project + action + sha (40 hex);
  - одноразовость: consume переводит в executed; executed не проходит guard;
  - идемпотентность: повторный create той же тройки возвращает существующую
    (не создаёт дубликат); повторный consume — no-op;
  - OWNER PASS ≠ OWNER GO: production_go требует ОТДЕЛЬНУЮ авторизацию;
    create с --requires-prior-action отказывает, если нет prior-авторизации
    того же SHA в статусе executed;
  - файлы-состояния: $ORCH_AUTH_DIR (по умолчанию $ORCH_ROOT/authorizations),
    атомарная запись (tmp + os.replace).

Команды:
  create  --project P --action A --sha <40hex> [--source-intake ID]
          [--source-note TEXT] [--requires-prior-action A2] [--expected TEXT]
  check   --project P --action A --sha <40hex>   # exit 0 + JSON если валидна
  consume --id ID | --project P --action A --sha S --result TEXT
  list [--project P] [--all]
  show    --id ID
"""
import hashlib
import json
import os
import re
import sys
import time

RE_SHA = re.compile(r"^[0-9a-f]{40}$")
RE_ID = re.compile(r"^[a-z0-9_-]{1,64}$")


def _root():
    r = os.environ.get("ORCH_ROOT") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return r


def _auth_dir():
    return os.environ.get("ORCH_AUTH_DIR") or os.path.join(_root(), "authorizations")


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _die(msg, code=2):
    print(f"owner_auth: REFUSED: {msg}", file=sys.stderr)
    sys.exit(code)


def _load_all():
    d = _auth_dir()
    out = []
    if not os.path.isdir(d):
        return out
    for f in sorted(os.listdir(d)):
        if not (f.startswith("AUTH-") and f.endswith(".json")):
            continue
        try:
            out.append(json.load(open(os.path.join(d, f))))
        except Exception:
            continue
    return out


def _save(a):
    d = _auth_dir()
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, a["id"] + ".json")
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(a, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, p)
    return p


def _find(project, action, sha, statuses):
    for a in _load_all():
        if (a.get("project") == project and a.get("action") == action
                and a.get("sha") == sha and a.get("status") in statuses):
            return a
    return None


def _valid_active(a):
    return bool(a.get("authorized_by_owner")) and a.get("status") == "authorized"


def cmd_create(args):
    project, action, sha = args["project"], args["action"], args["sha"]
    if not RE_ID.match(project or ""):
        _die(f"project: {project!r}")
    if not RE_ID.match(action or ""):
        _die(f"action: {action!r}")
    if not RE_SHA.match(sha or ""):
        _die("sha обязан быть полным 40-hex")
    # идемпотентность: та же тройка уже авторизована -> вернуть существующую
    ext = _find(project, action, sha, {"authorized"})
    if ext:
        print(json.dumps(ext, ensure_ascii=False))
        return 0
    prior = args.get("requires_prior_action")
    if prior:
        p = _find(project, prior, sha, {"executed"})
        if not p:
            _die(f"--requires-prior-action: нет executed-авторизации {prior} для этого SHA")
    note = args.get("source_note") or ""
    a = {
        "id": f"AUTH-{time.strftime('%Y%m%dT%H%M%S')}-{action}-{sha[:7]}",
        "project": project,
        "action": action,
        "sha": sha,
        "authorized_by_owner": True,
        "authorized_at": _now(),
        "source": {
            "kind": args.get("source_kind") or "owner",
            "intake_id": args.get("source_intake") or None,
            "note_sha256": hashlib.sha256(note.encode()).hexdigest() if note else None,
        },
        "expected_state": args.get("expected") or "branch=main, ff-only",
        "requires_prior": {"action": prior, "same_sha": True} if prior else None,
        "status": "authorized",
        "executed_at": None,
        "result": None,
    }
    # защита от коллизий id в одну секунду
    while os.path.exists(os.path.join(_auth_dir(), a["id"] + ".json")):
        a["id"] += "x"
    _save(a)
    print(json.dumps(a, ensure_ascii=False))
    return 0


def cmd_check(args):
    a = _find(args["project"], args["action"], args["sha"], {"authorized"})
    if a and _valid_active(a):
        print(json.dumps(a, ensure_ascii=False))
        return 0
    print("owner_auth: NOT FOUND (нет активной авторизации этой тройки)", file=sys.stderr)
    return 1


def cmd_consume(args):
    if args.get("id"):
        cands = [a for a in _load_all() if a.get("id") == args["id"]]
    else:
        cands = [_find(args["project"], args["action"], args["sha"],
                       {"authorized", "executed"})] or []
    cands = [c for c in cands if c]
    if not cands:
        _die("авторизация не найдена")
    a = cands[0]
    if a.get("status") == "executed":  # идемпотентный consume
        print(json.dumps(a, ensure_ascii=False))
        return 0
    a["status"] = "executed"
    a["executed_at"] = _now()
    a["result"] = (args.get("result") or "executed")[:300]
    _save(a)
    print(json.dumps(a, ensure_ascii=False))
    return 0


def cmd_list(args):
    for a in _load_all():
        if args.get("project") and a.get("project") != args["project"]:
            continue
        if a.get("status") != "authorized" and not args.get("all"):
            continue
        print(json.dumps({k: a.get(k) for k in
                          ("id", "project", "action", "sha", "status",
                           "authorized_at", "executed_at")}, ensure_ascii=False))
    return 0


def cmd_show(args):
    for a in _load_all():
        if a.get("id") == args["id"]:
            print(json.dumps(a, ensure_ascii=False, indent=1))
            return 0
    _die("id не найден")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    args, i = {}, 2
    while i < len(sys.argv):
        k = sys.argv[i]
        if not k.startswith("--"):
            _die(f"неожиданный аргумент: {k}")
        if k == "--all":  # булев флаг (без значения)
            args["all"] = "true"
            i += 1
            continue
        if i + 1 >= len(sys.argv):
            _die(f"{k} требует значение")
        args[k[2:].replace("-", "_")] = sys.argv[i + 1]
        i += 2
    return {"create": cmd_create, "check": cmd_check, "consume": cmd_consume,
            "list": cmd_list, "show": cmd_show}.get(cmd, lambda _a: _die(f"unknown: {cmd}"))(args)


if __name__ == "__main__":
    sys.exit(main() or 0)
