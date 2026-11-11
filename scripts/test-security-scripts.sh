#!/usr/bin/env bash
set -Euo pipefail
# ==========================================================================
# Mock tests for scripts/verify-master-rotation.sh and scripts/verify-imds-isolation.sh.
# Runs both scripts in a sandbox with stub `docker`, `aws` and `curl` and fake credential
# files. No real database, AWS API or instance metadata is contacted.
# ==========================================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/sw-sec-test.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

OLD_PW="oldMasterPw$(openssl rand -hex 6)"; NEW_PW="newMasterPw$(openssl rand -hex 16)"
APP_PW="appPw$(openssl rand -hex 16)"; MIG_PW="migPw$(openssl rand -hex 16)"
H=stockwatch-primary-db.cns8kouwop3n.ap-southeast-2.rds.amazonaws.com
Q='schema=public&sslmode=require&sslaccept=strict&sslcert=ap-southeast-2-bundle.pem'

setup() {
  rm -rf "${SB:?}/repo" "${SB:?}/bin"; mkdir -p "$SB/repo/scripts" "$SB/bin"
  cp "$ROOT/scripts/verify-master-rotation.sh" "$ROOT/scripts/verify-imds-isolation.sh" "$SB/repo/scripts/"
  printf 'DATABASE_URL="postgresql://stockwatch_app:%s@%s:5432/stockwatch?%s"\nMIGRATION_DATABASE_URL="postgresql://stockwatch_migrator:%s@%s:5432/stockwatch?%s"\n' "$APP_PW" "$H" "$Q" "$MIG_PW" "$H" "$Q" > "$SB/repo/.env"
  printf 'DATABASE_URL="postgresql://stockwatch_admin:%s@%s:5432/stockwatch?%s"\n' "$OLD_PW" "$H" "$Q" > "$SB/repo/.env.pre-roles"
  : > "$SB/argv.log"
  cat > "$SB/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/argv.log"
case "$1" in
  run)
    if [[ "$*" == *" psql "* ]]; then
      user=""; prev=""; for a in "$@"; do [[ "$prev" == -U ]] && user="$a"; prev="$a"; done
      sql="${*: -1}"
      [[ "${STUB_ODD:-}" == "$user" ]] && { echo 'unexpected notice'; exit 0; }
      [[ "${STUB_CONN_FAIL:-}" == "$user" ]] && { echo 'psql: error: connection to server at "db" (10.0.0.1), port 5432 failed: timeout expired'; exit 2; }
      want_var="STUB_PW_${user}"; want="${!want_var:-}"
      if [[ -n "$want" && "$PGPASSWORD" == "$want" ]]; then
        if [[ "$sql" == *"rds_superuser"* ]]; then echo "stockwatch_admin ssl=true rds_superuser=true"
        elif [[ "$sql" == *"current_user"* ]]; then echo "$user"; else echo 1; fi
      else echo "psql: error: connection to server at \"db\" (10.0.0.1), port 5432 failed: FATAL:  password authentication failed for user \"$user\""; exit 2; fi
    elif [[ "$*" == *"node -e"* ]]; then echo "${STUB_PROBE_RUN:-token=timeout credential_path=not-attempted}"
    else echo "docker: unexpected run" >&2; exit 125; fi ;;
  exec)
    if [[ "$*" == *"command -v node"* ]]; then [[ "$*" == *stockwatch-redis* || "$*" == *stockwatch-postgres* ]] && exit 1 || exit 0; fi
    if [[ "$*" == *"PrismaClient"* ]]; then echo "${STUB_APP_USER:-stockwatch_app}"; exit 0; fi
    if [[ "$*" == *"node -e"* ]]; then c=""; for a in "$@"; do [[ "$a" == stockwatch-* ]] && c="$a"; done; v="STUB_PROBE_${c//-/_}"; echo "${!v:-token=timeout credential_path=not-attempted}"; exit 0; fi ;;
  inspect) echo "${STUB_STARTED:-2026-11-11T02:45:12.141244892Z}" ;;
  ps) printf '%s\n' stockwatch-backend stockwatch-frontend stockwatch-postgres stockwatch-redis stockwatch-worker ;;
esac
STUB
  cat > "$SB/bin/aws" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${STUB_EVENT:-}" ]]; then echo "$STUB_EVENT"; else echo "An error occurred (AccessDenied): User: arn:aws:sts::123456789012:assumed-role/x is not authorized"; exit 254; fi
STUB
  cat > "$SB/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *api/token* ]]; then printf 'faketoken'; elif [[ "$*" == *security-credentials* ]]; then printf '200'; else printf '%s' "${STUB_HEALTH:-200}"; fi
STUB
  chmod +x "$SB/bin/"*
}

rot() { # rot <stdin-password> [args] -> OUT, RC
  local pw="$1"; shift
  OUT="$(cd "$SB/repo" && printf '%s\n' "$pw" | env PATH="$SB/bin:$PATH" HOME="$SB" STUB_DIR="$SB" \
    STUB_PW_stockwatch_admin="${ADMIN_ACCEPTS:-$NEW_PW}" STUB_PW_stockwatch_app="$APP_PW" STUB_PW_stockwatch_migrator="$MIG_PW" \
    STUB_EVENT="${EVENT-2026-11-11T08:10:00Z}" STUB_CONN_FAIL="${CONN_FAIL:-}" STUB_ODD="${ODD:-}" STUB_STARTED="${STARTED:-2026-11-11T02:45:12.141244892Z}" \
    ${TRACE:-} bash ${XFLAG:-} scripts/verify-master-rotation.sh "$@" 2>&1)"; RC=$?
}
no_secrets() { # no_secrets <label>
  local s leak=0
  for s in "$OLD_PW" "$NEW_PW" "$APP_PW" "$MIG_PW"; do grep -qF -- "$s" <<<"$OUT" && leak=1; grep -qF -- "$s" "$SB/argv.log" && leak=2; done
  [[ "$leak" == 0 ]] && ok "$1: no password in output or in any docker argv" || bad "$1: password exposed (code $leak)"
}

echo "verify-master-rotation.sh (mocked)"
setup; rot "$NEW_PW" --since 2026-11-11T08:00:00Z
[[ "$RC" == 0 ]] && grep -q 'Summary: 10 passed, 0 failed' <<<"$OUT" && ok "rotated: all 10 checks pass, exit 0" || { bad "rotated: rc=$RC"; tail -12 <<<"$OUT"; }
[[ -f "$SB/repo/.env.pre-roles" ]] && ok "without --delete-pre-roles the file is kept" || bad "file deleted without flag"
no_secrets "rotated"
setup; rot "$NEW_PW" --since 2026-11-11T08:00:00Z --delete-pre-roles
[[ "$RC" == 0 && ! -f "$SB/repo/.env.pre-roles" ]] && ok "--delete-pre-roles deletes only after all checks pass" || bad "delete flag: rc=$RC exists=$([[ -f $SB/repo/.env.pre-roles ]] && echo yes)"
setup; ADMIN_ACCEPTS="$OLD_PW" rot "$NEW_PW" --since 2026-11-11T08:00:00Z --delete-pre-roles
[[ "$RC" == 1 ]] && grep -q 'old master credential still ACCEPTED' <<<"$OUT" && [[ -f "$SB/repo/.env.pre-roles" ]] && ok "not rotated: old accepted -> FAIL, exit 1, file kept" || bad "not rotated: rc=$RC"
setup; CONN_FAIL=stockwatch_admin rot "$NEW_PW" --since 2026-11-11T08:00:00Z --delete-pre-roles
grep -q 'connection problem, not an authentication result' <<<"$OUT" && [[ "$RC" == 1 && -f "$SB/repo/.env.pre-roles" ]] && ok "network failure reported as connection problem (not as rejection), file kept" || { bad "conn failure: rc=$RC"; grep -E 'FAIL' <<<"$OUT"; }
setup; ODD=stockwatch_admin rot "$NEW_PW" --since 2026-11-11T08:00:00Z --delete-pre-roles
[[ "$RC" == 1 && -f "$SB/repo/.env.pre-roles" ]] && grep -q 'old master credential not verified (unexpected result' <<<"$OUT" && ! grep -q 'still ACCEPTED' <<<"$OUT" && ok "unexpected psql output -> not reported as accepted or rejected, file kept" || bad "unexpected output: rc=$RC"
setup; rot "wrong-$NEW_PW" --since 2026-11-11T08:00:00Z
[[ "$RC" == 1 ]] && grep -q 'new master credential REJECTED' <<<"$OUT" && ok "wrong new password -> FAIL, exit 1" || bad "wrong new pw: rc=$RC"
no_secrets "wrong new password"
setup; STARTED=2026-11-11T08:05:00.000Z rot "$NEW_PW" --since 2026-11-11T08:00:00Z
[[ "$RC" == 1 ]] && grep -q 'restarted at' <<<"$OUT" && ok "app restarted after rotation -> FAIL" || bad "restart detection: rc=$RC"
setup; EVENT="" rot "$NEW_PW" --since 2026-11-11T08:00:00Z
grep -q '123456789012' <<<"$OUT" && bad "account id printed from AWS error" || ok "missing event -> FAIL; AWS error printed with account id masked"
setup; rot "$NEW_PW" --since "2026-11-11 08:00"
[[ "$RC" == 2 ]] && ok "non-UTC/malformed --since rejected (exit 2)" || bad "--since validation: rc=$RC"
setup; XFLAG=-x rot "$NEW_PW" --since 2026-11-11T08:00:00Z
no_secrets "run under bash -x"

echo "verify-imds-isolation.sh (mocked)"
imds() { OUT="$(env PATH="$SB/bin:$PATH" STUB_DIR="$SB" "$@" bash "$SB/repo/scripts/verify-imds-isolation.sh" 2>&1)"; RC=$?; }
setup; imds
[[ "$RC" == 0 ]] && grep -q 'CANNOT reach' <<<"$OUT" && ok "all probes blocked -> isolated, exit 0" || bad "blocked: rc=$RC"
setup; imds STUB_PROBE_stockwatch_backend="token=200 credential_path=200 role=r"
[[ "$RC" == 1 ]] && ok "one container reaches credentials -> exit 1" || bad "reachable: rc=$RC"
setup; imds STUB_PROBE_RUN="docker: Error response from daemon: pull access denied"
[[ "$RC" == 3 ]] && grep -q INCONCLUSIVE <<<"$OUT" && ok "failed probe -> INCONCLUSIVE, exit 3 (never reported as isolated)" || bad "probe failure: rc=$RC"
setup; imds STUB_PROBE_stockwatch_worker="node: not found"
[[ "$RC" == 3 ]] && ok "unrecognized in-container probe output -> exit 3" || bad "unrecognized output: rc=$RC"

echo; echo "Summary: ${PASS} passed, ${FAIL} failed"; [[ "$FAIL" -eq 0 ]]
