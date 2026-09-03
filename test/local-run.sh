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
    # docker rm returns before the container is gone, so the volume it holds
    # can still be busy; a leftover volume would silently make the next run
    # start against a used /app/data.
    local i
    for i in $(seq 1 30); do
        docker volume inspect "${VOL}" >/dev/null 2>&1 || break
        docker volume rm "${VOL}" >/dev/null 2>&1 && break
        [[ ${i} -eq 30 ]] && { echo "could not remove volume ${VOL}" >&2; exit 1; }
        sleep 1
    done
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
    postgres:14-alpine >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" \
    redis:7-alpine redis-server --requirepass testpassword >/dev/null

for i in $(seq 1 180); do
    docker exec "${PG}" pg_isready -U litellm >/dev/null 2>&1 && break
    [[ ${i} -eq 180 ]] && fail "postgres did not become ready"
    sleep 1
done

start_app() {
    docker run -d --name "${APP}" --network "${NET}" \
        --read-only --tmpfs /tmp --tmpfs /run \
        -v "${VOL}:/app/data" \
        --memory=3072m --memory-swap=3072m \
        -p "127.0.0.1:${PORT}:4000" \
        -e "CLOUDRON_POSTGRESQL_URL=postgres://litellm:litellm@${PG}:5432/litellm" \
        -e "CLOUDRON_REDIS_HOST=${REDIS}" \
        -e CLOUDRON_REDIS_PORT=6379 \
        -e CLOUDRON_REDIS_PASSWORD=testpassword \
        -e "CLOUDRON_APP_ORIGIN=http://localhost:${PORT}" \
        -e CLOUDRON_APP_DOMAIN=localhost \
        "$@" "${IMAGE}" >/dev/null
}

# /health/readiness, unlike liveliness, reports the database as well.
wait_healthy() {
    local i
    for i in $(seq 1 600); do
        if curl -sf "http://127.0.0.1:${PORT}/health/readiness" >/dev/null 2>&1; then
            echo "==> healthy after ${i}s"
            return 0
        fi
        [[ "$(docker inspect -f '{{.State.Running}}' "${APP}" 2>/dev/null)" == true ]] \
            || { docker logs "${APP}"; fail "container exited"; }
        sleep 1
    done
    docker logs "${APP}" | tail -60
    fail "not healthy within 600s"
}

echo "==> [1/10] first boot on a read-only root filesystem"
start_app
wait_healthy

secret() { docker exec "${APP}" sed -n "s/^$1=//p" /app/data/env; }
secret_count() { docker exec "${APP}" grep -c "^$1=" /app/data/env; }

MASTER_KEY="$(secret LITELLM_MASTER_KEY)"
SALT_KEY="$(secret LITELLM_SALT_KEY)"
[[ "${MASTER_KEY}" == sk-* ]] || fail "master key not generated (got '${MASTER_KEY}')"
[[ -n "${SALT_KEY}" ]] || fail "salt key not generated"
echo "==> master key generated"

echo "==> [2/10] authenticated API responds"
code="$(curl -s -o /tmp/models.json -w '%{http_code}' \
    -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${PORT}/models")"
[[ "${code}" == "200" ]] || { cat /tmp/models.json; fail "/models returned ${code}"; }

echo "==> [3/10] unauthenticated API is rejected"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/models")"
[[ "${code}" == "401" || "${code}" == "403" ]] || fail "/models without a key returned ${code}"

echo "==> [4/10] database schema was applied"
tables="$(docker exec "${PG}" psql -U litellm -d litellm -tAc \
    "select count(*) from information_schema.tables where table_schema='public' and table_name like 'LiteLLM%'")"
[[ "${tables}" -gt 10 ]] || fail "expected LiteLLM tables in the database, found ${tables}"
echo "==> ${tables} LiteLLM tables present"

echo "==> [5/10] the admin UI is served"
code="$(curl -s -o /tmp/ui.html -w '%{http_code}' -L "http://127.0.0.1:${PORT}/ui")"
[[ "${code}" == "200" ]] || fail "/ui returned ${code}"
grep -qi '<div id="__next"\|_next/static' /tmp/ui.html || fail "/ui did not return the dashboard HTML"
code="$(curl -s -o /dev/null -w '%{http_code}' -L "http://127.0.0.1:${PORT}/ui/login")"
[[ "${code}" == "200" ]] || fail "/ui/login returned ${code}"

code="$(curl -s -o /tmp/cache.json -w '%{http_code}' \
    -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${PORT}/cache/ping")"
[[ "${code}" == "200" ]] || { cat /tmp/cache.json; fail "the redis cache is not healthy (${code})"; }
code="$(curl -s -o /dev/null -w '%{http_code}' -L "http://127.0.0.1:${PORT}/fallback/login")"
[[ "${code}" == "200" ]] || fail "the master-key fallback login returned ${code}"
[[ "$(docker exec "${APP}" sh -c 'ps -o user= -p 1' | tr -d ' ')" == "cloudron" ]] \
    || fail "the proxy is running as root"
[[ "$(docker exec "${APP}" stat -c '%U:%a' /app/data/env)" == "cloudron:600" ]] \
    || fail "/app/data/env has the wrong owner or mode"
[[ -z "$(docker exec "${APP}" sh -c 'ls /app/code/venv/lib/python3.12/site-packages | grep litellm_enterprise')" ]] \
    || fail "the enterprise-licensed package is present in a published image"

echo "==> [6/10] restart keeps the generated keys"
docker rm -f "${APP}" >/dev/null
start_app
wait_healthy
MASTER_KEY2="$(secret LITELLM_MASTER_KEY)"
SALT_KEY2="$(secret LITELLM_SALT_KEY)"
[[ "${MASTER_KEY}" == "${MASTER_KEY2}" ]] || fail "master key changed across restart"
[[ "${SALT_KEY}" == "${SALT_KEY2}" ]] || fail "salt key changed across restart"
[[ "$(secret_count LITELLM_SALT_KEY)" == "1" ]] || fail "a second salt key was appended"
docker logs "${APP}" > /tmp/applog 2>&1
grep -q "Database schema already applied" /tmp/applog \
    || fail "restart re-ran the migrations instead of skipping them"
echo "==> restart skipped the migrations"

echo "==> [7/10] a regenerated salt key is refused while the database holds credentials"
docker exec "${APP}" sh -c 'grep -v "^LITELLM_SALT_KEY=" /app/data/env > /app/data/e && mv /app/data/e /app/data/env'
docker exec -i "${PG}" psql -U litellm -d litellm -q >/dev/null <<'SQL'
insert into "LiteLLM_ProxyModelTable" (model_id, model_name, litellm_params, model_info, created_by, updated_by)
values ('probe', 'probe', '{}', '{}', 'test', 'test');
SQL
docker restart "${APP}" >/dev/null
for i in $(seq 1 60); do
    [[ "$(docker inspect -f '{{.State.Running}}' "${APP}")" == false ]] && break
    [[ ${i} -eq 60 ]] && fail "the app started and generated a new salt key over existing credentials"
    sleep 1
done
docker logs "${APP}" > /tmp/applog 2>&1
grep -q "LITELLM_SALT_KEY is missing" /tmp/applog || fail "no explanation was logged"
docker exec -i "${PG}" psql -U litellm -d litellm -q >/dev/null <<'SQL'
delete from "LiteLLM_ProxyModelTable" where model_id = 'probe';
SQL
echo "==> the app refused to boot rather than re-key"

echo "==> [8/10] a key appended after a line with no trailing newline is not glued onto it"
# The app is stopped by the previous check, so the volume is edited from a
# throwaway container: the env file is left ending in someone else's key with
# no trailing newline, which is what the appended salt could be glued onto.
docker run --rm -v "${VOL}:/app/data" --entrypoint sh "${IMAGE}" -c \
    'printf "%s\nOPENAI_API_KEY=sk-test" "$(cat /app/data/env)" > /app/data/e \
     && mv /app/data/e /app/data/env && chown cloudron:cloudron /app/data/env'
docker start "${APP}" >/dev/null
wait_healthy
[[ "$(secret_count LITELLM_SALT_KEY)" == "1" ]] || fail "the salt key was appended onto the previous line"
[[ "$(secret OPENAI_API_KEY)" == "sk-test" ]] || fail "the previous line was corrupted"
[[ "$(secret LITELLM_MASTER_KEY)" == "${MASTER_KEY}" ]] || fail "master key changed"

echo "==> [9/10] a new LiteLLM version re-runs the migrations on the existing data"
docker rm -f "${APP}" >/dev/null
start_app -e LITELLM_VERSION=99.0.0-next
wait_healthy
docker logs "${APP}" > /tmp/applog 2>&1
grep -q "Applying database schema" /tmp/applog \
    || fail "a changed LiteLLM version did not re-run the migrations"
[[ "$(docker exec "${APP}" cat /app/data/.schema-version)" == "99.0.0-next" ]] \
    || fail "the schema marker was not rewritten, so every later boot would re-migrate"
echo "==> migrations re-ran and the marker was rewritten"

echo "==> [10/10] SSO wiring points at the Cloudron provider"
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
