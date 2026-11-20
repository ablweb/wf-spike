# Shared helpers of the pipeline scripts (bash). Source it, do not execute it.
# The forge address, the repositories and the CI commands come from the project's .claude/wf.json. Secrets live in the per-user state folder
# (mode 700, outside every project): <user>.env holds the password and token, <user>.hdr the auth header that curl reads with
# -H @file, so no token ever appears on a command line or in output. WF_STATE moves the folder.

umask 077
WF_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE=${WF_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wf/run}
mkdir -p "$STATE" && chmod 700 "$STATE"

wfcfg() { jq -r "$1" "$WF_LIB/../wf.json" 2>/dev/null || true; }   # .claude/wf.json, written by mount.sh
BASE=$(wfcfg .forge.base)
EMAIL_DOMAIN=$(wfcfg .forge.email_domain)
BODY=${BODY:-$STATE/.body.$$}
trap 'rm -f "$BODY"' EXIT

say() { printf '%s\n' "$*" >&2; }
hdr() { printf '%s/%s.hdr' "$STATE" "$1"; }

# api_raw USER METHOD PATH [JSON|-]: prints the HTTP status, body goes to $BODY. "-" reads the JSON from stdin.
api_raw() {
  local user=$1 method=$2 path=$3 data=${4:-}
  local args=(-sS --max-time 30 -o "$BODY" -w '%{http_code}' -X "$method" -H "@$(hdr "$user")")   # a hung forge must not hang a hook
  if [ "$data" = "-" ]; then args+=(-H 'Content-Type: application/json' --data-binary @-)
  elif [ -n "$data" ]; then args+=(-H 'Content-Type: application/json' -d "$data"); fi
  curl "${args[@]}" "$BASE/api/v1$path" || echo 000
}

# api USER METHOD PATH [JSON|-]: body on stdout, non-zero on a non-2xx status.
api() {
  local code; code=$(api_raw "$@")
  if [ "${code:0:1}" != 2 ]; then say "api $2 $3 as $1 -> $code: $(head -c 300 "$BODY" 2>/dev/null)"; return 1; fi
  cat "$BODY"
}

# The notification channels of the state folder (set with wf/notify.sh; both hold secrets, so never in a project). Each sends nothing when its
# file is absent and returns curl's status when the send failed.
# notify_webhook MESSAGE: POST to the URL in notify-url (Discord-shaped: {"username", "content"}).
notify_webhook() {
  local u; u=$(cat "$STATE/notify-url" 2>/dev/null) || return 0
  curl -fsS --max-time 3 -o /dev/null -H 'Content-Type: application/json' -d "$(jq -nc --arg c "${1:0:1900}" '{username: "wf", content: $c}')" "$u"
}
# notify_mail MESSAGE: an email through curl's SMTP client; notify-mail is JSON: smtp (URL), from, to (comma list), and user, pass when the server wants a login.
# The first line of the message is the subject; subject and body are encoded, so any text travels.
notify_mail() {
  local f=$STATE/notify-mail smtp from to rcpt r subj=${1%%$'\n'*} args=(); [ -f "$f" ] || return 0
  mailcfg() { jq -r --arg k "$1" '.[$k] // empty' "$f"; }
  smtp=$(mailcfg smtp); from=$(mailcfg from); to=$(mailcfg to)
  IFS=, read -ra rcpt <<<"$to"; for r in "${rcpt[@]}"; do args+=(--mail-rcpt "${r// /}"); done
  [ -z "$(mailcfg user)" ] || args+=(--ssl-reqd -K <(jq -r '"user = " + ((.user + ":" + .pass) | @json)' "$f"))   # a login never travels in clear
  { printf 'From: wf <%s>\nTo: %s\nSubject: =?UTF-8?B?%s?=\nDate: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n' \
      "$from" "$to" "$(printf '%s' "${subj:0:120}" | base64 -w0)" "$(date -R)"
    printf '%s\n' "${1:0:1900}" | base64 -w76; } |
    curl -sS --max-time 8 --crlf --url "$smtp" --mail-from "$from" "${args[@]}" -T - -o /dev/null
}
# notify MESSAGE: the hook's word to every channel that is set. A forge or network failure never stops the pipeline.
notify() { notify_webhook "$1" >/dev/null 2>&1 || true; notify_mail "$1" >/dev/null 2>&1 || true; }

# Git over HTTP as USER; the token travels in the environment, not in argv.
git_as() {
  local user=$1; shift
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$(cat "$(hdr "$user")")" \
    GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1= \
    GIT_TERMINAL_PROMPT=0 git "$@"
}
