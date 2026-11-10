#!/usr/bin/env bash
# shellcheck shell=bash
# Shared by deploy.sh and rollback.sh: resolves the deployment target (region,
# expected RDS endpoint, regional CA bundle) and validates database URLs.
#
# Target selection: STOCKWATCH_TARGET=<name> loads targets/<name>.env (default: primary).
# Explicit environment variables override profile values (e.g. RDS_EXPECTED_HOST=...).
# The profile is non-secret; credentials stay in .env.

stockwatch_load_target() {
  local deploy_dir="$1"
  local target="${STOCKWATCH_TARGET:-primary}"
  local profile="${deploy_dir}/targets/${target}.env"

  if [[ ! "$target" =~ ^[a-z0-9-]+$ || ! -f "$profile" ]]; then
    echo "ERROR: Unknown deployment target '${target}' (expected ${deploy_dir}/targets/<name>.env)." >&2
    return 1
  fi

  local key value
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ "$key" =~ ^(STOCKWATCH_REGION|RDS_EXPECTED_HOST|RDS_DATABASE_NAME|RDS_CA_BUNDLE_FILE|RDS_CA_BUNDLE_HOST_PATH)$ ]] || {
      echo "ERROR: Unexpected key '${key}' in ${profile}." >&2
      return 1
    }
    # Environment overrides profile.
    if [[ -z "${!key:-}" ]]; then
      printf -v "$key" '%s' "$value"
    fi
    export "${key?}"
  done < "$profile"

  export STOCKWATCH_TARGET="$target"
  export RDS_CA_CONTAINER_PATH="/app/packages/database/prisma/${RDS_CA_BUNDLE_FILE}"
}

stockwatch_validate_target() {
  local region="$STOCKWATCH_REGION" host="$RDS_EXPECTED_HOST" ca_file="$RDS_CA_BUNDLE_FILE"

  if [[ "$host$ca_file$RDS_CA_BUNDLE_HOST_PATH$region" == *"<"* ]]; then
    echo "ERROR: Target '${STOCKWATCH_TARGET}' still contains placeholders; it is not provisioned." >&2
    return 1
  fi
  if [[ ! "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]]; then
    echo "ERROR: Invalid region '${region}'." >&2
    return 1
  fi
  if [[ "$host" != *".${region}.rds.amazonaws.com" ]]; then
    echo "ERROR: RDS endpoint is not in region ${region}." >&2
    return 1
  fi
  if [[ "$ca_file" != "${region}-bundle.pem" ]]; then
    echo "ERROR: CA bundle '${ca_file}' does not match region ${region}." >&2
    return 1
  fi
  if [[ "$(basename "$RDS_CA_BUNDLE_HOST_PATH")" != "$ca_file" || ! -s "$RDS_CA_BUNDLE_HOST_PATH" ]]; then
    echo "ERROR: Regional RDS CA bundle is missing: ${RDS_CA_BUNDLE_HOST_PATH}" >&2
    return 1
  fi
  if ! grep -q 'BEGIN CERTIFICATE' "$RDS_CA_BUNDLE_HOST_PATH"; then
    echo "ERROR: ${RDS_CA_BUNDLE_HOST_PATH} is not a PEM certificate bundle." >&2
    return 1
  fi
  echo "Target: ${STOCKWATCH_TARGET} (${region}); expected database endpoint and CA bundle verified."
}

# Validates DATABASE_URL and MIGRATION_DATABASE_URL against the target. Prints no secrets.
stockwatch_validate_database_urls() {
  python3 - <<'PY'
import os
import sys
from urllib.parse import urlsplit, parse_qs

expected_host = os.environ["RDS_EXPECTED_HOST"]
expected_db = os.environ.get("RDS_DATABASE_NAME", "stockwatch")
ca_file = os.environ["RDS_CA_BUNDLE_FILE"]

for name in ("DATABASE_URL", "MIGRATION_DATABASE_URL"):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"ERROR: {name} is missing.")
    url = urlsplit(value)
    params = parse_qs(url.query)

    if url.hostname != expected_host:
        sys.exit(f"ERROR: {name} does not point to the expected RDS host for this target.")
    if url.port != 5432 or url.path.rstrip("/") != f"/{expected_db}":
        sys.exit(f"ERROR: Unexpected RDS port or database name in {name}.")
    if params.get("sslmode", [""])[0] != "require":
        sys.exit(f"ERROR: sslmode=require is required in {name}.")
    if params.get("sslaccept", [""])[0] != "strict":
        sys.exit(f"ERROR: sslaccept=strict is required in {name}.")
    if params.get("sslcert", [""])[0] != ca_file:
        sys.exit(f"ERROR: {name} must reference the regional CA bundle ({ca_file}).")

runtime_user = urlsplit(os.environ["DATABASE_URL"]).username
migration_user = urlsplit(os.environ["MIGRATION_DATABASE_URL"]).username
if runtime_user == migration_user:
    print(f"WARNING: runtime and migrations share database user '{runtime_user}' (least-privilege split not configured).")
else:
    print(f"Runtime user '{runtime_user}' and migration user '{migration_user}' are separated.")
print("RDS endpoint and strict TLS configuration validated.")
PY
}
