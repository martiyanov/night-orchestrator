#!/usr/bin/env python3
"""Маршрутизатор навыка NightArena: детерминированно решить, относится ли
сообщение к проекту, и подсказать команду Intake. Проектный id — параметр
(--project, по умолчанию example-project из реестра навыка), generic Intake
остаётся проектно-нейтральным."""
import json, os, re, subprocess, sys

SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
ORCH = os.environ.get("ORCH_ROOT", os.path.expanduser("~/.local/share/night-orchestrator"))
INTAKE = os.path.join(ORCH, "bin", "intake.py")

def project_id():
    try:
        cfg = json.load(open(os.path.join(SKILL_DIR, "project.json")))
        return cfg.get("project_id", "example-project")
    except Exception:
        return "example-project"

def route(text):
    t = text.strip()
    m = re.match(r"^(?:Найт|агон|Night|agon)\s*[:,—-]\s*(.*)$", t, re.S)
    if m:
        return {"decision": "PROJECT", "how": "prefix", "payload": m.group(1).strip()}
    if re.match(r"^/night\b", t):
        return {"decision": "PROJECT", "how": "slash", "payload": re.sub(r"^/night\s*", "", t).strip()}
    # явные проектные якоря без префикса (AG-\d+, @example-project_bot, ag(')onarena)
    if re.search(r"\bTASK-\d+\b|example-project|НайтПроект", t, re.I):
        return {"decision": "AMBIGUOUS_PROJECT", "how": "anchor", "payload": t,
                "note": "похоже на NightArena — предложить продолжить в контексте проекта; без подтверждения ничего не запускать"}
    return {"decision": "NOT_PROJECT", "how": "-", "payload": t,
            "note": "обычный ассистент; навык не вызывается"}

def main():
    text = " ".join(sys.argv[1:]) or ""
    r = route(text)
    p = project_id()
    if r["decision"] == "PROJECT":
        r["intake_cmd"] = f"python3 {INTAKE} message {json.dumps(r['payload'], ensure_ascii=False)} --project {p}"
    print(json.dumps(r, ensure_ascii=False, indent=1))

if __name__ == "__main__":
    main()
