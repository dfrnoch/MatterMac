#!/bin/sh
# Development-only: create normal test users, a team, and channels on the local
# Docker test deployments using ephemeral HTTP for users and local mmctl for membership.
# Generated passwords are written ONLY to the git-ignored .local/ directory.
set -eu
# Explicitly disable inherited shell tracing before credentials are read.
set +x
cd "$(dirname "$0")/../../.."
COMPOSE="docker compose -f Tests/Integration/Server/compose.yaml"
mkdir -p .local && chmod 700 .local
ENV_FILE=.local/test-server.env
if [ ! -f "$ENV_FILE" ]; then
  umask 077
  gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }
  {
    echo "MM_TEST_ADMIN_PASSWORD=$(gen)Aa1!"
    echo "MM_TEST_ALICE_PASSWORD=$(gen)Aa1!"
    echo "MM_TEST_BOB_PASSWORD=$(gen)Aa1!"
    echo "MM_TEST_CAROL_PASSWORD=$(gen)Aa1!"
  } > "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"
set -a
. "./$ENV_FILE"
set +a
for svc in "$@"; do
  case "$svc" in mm11|mm11sub|mm10) ;; *) echo "Unknown local test service." >&2; exit 1 ;; esac
  mm() {
    $COMPOSE exec -T "$svc" mmctl --local "$@" 2>/dev/null || {
      echo "$svc: local provisioning command failed." >&2
      exit 1
    }
  }
  swift Tests/Integration/Server/BootstrapUsers.swift "$svc"
  teams=$(mm team list)
  if ! printf '%s\n' "$teams" | grep -Fxq qa; then
    mm team create --name qa --display-name "MatterMac QA" >/dev/null
  fi
  mm team users add qa mmadmin alice bob carol >/dev/null
  channels=$(mm channel list qa)
  if ! printf '%s\n' "$channels" | grep -Fxq interop; then
    mm channel create --team qa --name interop --display-name "Interop" >/dev/null
  fi
  if ! printf '%s\n' "$channels" | grep -Eq '^private-qa( \(private\))?$'; then
    mm channel create --team qa --name private-qa --display-name "Private QA" --private >/dev/null
  fi
  mm channel users add qa:interop alice bob carol >/dev/null
  mm channel users add qa:private-qa alice bob >/dev/null
  echo "$svc: users and channel memberships verified."
done
