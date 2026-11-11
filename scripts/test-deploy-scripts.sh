#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================================
# Behavioural tests for infrastructure/deployment/{deploy,rollback}.sh.
#
# Runs both scripts in a sandbox copy of the repository with a stub `docker`
# on PATH: no container, network, image or volume is touched and no real
# database is contacted. The stub records every invocation and simulates
# health results, so control flow (validation, target selection, automatic
# rollback, deployment-state files) is tested deterministically.
#
# Usage: scripts/test-deploy-scripts.sh   (from the repository root)
# ==========================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sw-deploy-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

SYD_HOST="stockwatch-primary-db.cns8kouwop3n.ap-southeast-2.rds.amazonaws.com"
MEL_HOST="stockwatch-dr-replica.abcdefghijkl.ap-southeast-4.rds.amazonaws.com"
SHA_OLD="1cc73a26a79e98d1a96735ca8c86caf09911eb8a"
SHA_NEW="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

url() { # url <user> <host> <ca-file>
  printf 'postgresql://%s:pw@%s:5432/stockwatch?schema=public&sslmode=require&sslaccept=strict&sslcert=%s' "$1" "$2" "$3"
}

# --- sandbox -------------------------------------------------------------------------------
setup() {
  rm -rf "${SANDBOX:?}/repo" "${SANDBOX:?}/bin" "${SANDBOX:?}/ca"
  mkdir -p "$SANDBOX/repo" "$SANDBOX/bin" "$SANDBOX/ca"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z infrastructure | tar --null -T - -cf -) | tar -xf - -C "$SANDBOX/repo"
  printf -- '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n' > "$SANDBOX/ca/ap-southeast-2-bundle.pem"
  printf -- '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n' > "$SANDBOX/ca/ap-southeast-4-bundle.pem"
  # Point the committed profiles at sandbox CA files.
  sed -i "s#^RDS_CA_BUNDLE_HOST_PATH=.*#RDS_CA_BUNDLE_HOST_PATH=$SANDBOX/ca/ap-southeast-2-bundle.pem#" "$SANDBOX/repo/infrastructure/deployment/targets/primary.env"
  sed -i "s#^RDS_CA_BUNDLE_HOST_PATH=.*#RDS_CA_BUNDLE_HOST_PATH=$SANDBOX/ca/ap-southeast-4-bundle.pem#" "$SANDBOX/repo/infrastructure/deployment/targets/melbourne.env"
  printf '%s\n' "$SHA_OLD" > "$SANDBOX/repo/infrastructure/deployment/.current_tag"
  write_env "$(url stockwatch_app "$SYD_HOST" ap-southeast-2-bundle.pem)" "$(url stockwatch_migrator "$SYD_HOST" ap-southeast-2-bundle.pem)"

  cat > "$SANDBOX/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Stub docker: logs calls; simulates health via STUB_* variables.
echo "docker $*" >> "$STUB_LOG"
case "$*" in
  *"stockwatch-backend wget"*)
    if [[ "${STUB_BACKEND_HEALTHY:-true}" == true || ( -n "${STUB_HEALTHY_TAG:-}" && "${IMAGE_TAG:-}" == "${STUB_HEALTHY_TAG}" ) ]]; then
      echo '{"status":"ok"}'
    else
      exit 1
    fi ;;
  *"inspect --format {{.State.Status}} stockwatch-worker"*) echo running ;;
  *"inspect"*"State.Health"*"stockwatch-worker"*) echo healthy ;;
  *"inspect"*"State.Health"*) echo healthy ;;
  *"inspect"*) echo running ;;
  *) : ;;
esac
exit 0
STUB
  chmod +x "$SANDBOX/bin/docker"
  : > "$SANDBOX/docker.log"
}

write_env() {
  cat > "$SANDBOX/repo/.env" <<EOF
NODE_ENV=production
DATABASE_URL="$1"
MIGRATION_DATABASE_URL="$2"
REDIS_PASSWORD=redis-test-password
EOF
}

run() { # run <script> [args...]  -> sets OUT, RC
  set +e
  OUT="$(cd "$SANDBOX/repo" && env PATH="$SANDBOX/bin:$PATH" STUB_LOG="$SANDBOX/docker.log" "${RUN_ENV[@]}" \
    bash "infrastructure/deployment/$1" "${@:2}" 2>&1)"
  RC=$?
  set -e
}
RUN_ENV=()

expect_rc() { # desc expected_rc pattern
  if [[ "$RC" == "$2" ]] && grep -qE -- "$3" <<<"$OUT"; then ok "$1"; else bad "$1 (rc=$RC)"; printf '%s\n' "$OUT" | tail -5 | sed 's/^/        /'; fi
}

echo "deploy.sh / rollback.sh behavioural tests (stub docker; sandbox: $SANDBOX)"

# --- deploy.sh ---------------------------------------------------------------------------
setup; RUN_ENV=(); run deploy.sh "$SHA_NEW"
expect_rc "deploy: primary target succeeds with separated users" 0 "Deployment successful: $SHA_NEW"
grep -q "Runtime user 'stockwatch_app' and migration user 'stockwatch_migrator' are separated" <<<"$OUT" && ok "deploy: reports runtime/migration user separation" || bad "deploy: separation message missing"
grep -q "source=$SANDBOX/ca/ap-southeast-2-bundle.pem,target=/app/packages/database/prisma/ap-southeast-2-bundle.pem" "$SANDBOX/docker.log" \
  && ok "deploy: migration container mounts the Sydney CA bundle" || bad "deploy: wrong CA mount for migrations"
grep -q -- "-e DATABASE_URL=postgresql://stockwatch_migrator" "$SANDBOX/docker.log" && ok "deploy: migrations run with MIGRATION_DATABASE_URL" || bad "deploy: migrations not using migrator URL"
[[ "$(cat "$SANDBOX/repo/infrastructure/deployment/.current_tag")" == "$SHA_NEW" && "$(cat "$SANDBOX/repo/infrastructure/deployment/.previous_tag")" == "$SHA_OLD" ]] \
  && ok "deploy: records current/previous tags" || bad "deploy: tag records wrong"
grep -q "up -d --remove-orphans backend worker frontend" "$SANDBOX/docker.log" && ok "deploy: starts app services" || bad "deploy: app services not started"
grep -qE "up -d (--[a-z-]+ )*postgres" "$SANDBOX/docker.log" && bad "deploy: started local postgres" || ok "deploy: never starts local postgres"

setup; RUN_ENV=(STOCKWATCH_TARGET=melbourne); run deploy.sh "$SHA_NEW"
expect_rc "deploy: melbourne target refused while placeholders remain" 1 "contains placeholders"
[[ ! -s "$SANDBOX/docker.log" ]] && ok "deploy: no docker call before validation fails" || bad "deploy: docker called despite invalid target"

setup; write_env "$(url stockwatch_app "$MEL_HOST" ap-southeast-4-bundle.pem)" "$(url stockwatch_migrator "$MEL_HOST" ap-southeast-4-bundle.pem)"
RUN_ENV=(STOCKWATCH_TARGET=melbourne RDS_EXPECTED_HOST="$MEL_HOST"); run deploy.sh "$SHA_NEW"
expect_rc "deploy: melbourne target with real endpoint override succeeds" 0 "Target: melbourne \(ap-southeast-4\)"
grep -q "target=/app/packages/database/prisma/ap-southeast-4-bundle.pem" "$SANDBOX/docker.log" && ok "deploy: melbourne migrations mount the Melbourne CA" || bad "deploy: melbourne CA not mounted"

setup; RUN_ENV=(STOCKWATCH_TARGET=melbourne RDS_EXPECTED_HOST="$MEL_HOST"); run deploy.sh "$SHA_NEW"
expect_rc "deploy: Sydney DATABASE_URL rejected for melbourne target" 1 "does not point to the expected RDS host"

setup; write_env "$(url stockwatch_app "$SYD_HOST" ap-southeast-4-bundle.pem)" "$(url stockwatch_migrator "$SYD_HOST" ap-southeast-2-bundle.pem)"
RUN_ENV=(); run deploy.sh "$SHA_NEW"
expect_rc "deploy: wrong-region CA in DATABASE_URL rejected" 1 "must reference the regional CA bundle"

setup; RUN_ENV=(RDS_CA_BUNDLE_HOST_PATH="$SANDBOX/ca/missing/ap-southeast-2-bundle.pem"); run deploy.sh "$SHA_NEW"
expect_rc "deploy: missing CA bundle rejected" 1 "CA bundle is missing"

setup; RUN_ENV=(RDS_EXPECTED_HOST="stockwatch-primary-db.x.ap-southeast-4.rds.amazonaws.com"); run deploy.sh "$SHA_NEW"
expect_rc "deploy: endpoint/region mismatch rejected" 1 "not in region ap-southeast-2"

setup; RUN_ENV=(STOCKWATCH_TARGET=../../etc); run deploy.sh "$SHA_NEW"
expect_rc "deploy: path-like target name rejected" 1 "Unknown deployment target"

setup; RUN_ENV=(); run deploy.sh "not-a-sha"
expect_rc "deploy: invalid image tag rejected" 1 "valid Git commit SHA"

setup; write_env "$(url stockwatch_admin "$SYD_HOST" ap-southeast-2-bundle.pem)" ""
sed -i '/^MIGRATION_DATABASE_URL=/d' "$SANDBOX/repo/.env"; RUN_ENV=(); run deploy.sh "$SHA_NEW"
expect_rc "deploy: falls back to DATABASE_URL for migrations (warns)" 0 "share database user 'stockwatch_admin'"

# Automatic rollback: new release unhealthy, previous verified tag healthy.
setup; RUN_ENV=(STUB_BACKEND_HEALTHY=false STUB_HEALTHY_TAG="$SHA_OLD"); run deploy.sh "$SHA_NEW"
expect_rc "deploy: failed health triggers automatic rollback" 1 "Automatic rollback completed"
[[ "$(cat "$SANDBOX/repo/infrastructure/deployment/.current_tag")" == "$SHA_OLD" ]] \
  && ok "deploy: failed release not recorded as current" || bad "deploy: .current_tag changed after failure"
grep -qE '\\n' "$SANDBOX/repo/infrastructure/deployment/.current_tag" && bad "rollback: literal \\n in tag file" || ok "rollback: tag file free of literal \\n"

# --- rollback.sh -------------------------------------------------------------------------
setup; printf '%s\n' "$SHA_NEW" > "$SANDBOX/repo/infrastructure/deployment/.current_tag"
printf '%s\n' "$SHA_OLD" > "$SANDBOX/repo/infrastructure/deployment/.previous_tag"; RUN_ENV=(); run rollback.sh
expect_rc "rollback: restores previous tag" 0 "Rollback successfully completed: $SHA_OLD"
[[ "$(cat "$SANDBOX/repo/infrastructure/deployment/.current_tag")" == "$SHA_OLD" && "$(cat "$SANDBOX/repo/infrastructure/deployment/.previous_tag")" == "$SHA_NEW" ]] \
  && ok "rollback: swaps current/previous tags" || bad "rollback: tag records wrong"

setup; RUN_ENV=(STOCKWATCH_TARGET=melbourne); run rollback.sh "$SHA_OLD"
expect_rc "rollback: melbourne placeholder target refused" 1 "contains placeholders"

setup; rm "$SANDBOX/repo/.env"; RUN_ENV=(); run rollback.sh "$SHA_OLD"
expect_rc "rollback: missing .env refused" 1 ".env file is missing"

setup; write_env "$(url stockwatch_app "evil.example.com" ap-southeast-2-bundle.pem)" "$(url stockwatch_migrator "$SYD_HOST" ap-southeast-2-bundle.pem)"
RUN_ENV=(); run rollback.sh "$SHA_OLD"
expect_rc "rollback: unexpected database host refused" 1 "does not point to the expected RDS host"

# --- external runtime directory (CI deploys from a dedicated clone) -----------------------
setup; RT="$SANDBOX/runtime"; mkdir -p "$RT/state"; mv "$SANDBOX/repo/.env" "$RT/.env"; printf '%s\n' "$SHA_OLD" > "$RT/state/.current_tag"
rm -f "$SANDBOX/repo/infrastructure/deployment/.current_tag"
RUN_ENV=(STOCKWATCH_ENV_FILE="$RT/.env" STOCKWATCH_STATE_DIR="$RT/state"); run deploy.sh "$SHA_NEW"
expect_rc "deploy: external STOCKWATCH_ENV_FILE / STOCKWATCH_STATE_DIR" 0 "Deployment successful: $SHA_NEW"
[[ "$(cat "$RT/state/.current_tag")" == "$SHA_NEW" && "$(cat "$RT/state/.previous_tag")" == "$SHA_OLD" && ! -e "$SANDBOX/repo/infrastructure/deployment/.current_tag" ]] \
  && ok "deploy: tag history written to the external state dir only" || bad "deploy: state dir not used"
grep -q -- "--project-name docker --env-file $RT/.env" "$SANDBOX/docker.log" && ok "deploy: compose project pinned to 'docker' with external env file" || bad "deploy: project/env-file not pinned"
setup; RUN_ENV=(STOCKWATCH_STATE_DIR="$SANDBOX/does-not-exist"); run deploy.sh "$SHA_NEW"
expect_rc "deploy: missing state dir refused" 1 "state directory .* does not exist"
setup; RT="$SANDBOX/runtime"; mkdir -p "$RT/state"; mv "$SANDBOX/repo/.env" "$RT/.env"
printf '%s\n' "$SHA_NEW" > "$RT/state/.current_tag"; printf '%s\n' "$SHA_OLD" > "$RT/state/.previous_tag"
RUN_ENV=(STOCKWATCH_ENV_FILE="$RT/.env" STOCKWATCH_STATE_DIR="$RT/state"); run rollback.sh
expect_rc "rollback: external env/state dir" 0 "Rollback successfully completed: $SHA_OLD"

echo
echo "Summary: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
