#!/bin/bash
# Reproduces the Cloudron runtime locally: read-only root filesystem, only
# /tmp, /run and /app/data writable, addon environment injected.
#
#   ./test/local-run.sh [image]           run the checks and clean up
#   KEEP=1 ./test/local-run.sh            leave the stack running afterwards
set -euo pipefail

IMAGE="${1:-cloudron-litellm:dev}"
NET=litellm-test-net
PG=litellm-test-pg
REDIS=litellm-test-redis
APP=litellm-test-app
VOL=litellm-test-data
PORT=14000

remove_stack() {
    docker rm -f "${APP}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
    docker volume rm "${VOL}" >/dev/null 2>&1 || true
    docker network rm "${NET}" >/dev/null 2>&1 || true
}

# KEEP=1 leaves the stack running when the script finishes, but a run always
# starts from a clean slate.
cleanup() {
    if [[ "${KEEP:-}" == "1" ]]; then
        echo "==> KEEP=1, leaving stack up on :${PORT}"
        return
    fi
    remove_stack
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

remove_stack
docker network create "${NET}" >/dev/null
docker volume create "${VOL}" >/dev/null

echo "==> Starting postgres and redis"
docker run -d --name "${PG}" --network "${NET}" \
    -e POSTGRES_USER=litellm -e POSTGRES_PASSWORD=litellm -e POSTGRES_DB=litellm \
    postgres:16-alpine >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" \
    redis:7-alpine redis-server --requirepass testpassword >/dev/null

for _ in $(seq 1 180); do
    docker exec "${PG}" pg_isready -U litellm >/dev/null 2>&1 && break
    sleep 1
done
docker exec "${PG}" pg_isready -U litellm >/dev/null 2>&1 || fail "postgres did not become ready"

start_app() {
    docker run -d --name "${APP}" --network "${NET}" \
        --read-only --tmpfs /tmp --tmpfs /run \
        -v "${VOL}:/app/data" \
        -p "127.0.0.1:${PORT}:4000" \
        -e "CLOUDRON_POSTGRESQL_URL=postgres://litellm:litellm@${PG}:5432/litellm" \
        -e "CLOUDRON_REDIS_HOST=${REDIS}" \
        -e CLOUDRON_REDIS_PORT=6379 \
        -e CLOUDRON_REDIS_PASSWORD=testpassword \
        -e "CLOUDRON_APP_ORIGIN=http://localhost:${PORT}" \
        -e CLOUDRON_APP_DOMAIN=localhost \
        "$@" "${IMAGE}" >/dev/null
}

wait_healthy() {
    local i
    for i in $(seq 1 600); do
        if curl -sf "http://127.0.0.1:${PORT}/health/liveliness" >/dev/null 2>&1; then
            echo "==> healthy after ${i}s"
            return 0
        fi
        docker inspect -f '{{.State.Running}}' "${APP}" 2>/dev/null | grep -q true \
            || { docker logs "${APP}"; fail "container exited"; }
        sleep 1
    done
    docker logs "${APP}" | tail -60
    fail "not healthy within 600s"
}

echo "==> [1/7] first boot on a read-only root filesystem"
start_app
wait_healthy

MASTER_KEY="$(docker exec "${APP}" sed -n 's/^LITELLM_MASTER_KEY=//p' /app/data/env)"
SALT_KEY="$(docker exec "${APP}" sed -n 's/^LITELLM_SALT_KEY=//p' /app/data/env)"
[[ "${MASTER_KEY}" == sk-* ]] || fail "master key not generated (got '${MASTER_KEY}')"
[[ -n "${SALT_KEY}" ]] || fail "salt key not generated"
echo "==> master key generated"

echo "==> [2/7] authenticated API responds"
code="$(curl -s -o /tmp/models.json -w '%{http_code}' \
    -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${PORT}/models")"
[[ "${code}" == "200" ]] || { cat /tmp/models.json; fail "/models returned ${code}"; }

echo "==> [3/7] unauthenticated API is rejected"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/models")"
[[ "${code}" == "401" || "${code}" == "403" ]] || fail "/models without a key returned ${code}"

echo "==> [4/7] database schema was applied"
tables="$(docker exec "${PG}" psql -U litellm -d litellm -tAc \
    "select count(*) from information_schema.tables where table_schema='public' and table_name like 'LiteLLM%'")"
[[ "${tables}" -gt 10 ]] || fail "expected LiteLLM tables in the database, found ${tables}"
echo "==> ${tables} LiteLLM tables present"

echo "==> [5/7] the admin UI is served"
code="$(curl -s -o /tmp/ui.html -w '%{http_code}' -L "http://127.0.0.1:${PORT}/ui")"
[[ "${code}" == "200" ]] || fail "/ui returned ${code}"
grep -qi '<div id="__next"\|_next/static' /tmp/ui.html || fail "/ui did not return the dashboard HTML"

echo "==> [6/7] restart keeps the generated keys"
docker rm -f "${APP}" >/dev/null
start_app
wait_healthy
MASTER_KEY2="$(docker exec "${APP}" sed -n 's/^LITELLM_MASTER_KEY=//p' /app/data/env)"
SALT_KEY2="$(docker exec "${APP}" sed -n 's/^LITELLM_SALT_KEY=//p' /app/data/env)"
[[ "${MASTER_KEY}" == "${MASTER_KEY2}" ]] || fail "master key changed across restart"
[[ "${SALT_KEY}" == "${SALT_KEY2}" ]] || fail "salt key changed across restart"
docker logs "${APP}" 2>&1 | grep -q "Database schema already applied" \
    || fail "restart re-ran the migrations instead of skipping them"
echo "==> restart skipped the migrations"

echo "==> [7/7] SSO wiring points at the Cloudron provider"
docker rm -f "${APP}" >/dev/null
start_app \
    -e CLOUDRON_OIDC_CLIENT_ID=testclient \
    -e CLOUDRON_OIDC_CLIENT_SECRET=testsecret \
    -e CLOUDRON_OIDC_AUTH_ENDPOINT=https://my.example.com/openid/auth \
    -e CLOUDRON_OIDC_TOKEN_ENDPOINT=https://my.example.com/openid/token \
    -e CLOUDRON_OIDC_PROFILE_ENDPOINT=https://my.example.com/openid/me \
    -e CLOUDRON_OIDC_PROVIDER_NAME=Cloudron
wait_healthy
location="$(curl -s -o /dev/null -w '%{redirect_url}' "http://127.0.0.1:${PORT}/sso/key/generate")"
grep -q '^https://my.example.com/openid/auth' <<<"${location}" \
    || fail "SSO did not redirect to the Cloudron provider (got '${location}')"
grep -q 'redirect_uri=http%3A%2F%2Flocalhost%3A'"${PORT}"'%2Fsso%2Fcallback' <<<"${location}" \
    || fail "SSO redirect_uri is not \$ORIGIN/sso/callback (got '${location}')"
echo "==> SSO redirects to ${location%%\?*}"

echo
echo "ALL CHECKS PASSED"
