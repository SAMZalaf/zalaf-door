#!/usr/bin/env bash
# Author: Mohamad Zalaf (https://zalaf.net)
# License: MIT
# zalaf_doo.sh v2.1 - temporary multi-agent SSH session manager
#
# Each agent seat has a key, path, policy, and expiration. Seats are identified
# by their own authorized_keys tag. Closing a seat removes only that tag; NOVA,
# the fixed ZALAF entry, and the owner's key are never removed.
set -uo pipefail
VERSION="2.1"

RUN_DIR="${ZALAF_DOOR_RUNDIR:-/root/zalaf.net/run}"
KEYFILE="${ZALAF_DOOR_KEYFILE:-/root/.ssh/authorized_keys}"
REGISTRY="$RUN_DIR/agents.registry"
SESSIONS="$RUN_DIR/sessions.dat"
JOURNAL="$RUN_DIR/door.log"
AUDIT_DIR="$RUN_DIR/audit"

SEAT_TAG="zalaf-door"
NOVA_PATTERN=" nova-agent-"
ZALAF_FIXED_TAG="zalaf-agent-20261116"
PROTECTED_LOGS="/root/nova_agent_audit.log /root/nova_agent_history.log"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'
  C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi
ok() { printf '%s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s!%s %s\n' "$C_Y" "$C_0" "$*"; }
err() { printf '%s✗%s %s\n' "$C_R" "$C_0" "$*" >&2; }
hdr() { printf '%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
dim() { printf '%s%s%s\n' "$C_D" "$*" "$C_0"; }
stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
die() { err "$*"; exit 1; }
mkdir -p "$RUN_DIR" 2>/dev/null || true
require_run_dir() {
  if [ ! -d "$RUN_DIR" ] || [ ! -w "$RUN_DIR" ]; then
    err "Cannot write to $RUN_DIR"
    dim "Run with sudo, or set ZALAF_DOOR_RUNDIR to a directory you own (testing only)." >&2
    exit 1
  fi
}
note() {
  local line; line="$(stamp) $*"
  { printf '%s\n' "$line" >> "$JOURNAL"; } 2>/dev/null || true
  chmod 600 "$JOURNAL" 2>/dev/null || true
  command -v logger >/dev/null 2>&1 && logger -t zalaf-door "$*" 2>/dev/null
}
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
count() {
  [ -f "$1" ] || { echo 0; return; }
  local n; n=$(grep "$2" -- "$3" "$1" 2>/dev/null)
  printf '%s\n' "${n:-0}" | tail -1
}
blob_of() {
  awk '{for (i=1;i<=NF;i++) if ($i ~ /^ssh-(ed25519|rsa|dss)$/ ||
    $i ~ /^ecdsa-sha2-/ || $i ~ /^sk-ssh-/) {print $(i+1); exit}}' <<<"$1"
}
fp_of_blob() {
  local tmp="$RUN_DIR/.fp.tmp"
  printf 'ssh-ed25519 %s k\n' "$1" > "$tmp" 2>/dev/null || return 1
  ssh-keygen -lf "$tmp" 2>/dev/null | awk '{print $2}'
  rm -f "$tmp"
}
exp_epoch() {
  local e="$1" y mo d h mi se
  y=${e:0:4}; mo=${e:4:2}; d=${e:6:2}; h=${e:8:2}; mi=${e:10:2}; se=${e:12:2}
  case "$y$mo$d$h$mi$se" in ''|*[!0-9]*) echo ""; return;; esac
  date -u -d "${y}-${mo}-${d} ${h}:${mi}:${se}" +%s 2>/dev/null
}
seat_regex() { printf ' %s-%s-[0-9]{14}$' "$SEAT_TAG" "$1"; }
seat_regex_any() { printf ' %s-[A-Za-z0-9_]+-[0-9]{14}$' "$SEAT_TAG"; }

seed_registry() {
  [ -f "$REGISTRY" ] && return
  cat > "$REGISTRY" <<'REG'
# name|type|blob|path|policy|comment
arena|key|AAAAC3NzaC1lZDI1NTE5AAAAIEJEfahsW+CSLFAMHxL39UktfDrWCxcwbhsaiok7dXAi|/root/zalaf.net|rw|Arena.ai agent
nova|key|AAAAC3NzaC1lZDI1NTE5AAAAIJTnfkKMkquEJ7yPb6TepAi0moSfqQyJWmpLP4vCc0nb|/root/NOVA|rw|NOVA agent
guest|prompt||/|rw|Ask for a key when opened
REG
  chmod 600 "$REGISTRY" 2>/dev/null || true
}
agents_list() { grep -v '^[[:space:]]*#' "$REGISTRY" 2>/dev/null | grep -v '^[[:space:]]*$'; }
agent_row() { agents_list | awk -F'|' -v n="$1" '$1==n{print; exit}'; }
agent_exists() { [ -n "$(agent_row "$1")" ]; }
agent_field() { agent_row "$1" | awk -F'|' -v f="$2" '{print $f}'; }
session_row() { [ -f "$SESSIONS" ] || return 1; awk -F'|' -v n="$1" '$1==n{print; exit}' "$SESSIONS"; }
session_exists() { [ -n "$(session_row "$1")" ]; }
session_set() {
  touch "$SESSIONS"; chmod 600 "$SESSIONS" 2>/dev/null || true
  grep -v "^$1|" "$SESSIONS" > "$SESSIONS.tmp" 2>/dev/null || true
  printf '%s\n' "$2" >> "$SESSIONS.tmp"; mv "$SESSIONS.tmp" "$SESSIONS"
}
session_del() {
  [ -f "$SESSIONS" ] || return
  grep -v "^$1|" "$SESSIONS" > "$SESSIONS.tmp" 2>/dev/null || true
  mv "$SESSIONS.tmp" "$SESSIONS"
}

cmd_agents() {
  seed_registry; hdr "Registered seats"
  agents_list | while IFS='|' read -r n t b p pol c; do
    local fp="—" live=""
    [ -n "${b:-}" ] && fp=$(fp_of_blob "$b")
    session_exists "$n" && live="  ${C_G}● active session${C_0}"
    printf '  %s%-10s%s  %-34s %s%s\n' "$C_B" "$n" "$C_0" "${p:-—}" "${pol:-rw}" "$live"
    printf '   %-30s %s\n' "Fingerprint" "$fp"
    [ -n "${c:-}" ] && dim "   $c"
  done
  echo; dim "  agent-add NAME --key FILE.pub [-p DIR] [-r]  ·  agent-del NAME"
}

cmd_agent_add() {
  local name="${1:-}"; [ -n "$name" ] || die "Name is required"; shift || true
  local pubfile="" pubkey="" path="/" policy="rw" comment=""
  while [ $# -gt 0 ]; do case "$1" in
    --key) pubfile="$2"; shift 2;; --pubkey) pubkey="$2"; shift 2;;
    -p|--path) path="$2"; shift 2;; -r|--read-only|--restricted) policy="restricted"; shift;;
    -c|--comment) comment="$2"; shift 2;; *) die "Unknown option: $1";;
  esac; done
  case "$name" in *[!A-Za-z0-9_]*) die "Name may contain only English letters, numbers, and _";; esac
  agent_exists "$name" && die "Seat '$name' already exists — remove it with agent-del $name"
  local blob=""
  if [ -n "$pubfile" ]; then
    [ -f "$pubfile" ] || die "No such file: $pubfile"
    blob=$(blob_of "$(cat "$pubfile")")
    comment="${comment:-$(awk '{print $NF}' "$pubfile")}"
  elif [ -n "$pubkey" ]; then blob=$(blob_of "$pubkey"); fi
  seed_registry
  printf '%s|%s|%s|%s|%s|%s\n' "$name" "$([ -n "$blob" ] && echo key || echo prompt)" \
    "$blob" "$path" "$policy" "${comment:-Added $(stamp)}" >> "$REGISTRY"
  ok "Added seat '$name' — path $path · policy $policy"
  [ -n "$blob" ] && dim "   Fingerprint: $(fp_of_blob "$blob")"
}

cmd_agent_del() {
  local name="${1:-}"; [ -n "$name" ] || die "Name is required"
  agent_exists "$name" || die "No seat with this name: $name"
  session_exists "$name" && { warn "The agent has an active session; closing it."; cmd_close -a "$name" >/dev/null 2>&1 || true; }
  grep -v "^$name|" "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
  ok "Removed '$name' from the registry (authorized_keys was not touched)."
}

cmd_open() {
  local name="arena" minutes=120 path="" policy="" wrap=0 guard=0 force=0
  local key_override="" pubkey_override="" label="" no_sftp=0 no_pty=0
  while [ $# -gt 0 ]; do case "$1" in
    -a|--agent) name="$2"; shift 2;; -m|--minutes) minutes="$2"; shift 2;;
    -p|--path) path="$2"; shift 2;; -r|--restricted|--read-only) policy="restricted"; shift;;
    --rw) policy="rw"; shift;; -w|--wrap) wrap=1; shift;; -g|--guard) guard=1; shift;;
    --force) force=1; shift;; --key) key_override="$2"; shift 2;;
    --pubkey) pubkey_override="$2"; shift 2;; --label) label="$2"; shift 2;;
    --no-sftp) no_sftp=1; shift;; --no-pty) no_pty=1; shift;; -y|--yes) shift;;
    -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
  case "$name" in *[!A-Za-z0-9_]*) die "Invalid seat name: $name";; esac
  is_num "$minutes" || die "Duration must contain only digits"
  [ "$minutes" -ge 5 ] && [ "$minutes" -le 1440 ] || die "Duration must be 5–1440 minutes"
  seed_registry
  local blob="" regpath="/" regpol="rw"
  if agent_exists "$name"; then blob=$(agent_field "$name" 3); regpath=$(agent_field "$name" 4); regpol=$(agent_field "$name" 5); fi
  [ -n "$key_override" ] && { [ -f "$key_override" ] || die "No such file: $key_override"; blob=$(blob_of "$(cat "$key_override")"); }
  [ -n "$pubkey_override" ] && blob=$(blob_of "$pubkey_override")
  [ -n "$blob" ] || die "No key for '$name' — pass --key FILE.pub or --pubkey, or register it with agent-add."
  path="${path:-$regpath}"; policy="${policy:-$regpol}"
  [ -d "$path" ] || warn "Path does not currently exist: $path"
  if session_exists "$name"; then
    [ "$force" -eq 1 ] || die "Seat '$name' is already open. Use --force or close -a $name"
    warn "Closing the existing '$name' session before reopening."; cmd_close -a "$name" >/dev/null 2>&1 || true
  fi
  mkdir -p "$(dirname "$KEYFILE")" && chmod 700 "$(dirname "$KEYFILE")" 2>/dev/null || true
  mkdir -p "$RUN_DIR"; touch "$KEYFILE"; chmod 600 "$KEYFILE"
  local bak="$RUN_DIR/authorized_keys.bak.open-$name.$(stamp | tr -d ':')"
  cp -a "$KEYFILE" "$bak" 2>/dev/null || die "Could not create a backup — nothing was changed."
  local opts="no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc"
  [ "$no_sftp" -eq 1 ] && opts="$opts,no-sftp"; [ "$no_pty" -eq 1 ] && opts="$opts,no-pty"
  [ "$policy" = restricted ] && opts="$opts,restrict"
  local exp; exp=$(date -u -d "+${minutes} minutes" +%Y%m%d%H%M%SZ 2>/dev/null) ||
    exp=$(date -u -v+"${minutes}"M +%Y%m%d%H%M%SZ 2>/dev/null) || die "Could not calculate expiration."
  local tag="${SEAT_TAG}-${name}-$(date -u +%Y%m%d%H%M%S)"
  local cmdopt=""
  if [ "$wrap" -eq 1 ]; then
    local w="$RUN_DIR/wrap.$name.sh"
    cat > "$w" <<WRAPEOF
#!/bin/sh
LOG="$AUDIT_DIR/$name.log"; umask 077; [ -d "$AUDIT_DIR" ] || mkdir -p "$AUDIT_DIR" 2>/dev/null
ts(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
say(){ printf '%s %s\n' "\$(ts)" "\$*" >> "\$LOG" 2>/dev/null; command -v logger >/dev/null 2>&1 && logger -t zalaf-door-$name "\$*" 2>/dev/null; }
say "SESSION start sid=\$\$ src=\${SSH_CONNECTION%% *} path='$path'"
cd '$path' 2>/dev/null || true
if [ -n "\${SSH_ORIGINAL_COMMAND:-}" ]; then say "CMD exec :: \$SSH_ORIGINAL_COMMAND"; sh -c "\$SSH_ORIGINAL_COMMAND"; rc=\$?; say "CMD done rc=\$rc"; exit \$rc; fi
"\${SHELL:-/bin/bash}" -il; rc=\$?; say "SESSION end rc=\$rc"; exit \$rc
WRAPEOF
    chmod 755 "$w"
    if sh -n "$w" 2>/dev/null; then cmdopt=",command=\"$w\""; ok "Audit wrapper: $w"; else rm -f "$w"; warn "Could not create wrapper; session will not be audited."; fi
  fi
  grep -vE "$(seat_regex "$name")" "$KEYFILE" > "$KEYFILE.tmp" || true
  mv "$KEYFILE.tmp" "$KEYFILE"; chmod 600 "$KEYFILE"
  printf '%s\n' "${opts}${cmdopt},expiry-time=\"${exp}\" ssh-ed25519 ${blob} ${tag}" >> "$KEYFILE"; chmod 600 "$KEYFILE"
  local before_nova before_zalaf nova_n zalaf_n other_changed
  before_nova=$(count "$bak" -cE "$NOVA_PATTERN"); before_zalaf=$(count "$bak" -cF " $ZALAF_FIXED_TAG")
  nova_n=$(count "$KEYFILE" -cE "$NOVA_PATTERN"); zalaf_n=$(count "$KEYFILE" -cF " $ZALAF_FIXED_TAG")
  other_changed=$(diff <(grep -vE "$(seat_regex "$name")" "$bak") <(grep -vF " $tag" "$KEYFILE") >/dev/null 2>&1 && echo no || echo yes)
  if [ "$nova_n" != "$before_nova" ] || [ "$zalaf_n" != "$before_zalaf" ] || [ "$other_changed" = yes ]; then
    cp -a "$bak" "$KEYFILE"; chmod 600 "$KEYFILE"
    die "Safety check failed; the backup was restored and nothing was changed."
  fi
  session_set "$name" "$name|$tag|$exp|$(stamp)|$blob|$path|$policy|$wrap|$guard|$label"
  note "OPEN seat=$name tag=$tag min=$minutes exp=$exp path=$path policy=$policy wrap=$wrap guard=$guard"
  if [ "$guard" -eq 1 ]; then
    if command -v systemd-run >/dev/null 2>&1 && systemd-run --on-active="${minutes}m" --unit="zalaf-door-$name-$(date +%s)" "$0" close -a "$name" >/dev/null 2>&1; then
      ok "systemd-run guard scheduled after $minutes minutes"
    else nohup sh -c "sleep $((minutes*60)); '$0' close -a '$name'" >/dev/null 2>&1 & ok "Sleep guard scheduled after $minutes minutes"; fi
  fi
  echo; hdr "Seat '$name' open — $minutes minutes"
  printf '  %-14s %s\n' "Tag" "$tag"; printf '  %-14s %s (UTC)\n' "Expires" "$exp"
  printf '  %-14s %s\n' "Path" "$path"; printf '  %-14s %s\n' "Policy" "$policy"
  printf '  %-14s %s\n' "Fingerprint" "$(fp_of_blob "$blob")"; printf '  %-14s %s\n' "Backup" "$bak"
}

cmd_close() {
  local name="" all=0 dry=0
  while [ $# -gt 0 ]; do case "$1" in -a|--agent) name="$2"; shift 2;; --all) all=1; shift;; --dry-run) dry=1; shift;; -y|--yes) shift;; *) die "Unknown option: $1";; esac; done
  [ "$all" -eq 1 ] && name="@all"; [ -n "$name" ] || die "Specify close -a NAME or close --all"
  [ -f "$KEYFILE" ] || { warn "No key file; nothing to close."; return; }
  local re; [ "$name" = @all ] && re=$(seat_regex_any) || re=$(seat_regex "$name")
  local before_nova before_zalaf; before_nova=$(count "$KEYFILE" -cE "$NOVA_PATTERN"); before_zalaf=$(count "$KEYFILE" -cF " $ZALAF_FIXED_TAG")
  local bak="$RUN_DIR/authorized_keys.bak.close-${name//@/}.$(stamp | tr -d ':')"
  cp -a "$KEYFILE" "$bak" 2>/dev/null || die "Could not create a backup — nothing was deleted."
  hdr "Lines to delete ($name)"; local n=0 l
  while IFS= read -r l; do [ -z "$l" ] && continue; if grep -qE "$re" <<<"$l"; then n=$((n+1)); printf '  %s\n' "$l" | cut -c1-110; fi; done < "$KEYFILE"
  [ "$n" -eq 0 ] && dim "  (none)"
  [ "$dry" -eq 1 ] && { ok "Dry run: nothing was deleted."; dim "  Backup: $bak"; return; }
  grep -vE "$re" "$KEYFILE" > "$KEYFILE.tmp" || true
  local after_nova after_zalaf; after_nova=$(count "$KEYFILE.tmp" -cE "$NOVA_PATTERN"); after_zalaf=$(count "$KEYFILE.tmp" -cF " $ZALAF_FIXED_TAG")
  local other_changed; other_changed=$(diff <(grep -vE "$re" "$KEYFILE") "$KEYFILE.tmp" >/dev/null 2>&1 && echo no || echo yes)
  if [ "$after_nova" != "$before_nova" ] || [ "$after_zalaf" != "$before_zalaf" ] || [ "$other_changed" = yes ]; then rm -f "$KEYFILE.tmp"; die "Safety check failed; nothing was deleted."; fi
  mv "$KEYFILE.tmp" "$KEYFILE"; chmod 600 "$KEYFILE"; [ "$name" = @all ] && : > "$SESSIONS" || session_del "$name"
  note "CLOSE seat=$name lines=$n nova=kept zalaf=kept"; ok "Closed '$name' — deleted $n line(s)."
}

cmd_list() {
  hdr "Active sessions"
  if [ ! -s "$SESSIONS" ]; then
    dim "  (none)"
  else
    while IFS='|' read -r n tag exp opened blob path policy wrap guard label; do
      [ -z "${n:-}" ] && continue
      local mark="${C_G}●${C_0}" remaining="—"
      grep -qF "$blob" "$KEYFILE" 2>/dev/null || mark="${C_R}✗${C_0}"
      local e; e=$(exp_epoch "$exp")
      if [ -n "${e:-}" ]; then local d=$(( (e - $(date +%s)) / 60 )); [ "$d" -lt 0 ] && remaining="${C_R}expired${C_0}" || remaining="$d minutes"; fi
      printf '  %s %s%-10s%s  expires in %-12s %s\n' "$mark" "$C_B" "$n" "$C_0" "$remaining" "${path:-—}"
    done < "$SESSIONS"
  fi
}
cmd_status() {
  local name=""; while [ $# -gt 0 ]; do case "$1" in -a|--agent) name="$2"; shift 2;; *) shift;; esac; done
  [ -n "$name" ] && { hdr "Seat '$name'"; session_exists "$name" && printf '%s\n' "$(session_row "$name")" || warn "No active session for '$name'"; return; }
  hdr "Door status"; printf '  Key file: %s\n' "$KEYFILE"; printf '  NOVA lines: %s (protected)\n' "$(count "$KEYFILE" -cE "$NOVA_PATTERN")"; printf '  Fixed ZALAF lines: %s (protected)\n' "$(count "$KEYFILE" -cF " $ZALAF_FIXED_TAG")"; cmd_list
}
cmd_log() {
  local name="" follow=0 tailn=200
  while [ $# -gt 0 ]; do case "$1" in -a|--agent) name="$2"; shift 2;; -f|--follow) follow=1; shift;; -n) tailn="$2"; shift 2;; *) shift;; esac; done
  local f="$AUDIT_DIR/$name.log"
  [ -n "$name" ] || f="$JOURNAL"; [ -f "$f" ] || { warn "No log for '$name'"; return; }
  [ "$follow" -eq 1 ] && tail -f "$f" || tail -n "$tailn" "$f"
}
cmd_doctor() {
  hdr "Environment check"
  for b in sshd ssh-keygen date systemd-run nohup logger; do command -v "$b" >/dev/null 2>&1 && printf '  ✓ %-12s %s\n' "$b" "$(command -v "$b")" || printf '  ! %-12s missing\n' "$b"; done
  printf '  Run directory: %s\n' "$RUN_DIR"; cmd_list
}
usage() {
  cat <<'USAGE'
zalaf_doo.sh v2.1 - temporary multi-agent session manager
  bash zalaf_doo.sh                         interactive menu
  open -a NAME [-m N] [-p DIR] [-r] [-w] [-g] [--force]
  close -a NAME [--dry-run] | close --all [--dry-run]
  list | status [-a NAME] | log [-a NAME] [--follow]
  agents | agent-add NAME --key FILE.pub [-p DIR] [-r] | agent-del NAME | doctor
Each seat is tagged zalaf-door-NAME-<14 digit timestamp>.
Deletion uses the tag only, preserving NOVA, fixed ZALAF, and owner entries.
USAGE
}

CMD="${1:-menu}"; shift || true
case "$CMD" in -h|--help|help) usage; exit 0;; esac
require_run_dir; seed_registry
case "$CMD" in
  open) cmd_open "$@";; close) cmd_close "$@";; list|ls) cmd_list;;
  status) cmd_status "$@";; log|logs) cmd_log "$@";; agents|seats) cmd_agents;;
  agent-add) cmd_agent_add "$@";; agent-del) cmd_agent_del "$@";; doctor) cmd_doctor;;
  menu) usage;; *) err "Unknown command: $CMD"; usage; exit 1;;
esac
