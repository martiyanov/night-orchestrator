#!/usr/bin/env bash
# gates.sh — hard safety guard + deterministic gates for Night Orchestrator v1.
# Safety is enforced HERE, in shell code, not by model prompts.
# Sourced by run_task.sh / night_run.sh / selftest.sh.
# guard_check returns 0 (allow) / 1 (deny + reason on stderr). rc 125 in run_guarded = PERMISSION_VIOLATION.

ORCH_ROOT="${ORCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------- guard ----

guard_check() {
  local mode="$1" jail="$2" cmd="$3"
  local cmd_stripped; cmd_stripped="$(_strip_heredocs "$cmd")"
  local lc; lc="$(printf '%s' "$cmd_stripped" | tr '[:upper:]' '[:lower:]')"
  # strip harmless stderr/stdout redirections before redirect analysis
  # (2>&1, and writes to /dev/null — they do not modify any real path;
  #  redirects to real paths like 2>/home/.../err.log stay significant)
  local body="${lc//2>&1/}"; body="${body//1>&2/}"
  body="$(printf '%s' "$body" | sed -E 's#2?>{1,2} ?/dev/null# #g; s#&>{1,2} ?/dev/null# #g')"

  local re
  _deny() { echo "guard: DENY pattern [$1] matched" >&2; return 1; }

  # --- universal: production/deploy/system control -------------------------
  for re in \
    'ops/deploy' 'deploy-staging' 'deploy\.sh' \
    'systemctl' 'service[[:space:]]+[a-z-]+[[:space:]]+(start|stop|restart|reload)' \
    'docker(-compose)?[[:space:]]' 'podman[[:space:]]' \
    '(^|[[:space:]|;&(])(reboot|shutdown|halt|poweroff)([[:space:]]|$)' \
    '(^|[[:space:]|;&(])(kill|killall|pkill)([[:space:]]|$)' \
    'crontab[[:space:]]' \
    '(^|[[:space:]|;&(])(chmod|chown|chgrp|chattr|setfacl)([[:space:]]|$)' \
    '(mkfs[.a-z]*[[:space:]])' 'dd[[:space:]]+if=' 'shred[[:space:]]' \
    'find[^|;&]*( -delete| -exec| -fprintf)' \
    ; do
    [[ "$body" =~ $re ]] && { _deny "$re"; return 1; }
  done

  # --- universal: privilege / package / history tampering ------------------
  for re in \
    '(^|[[:space:]|;&(])(sudo|doas|su)([[:space:]]|$)' \
    '(pip3?[[:space:]]+install|python3?[[:space:]]+-m[[:space:]]+pip[[:space:]]+install|npm[[:space:]]+(install|i|ci)[[:space:]]|yarn[[:space:]]+add|apt(-get)?[[:space:]]+(install|remove|purge|upgrade|update)|snap[[:space:]]+(install|refresh)|dpkg[[:space:]]+(-i|--configure)|gem[[:space:]]+install|cargo[[:space:]]+(install|add)|go[[:space:]]+install)' \
    '(^|[[:space:];&(])(bash_env|ld_preload|env)(=)' \
    '(^|[[:space:]])path=' \
    'core\.hooksPath' '\.git/hooks' \
    '(^|[[:space:];&(])(git_dir|git_work_tree|git_index_file|git_object_directory)(=)' \
    '\-\-git-dir' '\-\-work-tree' \
    ; do
    [[ "$body" =~ $re ]] && { _deny "$re"; return 1; }
  done

  # --- universal: secrets ---------------------------------------------------
  # any .env* token (also .env.example), provider secrets, host credentials
  if [[ "$body" =~ (^|[^a-z0-9_.-])\.env[a-z0-9._-]* ]]; then _deny ".env* token"; return 1; fi
  # файловые имена, оканчивающиеся на .env (post-cutover прод-секреты живут в
  # example: /srv/prod/env/app.env — filename-like env secrets
  # его не ловил: перед .env стоит alnum). Hardening после реального прогона.
  if [[ "$body" =~ (^|[^a-z0-9_.-])[a-z0-9_.-]+\.env([[:space:]/\"]|$) ]]; then _deny "*.env filename"; return 1; fi
  # запретные корни конкретного проекта (guard_roots из реестра projects.json,
  # пробрасывается run_task'ом): недоступны из команд целиком
  if [[ -n "${GUARD_DENY_ROOTS:-}" ]]; then
    local _r
    for _r in $GUARD_DENY_ROOTS; do
      if [[ "$body" == *"$_r"* ]]; then _deny "project guard root: $_r"; return 1; fi
    done
  fi
  for re in \
    '/\.ssh' '/\.gnupg' '/\.aws' '\.git-credentials' '\.netrc' \
    'providers\.json' '/secrets' '/credentials' \
    'openclaw\.json' '/credentials' 'id_rsa' 'id_ed25519' 'id_ecdsa' \
    '\.pem([[:space:]]|"'\'']|$)' 'night-orchestrator' \
    ; do
    [[ "$body" =~ $re ]] && { _deny "$re"; return 1; }
  done

  # --- universal: network (night runs are offline) --------------------------
  for re in \
    '(^|[[:space:]|;&(])(curl|wget|nc|ncat|netcat|socat|ssh|scp|sftp|rsync|ftp|telnet|gh|ping|dig|nslookup)([[:space:]]|$)' \
    'base64' 'openssl[[:space:]]' \
    ; do
    [[ "$body" =~ $re ]] && { _deny "$re"; return 1; }
  done

  # --- universal: git hard denials -----------------------------------------
  # a real run postmortem
  # read-only подкоманд (`git merge-base` → ложно DENY как `merge`). Теперь
  # глагол обязан кончаться границей (не alnum/dash/underscore), а опасное
  # plumbing с похожими префиксами запрещено отдельным списком ниже.
  # Матчинг идёт по gbody (body без кавычек): закрывает обход `git "merge" x`
  # и mid-word-кавычки (`git me"rge"`), сохраняя поведение для inert-текста.
  local gbody; gbody="$(printf '%s' "$body" | tr -d "\"'")"
  for re in \
    'git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(push|merge|reset|rebase|clean|filter-branch|cherry-pick|revert|reflog|gc|prune|bisect|worktree|submodule|apply|am|remote|fetch|pull|config|init|clone|daemon|notes|replace|repack|mv|rm)([^[:alnum:]_-]|$)' \
    ; do
    [[ "$gbody" =~ $re ]] && { _deny "$re"; return 1; }
  done
  # plumbing-подкоманды, чьи префиксы после boundary-фикса перестали
  # покрываться списком выше: пишут файлы/объекты или являются сетевым
  # транспортом (merge-base — единственное намеренное исключение, см.
  # writable-allowlist и selftest 4e).
  for re in \
    'git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(merge-file|merge-index|merge-tree|checkout-index|commit-tree|commit-graph|fetch-pack|upload-pack|send-pack|remote-ext|remote-fd|prune-packed)([^[:alnum:]_-]|$)' \
    ; do
    [[ "$gbody" =~ $re ]] && { _deny "$re (plumbing)"; return 1; }
  done

  # --- universal: git -c / git -C (case-sensitive, heredoc-stripped cmd) ----
  # `git -c <cfg>=<v>` overrides git config (core.hooksPath evasion) and must
  # be denied; `git -C <dir>` (capital C) only switches the working directory
  # and is legitimate inside the jail. Matching these on the lowercased body
  # collapsed -C into -c and false-positived run exec10's `git -C . status`.
  # Input is $cmd_stripped (heredoc bodies removed, case preserved): file
  # content written via heredoc is inert text. Only git's GLOBAL option prefix
  # is scanned, so subcommand flags such as `git grep -c` (count) or
  # `git diff -C3` (rename detection) stay allowed.
  local _gseg _gtok _gti _gval
  while IFS= read -r _gseg; do
    [[ -z "$_gseg" ]] && continue
    local -a _gtoks=()
    read -r -a _gtoks <<< "$_gseg"
    _gti=0
    while (( _gti < ${#_gtoks[@]} )); do
      _gtok="${_gtoks[$_gti]}"
      case "$_gtok" in
        -c) _deny "git -c (config override)"; return 1 ;;
        -C)
          _gval="${_gtoks[_gti+1]:-}"
          case "$_gval" in
            "$jail"|"$jail"/*|/tmp|/tmp/*|/dev/null) : ;;
            /*) echo "guard: DENY git -C outside jail: $_gval" >&2; return 1 ;;
            *) : ;;  # relative: resolves against the jail cwd in run_guarded
          esac
          _gti=$((_gti+2)) ;;
        -*) _gti=$((_gti+1)) ;;
        *) break ;;  # subcommand reached: its own flags are not global config
      esac
    done
  done < <(printf '%s' "$cmd_stripped" | grep -oE '(^|[[:space:][:punct:]])git[[:space:]][^|;&]*' | sed -E 's/^[[:space:][:punct:]]*git[[:space:]]+//')

  # --- universal: nested shells / script exec / eval (evasion surface) -----
  for re in \
    '(^|[[:space:]|;&(])(bash|sh|zsh|dash|ksh)([[:space:]]|$)' \
    '(^|[[:space:]|;&(])\./' 'source[[:space:]]' '(^|[[:space:]|;&(])\.[[:space:]]+\.?/' \
    '(^|[[:space:]|;&(])\.[[:space:]]+/' \
    'eval[[:space:]]' \
    ; do
    [[ "$body" =~ $re ]] && { _deny "$re"; return 1; }
  done

  # --- python: read_only forbids all; writable allows only pytest form -----
  re='(^|[[:space:]|;&(])python3?([[:space:]]|$)'
  if [[ "$body" =~ $re ]]; then
    if [[ "$mode" == "read_only" ]]; then _deny "python in read_only"; return 1; fi
    re='python3?[[:space:]]+-m[[:space:]]+pytest'
    if ! [[ "$body" =~ $re ]]; then
      _deny "python outside pytest form"; return 1
    fi
  fi

  # --- data dir of protected projects (production sqlite/state) ------------
  re='(^|[^a-z0-9_.-])data/[a-z0-9._-]'
  if [[ "$body" =~ $re ]]; then _deny "data/ path"; return 1; fi

  if [[ "$mode" == "read_only" ]]; then
    # no writes at all: redirects, write verbs, git mutations, tests
    if [[ "$body" == *'>'* ]]; then _deny "redirect in read_only"; return 1; fi
    # чтение веток (branch --show-current/--list/-l/-a/-v) — read-only: вырезать
    # из тела перед матчем мутационных git-глаголов (создание/удаление веток
    # остаётся запрещённым). Реальный кейс: verify-only задача не могла
    # прочитать имя текущей ветки (run 20260927-zapusti-zaranee-po-02).
    local body_ro="${body}"
    body_ro="$(printf '%s' "$body_ro" | sed -E 's/git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*branch[[:space:]]+(--show-current|--list|-l|-a|-v|--verbose)([[:space:]]|$)/git brread /g')"
    for re in \
      '(^|[[:space:]|;&(])(tee|touch|mkdir|rmdir|rm|mv|cp|ln|truncate)([[:space:]]|$)' \
      'sed[^|;&]*-i' \
      'git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(add|commit|checkout|switch|branch|stash|restore|tag)' \
      '(^|[[:space:]|;&(])pytest([[:space:]]|$)' \
      ; do
      [[ "$body_ro" =~ $re ]] && { _deny "$re (read_only)"; return 1; }
    done
    return 0
  fi

  # --- writable mode --------------------------------------------------------
  # rm -rf / rm -fr entirely; plain rm <file> allowed
  re='(^|[[:space:]|;&(])rm[[:space:]]+-[a-z]*([rf][a-z]*|[fr][a-z]*)'
  if [[ "$body" =~ $re ]]; then
    _deny "rm -rf/-fr"; return 1
  fi
  # pytest allowed (iterate on tests); python otherwise already denied above

  # absolute paths: writes only inside jail or /tmp; cd only inside jail
  # (paths extracted from the ORIGINAL command, token-boundary aware:
  #  relative paths like app/services/duel_service.py are NOT absolute paths;
  #  command substitution, NOT process substitution — python output through
  #  < <(...) is unreliable when the helper uses a heredoc)
  local tok _toks
  _toks="$(_abs_path_tokens "$cmd_stripped")"
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    case "$tok" in
      "$jail"|"$jail"/*|/tmp|/tmp/*|/dev/null|/dev/stdout|/dev/stderr) : ;;
      *)
        # any abs path outside allowed prefixes combined with ANY write op -> deny
        if echo "$body" | grep -qE '(^|[[:space:]|;&(])(cd|tee|touch|mkdir|rmdir|rm|mv|cp|ln|truncate|dd)([[:space:]])|sed[[:space:]][^|;&]*-i|>'; then
          echo "guard: DENY abs path outside jail with write op: $tok" >&2; return 1
        fi
        ;;
    esac
  done <<< "$_toks"

  # cd to abs path outside jail (from ORIGINAL command — paths are case-sensitive;
  # command substitution, not process substitution)
  local cdprefix _cds
  _cds="$(printf '%s' "$cmd" | grep -oE 'cd[[:space:]]+/[a-zA-Z0-9._/-]+' | sed -E 's/^cd[[:space:]]+//' || true)"
  while IFS= read -r cdprefix; do
    [[ -z "$cdprefix" ]] && continue
    case "$cdprefix" in
      "$jail"|"$jail"/*|/tmp|/tmp/*) : ;;
      *) echo "guard: DENY cd outside jail: $cdprefix" >&2; return 1 ;;
    esac
  done <<< "$_cds"

  # git verb allowlist for writable mode
  local verb gitopts
  gitverb_scan() {
    local s="$1" out verb
    out=""
    while [[ "$s" =~ git[[:space:]]+(.*)$ ]]; do
      local rest="${BASH_REMATCH[1]}"
      verb=""
      # skip option tokens; -c consumes an extra token
      while [[ "$rest" =~ ^(-[^[:space:]]+)([[:space:]]+(.*))?$ ]]; do
        local opt="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[3]:-}"
        [[ "$opt" == "-c" || "$opt" == "-C" ]] && rest="${rest#* }"
        [[ -z "$rest" ]] && break
      done
      if [[ "$rest" =~ ^([^[:space:]]+) ]]; then verb="${BASH_REMATCH[1]}"; fi
      [[ -n "$verb" ]] && out="$out $verb"
      # continue after this git occurrence
      s="${s#*git}"; s=" ${s}"
      [[ "$s" =~ git[[:space:]] ]] || break
    done
    echo "$out"
  }
  local verbs; verbs="$(gitverb_scan "$body")"
  local re_bd re_sw_no_c re_co_no_b
  re_bd='git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*branch[[:space:]]+[^|;&]*-[dD]([[:space:]]|$)'
  re_sw_no_c='git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*switch([[:space:]]+[^|;&]*)?([[:space:]]|$)'
  re_co_no_b='git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*checkout([[:space:]]+[^|;&]*)?([[:space:]]|$)'
  for verb in $verbs; do
    case "$verb" in
      status|diff|log|show|rev-parse|ls-files|grep|add|commit|stash|merge-base) : ;;
      branch)
        if [[ "$body" =~ $re_bd ]]; then
          _deny "git branch -d/-D"; return 1
        fi ;;
      switch)
        re='git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*switch[[:space:]]+-c([[:space:]]|$)'
        if ! [[ "$body" =~ $re ]]; then
          _deny "git switch without -c"; return 1
        fi ;;
      checkout)
        re='git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*checkout[[:space:]]+-b([[:space:]]|$)'
        if ! [[ "$body" =~ $re ]]; then
          _deny "git checkout without -b"; return 1
        fi ;;
      *)
        _deny "git verb not allowlisted: $verb"; return 1 ;;
    esac
  done

  return 0
}

# run_guarded MODE JAIL TIMEOUT_S CMD OUTFILE
# executes CMD with bash -c inside JAIL under sanitized env; rc 125 => guard violation
run_guarded() {
  local mode="$1" jail="$2" tmo="$3" cmd="$4" out="$5"
  if ! guard_check "$mode" "$jail" "$cmd"; then return 125; fi
  # NOTE: NO_* must be argv assignments to env (env -i clears inherited environ)
  env -i \
    PATH="${ORCH_TEST_VENV:+$ORCH_TEST_VENV/bin:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME="$jail" \
    LANG="${LANG:-C.UTF-8}" TERM=dumb \
    GIT_TERMINAL_PROMPT=0 \
    GIT_AUTHOR_NAME="Night Orchestrator" GIT_AUTHOR_EMAIL="night@orchestrator.local" \
    GIT_COMMITTER_NAME="Night Orchestrator" GIT_COMMITTER_EMAIL="night@orchestrator.local" \
    PYTHONDONTWRITEBYTECODE=1 \
    NO_CMD="$cmd" NO_JAIL="$jail" NO_TMO="$tmo" NO_OUT="$out" \
    bash -c '
      timeout -k 5 "$NO_TMO" bash -c "cd \"$NO_JAIL\" && eval \"\$NO_CMD\"" >"$NO_OUT" 2>&1
    '
  local rc=$?
  return $rc
}

# ------------------------------------------------------------- validators --

validate_schema() { # FILE SCHEMA -> prints OK or error
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
try:
    import jsonschema
    data = json.load(open(sys.argv[1]))
    schema = json.load(open(sys.argv[2]))
    jsonschema.validate(data, schema)
    print("OK")
except Exception as e:
    print(f"SCHEMA_ERROR: {type(e).__name__}: {str(e)[:500]}")
PYEOF
}

# --------------------------------------------------------- deterministic gates

# path matches glob (fnmatch) with dir/ prefix convenience
_path_match() { # path pattern
  python3 - "$1" "$2" <<'PYEOF'
import fnmatch, sys
p, pat = sys.argv[1], sys.argv[2].rstrip('/')
ok = fnmatch.fnmatch(p, pat) or fnmatch.fnmatch(p, pat + '/*') or (pat and p.startswith(pat + '/'))
print("MATCH" if ok else "NO")
PYEOF
}

# _strip_heredocs CMD — remove BODIES of QUOTED heredocs (<<'D', <<"D", <<\D)
# before pattern analysis. A quoted delimiter makes the body fully literal
# (no parameter/command expansion at eval), so it is inert text; guard patterns
# applied to it caused false PERMISSION_VIOLATIONs (e.g. "git -c" in a docstring).
# UNQUOTED <<D heredocs are NOT stripped: their $()/`` bodies expand at eval
# time and must stay checked (selftest 4g).
_strip_heredocs() {
  python3 - "$1" <<'PYSTRIP'
import re, sys
cmd = sys.argv[1]
out, skip = [], None
heredoc_re = re.compile(r"""<<-?\s*(?:(['"])([A-Za-z_][A-Za-z0-9_]*)\1|\\([A-Za-z_][A-Za-z0-9_]*))""")
blanker_re = re.compile(r"""<<-?\s*(?:(['"])[A-Za-z_][A-Za-z0-9_]*\1|\\[A-Za-z_][A-Za-z0-9_]*)""")
for ln in cmd.split("\n"):
    if skip is not None:
        if ln.strip() == skip:
            skip = None
        continue
    m = heredoc_re.search(ln)
    if m:
        skip = m.group(2) or m.group(3)
        out.append(blanker_re.sub(" <<HEREDOC", ln))
        continue
    out.append(ln)
sys.stdout.write("\n".join(out))
PYSTRIP
}

# _abs_path_tokens CMD — extract GENUINE absolute paths (leading slash at a token
# boundary: start, whitespace, shell separator, quote, '=', '[').
# Relative paths like app/services/duel_service.py must NOT yield /services/...
# sed SCRIPT arguments are not paths (exec11: `sed -i '/x/a y'` yielded /x):
# script words (first bare word after sed, -e/-f/--expression/--file args,
# attached -eSCRIPT form) are excluded; file operands — quoted or not — remain
# audited (selftest 4g: `echo evil > '$HOME/evil.txt'` stays DENY).
# (awk scripts share the shape but had no failing run yet — out of scope.)
_abs_path_tokens() {
  python3 - "$1" <<'PYEOF'
import re, sys

s = sys.argv[1]

# quote-aware word tokenizer with character spans
words = []  # (text, start, end_exclusive)
i, n = 0, len(s)
cur, start = "", None
while i < n:
    c = s[i]
    if c in " \t\n":
        if cur:
            words.append((cur, start, i)); cur = ""
        i += 1
        continue
    if cur == "":
        start = i
    if c == "'":
        j = s.find("'", i + 1)
        j = n - 1 if j == -1 else j
        cur += s[i:j + 1]; i = j + 1; continue
    if c == '"':
        j = i + 1
        while j < n and s[j] != '"':
            j += 2 if s[j] == "\\" else 1
        j = min(j, n - 1)
        cur += s[i:j + 1]; i = j + 1; continue
    if c == "\\":
        cur += s[i:i + 2]; i += 2; continue
    cur += c; i += 1
if cur:
    words.append((cur, start, n))

# exclude sed script words AND awk program words from path extraction
# (postmortem: `/^### TASK-1/` inside an awk regex literal was
#  tokenized as absolute path `/TASK-7`. Lexical rule: the PROGRAM string
#  of awk/gawk/mawk (and sed script) is inert text, never a path operand;
#  FILE operands after the program stay path candidates. awk -f PROGFILE
#  stays a candidate too — unlike sed -f, it is real filesystem access.)
excl = []  # char ranges (start, end_exclusive)
k = 0
while k < len(words):
    w = words[k][0]
    if w.rsplit("/", 1)[-1] == "sed":
        k += 1
        saw_script = False
        while k < len(words):
            t = words[k][0]
            if t in ("-e", "--expression", "-f", "--file"):
                if k + 1 < len(words):
                    excl.append((words[k + 1][1], words[k + 1][2]))
                saw_script = True
                k += 2
                continue
            if t.startswith("-") and t != "-":
                if t.startswith("-e") and len(t) > 2:  # attached -eSCRIPT form
                    excl.append((words[k][1], words[k][2]))
                    saw_script = True
                k += 1
                continue
            break
        if k < len(words) and not saw_script:
            excl.append((words[k][1], words[k][2]))  # first bare word = script
            k += 1
    elif w.rsplit("/", 1)[-1] in ("awk", "gawk", "mawk"):
        k += 1
        saw_program = False
        while k < len(words):
            t = words[k][0]
            if t in ("-v", "--assign", "-F", "--field-separator"):
                if k + 1 < len(words):  # flag VALUE is inert (var=..., sep)
                    excl.append((words[k + 1][1], words[k + 1][2]))
                k += 2
                continue
            if t.startswith("-v") and len(t) > 2:  # attached -vVAR=VAL
                excl.append((words[k][1], words[k][2]))
                k += 1
                continue
            if t.startswith("-F") and len(t) > 2:  # attached -FSEP
                excl.append((words[k][1], words[k][2]))
                k += 1
                continue
            if t.startswith("-") and t != "-":
                k += 1
                continue
            if not saw_program:
                excl.append((words[k][1], words[k][2]))  # program = inert text
                saw_program = True
                k += 1
                continue
            break  # file operands: remain path candidates
    else:
        k += 1

def excluded(a):
    return any(a >= x and a < y for x, y in excl)

toks = []
for m in re.finditer(r'(?:^|[\s;&|><("\'`=\[])(/[A-Za-z0-9._~-]+(?:/[A-Za-z0-9._~-]+)*)', s):
    if excluded(m.start(1)):
        continue
    toks.append(m.group(1))
sys.stdout.write("\n".join(toks))
PYEOF
}

# gate_changed_paths JAIL MODE BASE_BRANCH ; env: ALLOWED_GLOBS, FORBIDDEN_GLOBS (space-separated)
# verifies all changes (committed vs base + working tree) are inside allowed and outside forbidden
gate_changed_paths() {
  local jail="$1" mode="$2" base="$3"
  local files=""
  if [[ "$mode" == "writable" ]]; then
    files="$(git -C "$jail" diff --name-only "${base}...HEAD" 2>/dev/null; git -C "$jail" status --porcelain | awk '{print $NF}')"
  else
    files="$(git -C "$jail" status --porcelain | awk '{print $NF}')"
  fi
  files="$(printf '%s\n' "$files" | sed '/^$/d' | sort -u)"
  if [[ -z "$files" ]]; then
    echo "changed_paths:PASS|no changes"
    return 0
  fi
  local bad_allowed="" bad_forbidden="" f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$mode" == "read_only" ]]; then
      bad_allowed="$bad_allowed $f"; continue
    fi
    local ok=NO
    for pat in $ALLOWED_GLOBS; do
      [[ "$(_path_match "$f" "$pat")" == "MATCH" ]] && { ok=YES; break; }
    done
    [[ "$ok" != "YES" ]] && bad_allowed="$bad_allowed $f"
    for pat in $FORBIDDEN_GLOBS; do
      [[ "$(_path_match "$f" "$pat")" == "MATCH" ]] && bad_forbidden="$bad_forbidden $f"
    done
  done <<< "$files"
  if [[ -n "$bad_allowed" || -n "$bad_forbidden" ]]; then
    echo "changed_paths:FAIL|outside_allowed:[$bad_allowed ] forbidden:[$bad_forbidden ]"
    return 1
  fi
  echo "changed_paths:PASS|changed:[$(echo $files | tr '\n' ' ')]"
  return 0
}

gate_git_diff_check() { # JAIL
  local out; out="$(git -C "$1" diff --check 2>&1)"; local rc=$?
  if [[ $rc -ne 0 || -n "$out" ]]; then echo "git_diff_check:FAIL|${out:-rc=$rc}"; return 1; fi
  echo "git_diff_check:PASS|no whitespace/conflict-marker errors"; return 0
}

gate_git_status_clean() { # JAIL  (read_only backstop: production tree untouched)
  local out; out="$(git -C "$1" status --porcelain 2>&1)"
  if [[ -n "$out" ]]; then echo "git_status_clean:FAIL|dirty:[$out]"; return 1; fi
  echo "git_status_clean:PASS|clean"; return 0
}

gate_run_checks() { # JAIL CHECKS_FILE MODE TIMEOUT OUTDIR ; CHECKS_FILE is a path to a JSON array
  local jail="$1" checks_file="$2" mode="$3" def_tmo="$4" outdir="$5"
  local n; n="$(jq 'length' "$checks_file" 2>/dev/null)"; n="${n:-0}"
  local i=0 rc_all=0
  while [[ $i -lt $n ]]; do
    local name cmd tmo
    name="$(jq -r ".[$i].name" "$checks_file")"
    cmd="$(jq -r ".[$i].command" "$checks_file")"
    tmo="$(jq -r ".[$i].timeout_seconds // $def_tmo" "$checks_file")"
    local outf="$outdir/check_${i//[^0-9]/}_$(echo "$name" | tr -c 'a-zA-Z0-9' '_').log"
    run_guarded "$mode" "$jail" "$tmo" "$cmd" "$outf"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "task_checks:FAIL|$name rc=$rc tail=$(tail -c 400 "$outf" 2>/dev/null | tr '\n' ' ')"
      return 1
    fi
    i=$((i+1))
  done
  echo "task_checks:PASS|$n checks"
  return 0
}

gate_full_offline() { # JAIL TEST_CMD OUTFILE  (uses $TEST_VENV_DIR for interpreter)
  local jail="$1" test_cmd="$2" outf="$3"
  (
    cd "$jail" || exit 1
    export PATH="${TEST_VENV_DIR:+$TEST_VENV_DIR/bin:}$HOME/.local/bin:$PATH"
    eval "$test_cmd"
  ) >"$outf" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "full_offline_gate:FAIL|rc=$rc tail=$(tail -c 500 "$outf" | tr '\n' ' ')"; return 1
  fi
  echo "full_offline_gate:PASS|$(tail -c 200 "$outf" | tr '\n' ' ' | grep -oE '[0-9]+ passed[^)]*' | tail -1)"
  return 0
}
