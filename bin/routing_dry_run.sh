#!/usr/bin/env bash
# routing_dry_run.sh <task.json> [profile] — resolve the model chain WITHOUT calling models.
set -u
ORCH_ROOT="${ORCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TASK_FILE="${1:?task.json}"; PROFILE="${2:-$(jq -r '.execution_profile // "balanced"' "$ORCH_ROOT/config/permissions.json")}"
pj() { jq -r --arg p "$PROFILE" --arg k "$1" '.profiles[$p][$k] // .profiles.balanced[$k]' "$ORCH_ROOT/config/permissions.json"; }
TID="$(jq -r .task_id "$TASK_FILE")"; RISK="$(jq -r .risk "$TASK_FILE")"; MODE="$(jq -r .mode "$TASK_FILE")"
TRIG="$(jq -r '.explicit_review_trigger // false' "$TASK_FILE")"
REVIEW="$(jq -r --arg r "$RISK" '.roles["review_" + (.risk | ascii_downcase)].primary // .roles.review_medium.primary' "$ORCH_ROOT/config/routing.json" 2>/dev/null)"
REVIEW="$(jq -r --arg r "$RISK" '.roles["review_" + ($r | ascii_downcase)].primary' "$ORCH_ROOT/config/routing.json")"
echo "Task:        $TID (risk=$RISK mode=$MODE profile=$PROFILE)"
echo "Planner:     $(jq -r --arg r "$RISK" '.roles["planner_" + ($r | ascii_downcase)].primary // "skip (bounded LOW)"' "$ORCH_ROOT/config/routing.json" 2>/dev/null || echo skip)"
echo "Executor:    $(pj executor_model)"
echo "Takeover:    $(pj takeover_model) (triggers: $(pj escalate_after_turns_without_write) turns w/o write, $(pj escalate_after_minutes_without_write) min w/o write, $(pj escalate_after_reads_post_write) reads after write; once, no return)"
echo "Review:      ${REVIEW:-deterministic_gates (LOW)}"
echo "Independent: $(jq -r '.roles.review_independent.primary' "$ORCH_ROOT/config/routing.json") trigger_only; explicit_review_trigger=$TRIG -> $([[ "$TRIG" == "true" ]] && echo "enabled" || echo "DISABLED (guard refuses, exit 43)")"
echo "Turns:       max $(pj max_agent_turns); hard budget $(pj task_hard_budget_minutes) min; first-write target $(pj first_write_target_minutes) min"
echo "Policy:      attempts=$(jq -r .max_executor_attempts "$ORCH_ROOT/config/permissions.json") + 1 bounded post-strong-review; push/merge/deploy=forbidden"
