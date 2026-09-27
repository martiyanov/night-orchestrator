#!/usr/bin/env bash
# task.sh — единая контролируемая точка входа для lifecycle-обслуживания
# AG-запусков Night Orchestrator. Цель: ОДНО allow-always одобрение на этот
# wrapper вместо повторяющихся approvals на каждый новый run-id
# (mkdir runs/<id>/tasks, touch runs/<id>/STOP, ...).
#
# Разрешены ТОЛЬКО: new|stop|status|report <run-id>.
# Это НЕ general shell: никакого произвольного exec/путей/шелл-строк/argv
# passthrough. Нет git/docker/network/sudo/systemctl — тяжёлая работа
# остаётся за canonical night_run.sh/run_task.sh под их gates.
#
# Safety:
#   - run-id: строгий regex ^[A-Za-z0-9_-]{1,64}$ (без traversal/метасимволов);
#   - ORCH_ROOT/RUNS_DIR — literal, из окружения агента НЕ читаются;
#   - symlink-guard: run-dir не должен быть симлинком, realpath обязан
#     совпадать с каноническим путём под RUNS_DIR (защита от escape);
#   - никаких удалений; операции new/stop идемпотентны.
set -euo pipefail

ORCH_ROOT="${ORCH_ROOT:-$HOME/.local/share/night-orchestrator}"
RUNS_DIR="$ORCH_ROOT/runs"

die() { echo "ag_task: REFUSED: $*" >&2; exit 1; }
usage() { echo "usage: task.sh {new|stop|status|report|wait} <run-id> [wait: --timeout=MIN]" >&2; exit 2; }

WAIT_TIMEOUT_MIN=120
if [[ "$1" == "wait" ]]; then
    cmd="wait"; rid="${2:-}"; shift 2 2>/dev/null || shift $# 
    for arg in "$@"; do
        case "$arg" in
            --timeout=*) WAIT_TIMEOUT_MIN="${arg#--timeout=}" ;;
            *) usage ;;
        esac
    done
    [[ "$rid" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "invalid run-id"
    set -- wait "$rid"
else
    [ $# -eq 2 ] || usage
    cmd="$1"; rid="$2"
fi

# --- strict run-id validation (no eval anywhere in this script) ----------
[[ "$rid" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "invalid run-id (expected ^[A-Za-z0-9_-]{1,64}$)"

run_dir="$RUNS_DIR/$rid"

# --- symlink / path-escape guard ------------------------------------------
# RUNS_DIR каноникализуем сами; существующий run_dir отвергается, если он
# симлинк или его realpath выходит за физический RUNS_DIR.
RUNS_REAL="$(readlink -f "$RUNS_DIR")"
[ -n "$RUNS_REAL" ] && [ -d "$RUNS_REAL" ] || die "runs dir missing: $RUNS_DIR"
guard_run_dir() {
    [ -L "$run_dir" ] && die "run dir is a symlink: $run_dir"
    if [ -e "$run_dir" ]; then
        [ -d "$run_dir" ] || die "run path is not a directory: $run_dir"
        local phys
        phys="$(readlink -f "$run_dir")"
        [ "$phys" = "$RUNS_REAL/$rid" ] || die "run dir realpath escapes runs dir: $phys"
    fi
}
case "$cmd" in
    wait)
        # Умное ожидание terminal-состояния: адаптивный опрос (10s→20s→45s,
        # сброс интервала при изменениях), немедленный выход на terminal.
        [ -d "$run_dir" ] || die "run not found: $run_dir"
        guard_run_dir
        deadline=$(( $(date +%s) + WAIT_TIMEOUT_MIN * 60 ))
        interval=10 last_sig=""
        while :; do
            sig="$( { stat -c '%Y' "$run_dir/log.jsonl" "$run_dir/status.log" 2>/dev/null || true; } | sort | tail -1)$( { ls "$run_dir"/*/RESULT.json "$run_dir"/STOP 2>/dev/null || true; } | tr '\n' ' ')"
            st=""
            if [[ -f "$run_dir/status.json" ]]; then st="$(jq -r '.stage // .status // ""' "$run_dir/status.json" 2>/dev/null || true)"; fi
            case "$st" in
                FINISHED|READY_FOR_OWNER_PASS|NO_CHANGE_REQUIRED|NEEDS_OWNER_INPUT|BLOCKED|FAILED)
                    echo "ag_task: wait done: $st (run $rid)"; exit 0 ;;
            esac
            if ls "$run_dir"/*/RESULT.json >/dev/null 2>&1 || [[ -f "$run_dir/STOP" ]]; then
                echo "ag_task: wait done: terminal artifact present (run $rid)"; exit 0
            fi
            now=$(date +%s)
            [[ $now -ge $deadline ]] && { echo "ag_task: wait TIMEOUT after ${WAIT_TIMEOUT_MIN}min (run $rid)" >&2; exit 3; }
            if [[ "$sig" != "$last_sig" ]]; then last_sig="$sig"; interval=10
            elif (( interval < 45 )); then interval=$(( interval + 10 )); fi
            sleep "$interval"
        done
        ;;
    new)
        # Служебная подготовка run-state (замена ручного mkdir агентом).
        # night_run.sh ожидает СУЩЕСТВУЮЩИЙ run_dir с tasks/*.json — он сам
        # каталоги не создаёт; здесь только mkdir -p, никаких удалений.
        guard_run_dir
        if [ -d "$run_dir" ]; then
            mkdir -p "$run_dir/tasks"
            echo "ag_task: OK (exists): $run_dir"
        else
            mkdir -p "$run_dir/tasks"
            echo "ag_task: OK (created): $run_dir"
        fi
        echo "ag_task: tasks dir: $run_dir/tasks (положите TASK.json)"
        ;;
    stop)
        # Graceful stop: runner(run_task.sh) читает $RUN_DIR/STOP на turn
        # boundary. Создаём ТОЛЬКО STOP внутри существующего run-dir.
        [ -d "$run_dir" ] || die "run not found: $run_dir"
        guard_run_dir
        touch "$run_dir/STOP"
        echo "ag_task: STOP set: $run_dir/STOP"
        ;;
    status)
        # Read-only: без единой записи в FS.
        if [ ! -d "$run_dir" ]; then
            echo "ag_task: run NOT FOUND: $run_dir"
            exit 1
        fi
        guard_run_dir
        echo "run_dir: $run_dir"
        [ -e "$run_dir/STOP" ]    && echo "STOP: present"    || echo "STOP: absent"
        [ -e "$run_dir/RESULT.json" ] && echo "RESULT(batch): present" || echo "RESULT(batch): absent"
        n_tasks=0
        for t in "$run_dir"/tasks/*.json; do [ -e "$t" ] && n_tasks=$((n_tasks+1)); done
        echo "tasks/*.json: $n_tasks"
        for r in "$run_dir"/*/RESULT.json; do
            [ -e "$r" ] || continue
            printf 'task %s: %s\n' \
                "$(jq -r '.task_id // "?"' "$r" 2>/dev/null)" \
                "$(jq -r '.status // "?"' "$r" 2>/dev/null)"
        done
        if [ -f "$run_dir/status.json" ]; then
            printf 'status.json: %s\n' "$(jq -c '{status,attempt,updated_at}' "$run_dir/status.json" 2>/dev/null || echo present)"
        fi
        if [ -f "$run_dir/status.log" ]; then
            echo "status.log (last 3):"
            tail -n 3 "$run_dir/status.log" | sed 's/^/  /'
        fi
        ;;
    report)
        # Делегация canonical report-механизму (Telegram routing/формат — его).
        [ -d "$run_dir" ] || die "run not found: $run_dir"
        guard_run_dir
        exec bash "$ORCH_ROOT/bin/report.sh" "$run_dir"
        ;;
    *)
        usage
        ;;
esac
