#!/bin/bash
set -euo pipefail

RUN_DIR=/run/litellm
DATA_DIR=/app/data
ENV_FILE="${DATA_DIR}/env"
CONFIG_FILE="${DATA_DIR}/config.yaml"
SCHEMA_MARKER="${DATA_DIR}/.schema-version"
PORT=4000

: "${CLOUDRON_POSTGRESQL_URL:?is required — is the postgresql addon enabled?}"
: "${CLOUDRON_REDIS_HOST:?is required — is the redis addon enabled?}"
: "${CLOUDRON_REDIS_PORT:?is required — is the redis addon enabled?}"
: "${CLOUDRON_REDIS_PASSWORD:?is required — is the redis addon enabled?}"
: "${CLOUDRON_APP_ORIGIN:?is required}"

# --- 1. the only work that needs root -------------------------------------
# Cloudron does not preserve ownership under /app/data, so it is claimed for
# the app user here. Everything after this runs unprivileged: the env file
# below is user-editable, and evaluating it as root would turn any write to
# it — including one made by the proxy itself — into root in the container.
if [[ "$(id -u)" -eq 0 ]]; then
    echo "==> Starting LiteLLM"
    mkdir -p "${RUN_DIR}/.cache" "${RUN_DIR}/migrations" "${DATA_DIR}"
    chown -R cloudron:cloudron "${RUN_DIR}" "${DATA_DIR}"
    exec gosu cloudron:cloudron "$0" "$@"
fi

mkdir -p "${RUN_DIR}/.cache" "${RUN_DIR}/migrations"

# The version baked into the image. Captured before the user's env file is
# sourced, so that setting LITELLM_VERSION there cannot suppress migrations.
IMAGE_LITELLM_VERSION="${LITELLM_VERSION}"

# The URL is passed in rather than read from a global: the secret guard below
# must always ask the addon's database, while the schema check must ask
# whichever database the proxy will actually use.
db() { psql "$1" -tAc "$2"; }

# --- 2. first run: templates and secrets ----------------------------------
[[ -s "${CONFIG_FILE}" ]] || { cp /app/code/config.yaml.template "${CONFIG_FILE}"; chmod 600 "${CONFIG_FILE}"; }
[[ -s "${ENV_FILE}" ]] || cp /app/code/env.template "${ENV_FILE}"

# openssl failing inside a command substitution does not fail the script — the
# status is discarded — so an empty or short key would be written once and then
# match the guard below forever.
random_hex() {
    local bytes="$1" value
    value="$(openssl rand -hex "${bytes}")" || return 1
    [[ ${#value} -eq $(( bytes * 2 )) ]] || return 1
    printf '%s' "${value}"
}

append_secret() {
    local name="$1" value="$2"
    grep -qE "^${name}=" "${ENV_FILE}" && return 0
    printf '%s=%s\n' "${name}" "${value}" >> "${ENV_FILE}"
}

# LITELLM_SALT_KEY encrypts the provider credentials stored in the database.
# It is generated exactly once: a second one makes those credentials
# undecryptable, so the lock keeps two starts from both appending, and the
# check below refuses to invent a new one for a database that already holds
# credentials — the case where the env file was deleted but the data was not.
exec 9>"${DATA_DIR}/.env.lock"
flock -w 60 9 || { echo "ERROR: another instance is holding ${DATA_DIR}/.env.lock" >&2; exit 1; }

if ! grep -qE '^LITELLM_SALT_KEY=' "${ENV_FILE}"; then
    # A missing salt key means either a first install or a lost env file, and
    # the difference is only visible in the database. Answering that question
    # requires the database to actually answer: treating "cannot connect" as
    # "no credentials" would mint a new key over an existing installation,
    # which is the exact accident this guard exists to prevent.
    for attempt in $(seq 1 30); do
        db "${CLOUDRON_POSTGRESQL_URL}" 'select 1' >/dev/null 2>&1 && break
        if [[ "${attempt}" -eq 30 ]]; then
            echo "ERROR: no LITELLM_SALT_KEY in /app/data/env and the database cannot be" >&2
            echo "reached, so it is not safe to generate one. Refusing to start." >&2
            exit 1
        fi
        sleep 2
    done

    # Every table whose rows are encrypted with the salt key. Each is probed
    # separately because on a first install none of them exist yet.
    for table in LiteLLM_CredentialsTable LiteLLM_ProxyModelTable LiteLLM_MCPServerTable; do
        if [[ -n "$(db "${CLOUDRON_POSTGRESQL_URL}" "select 1 from \"${table}\" limit 1" 2>/dev/null)" ]]; then
            echo "ERROR: the database holds encrypted credentials but LITELLM_SALT_KEY is missing" >&2
            echo "from /app/data/env. Restore that file from a backup — generating a new key would" >&2
            echo "make those credentials permanently unreadable." >&2
            exit 1
        fi
    done
fi

# Without a trailing newline the appends would glue the key onto the last
# line, hiding it from the grep above and regenerating it on every boot.
[[ -z "$(tail -c1 "${ENV_FILE}")" ]] || printf '\n' >> "${ENV_FILE}"

# Generated into variables first: a command substitution that fails inside an
# argument has its status discarded, so `append_secret NAME "$(...)"` would
# write an empty key and carry on. A plain assignment propagates the failure.
gen_failed() { echo "ERROR: could not generate a random key — openssl rand failed" >&2; exit 1; }
master_key="sk-$(random_hex 24)" || gen_failed
salt_key="$(random_hex 32)" || gen_failed
[[ -n "${master_key#sk-}" && -n "${salt_key}" ]] || gen_failed

append_secret LITELLM_MASTER_KEY "${master_key}"
append_secret LITELLM_SALT_KEY "${salt_key}"
chmod 600 "${ENV_FILE}"

exec 9>&-

# --- 3. platform-derived environment --------------------------------------
# The user's env file is sourced last, so anything set there wins.
export DATABASE_URL="${CLOUDRON_POSTGRESQL_URL}"
export PROXY_BASE_URL="${CLOUDRON_APP_ORIGIN}"
export LITELLM_MODE=PRODUCTION
export STORE_MODEL_IN_DB=True
export DISABLE_SCHEMA_UPDATE=True
export HOME="${RUN_DIR}"
export XDG_CACHE_HOME="${RUN_DIR}/.cache"
export TMPDIR=/tmp
# LiteLLM's migration package lives in the read-only image, so it is pointed
# at a writable copy — upstream provides this variable for exactly that. It
# belongs in /run: it is rebuilt per boot and must never enter a backup.
export LITELLM_MIGRATION_DIR="${RUN_DIR}/migrations"

export REDIS_HOST="${CLOUDRON_REDIS_HOST}"
export REDIS_PORT="${CLOUDRON_REDIS_PORT}"
export REDIS_PASSWORD="${CLOUDRON_REDIS_PASSWORD}"

# Cloudron SSO -> LiteLLM generic OIDC. Absent when the app is installed
# without SSO, in which case the master key is the only admin login. A
# partially populated set disables SSO rather than refusing to boot: losing
# the UI login is recoverable, an API gateway that will not start is not.
if [[ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]]; then
    if [[ -n "${CLOUDRON_OIDC_CLIENT_SECRET:-}" && -n "${CLOUDRON_OIDC_AUTH_ENDPOINT:-}" \
       && -n "${CLOUDRON_OIDC_TOKEN_ENDPOINT:-}" && -n "${CLOUDRON_OIDC_PROFILE_ENDPOINT:-}" ]]; then
        echo "==> Cloudron SSO detected, enabling OIDC login"
        export GENERIC_CLIENT_ID="${CLOUDRON_OIDC_CLIENT_ID}"
        export GENERIC_CLIENT_SECRET="${CLOUDRON_OIDC_CLIENT_SECRET}"
        export GENERIC_AUTHORIZATION_ENDPOINT="${CLOUDRON_OIDC_AUTH_ENDPOINT}"
        export GENERIC_TOKEN_ENDPOINT="${CLOUDRON_OIDC_TOKEN_ENDPOINT}"
        export GENERIC_USERINFO_ENDPOINT="${CLOUDRON_OIDC_PROFILE_ENDPOINT}"
        export GENERIC_SCOPE="openid profile email"
        export GENERIC_USER_ID_ATTRIBUTE=sub
        export GENERIC_USER_EMAIL_ATTRIBUTE=email
        export GENERIC_USER_DISPLAY_NAME_ATTRIBUTE=name
    else
        echo "==> Cloudron SSO is incomplete, leaving it off — sign in with the master key" >&2
    fi
fi

# An unset variable referenced in the user's file would otherwise abort the
# shell before the message below could name the file.
set -o allexport +u
# shellcheck disable=SC1090
source "${ENV_FILE}" || {
    echo "ERROR: /app/data/env is not valid shell. Quote values containing spaces or \$." >&2
    exit 1
}
set +o allexport -u

# --- 4. database schema ---------------------------------------------------
# Migrations are needed on a first install and after an update, not on an
# ordinary restart, which they would otherwise slow by minutes. The marker
# alone is not enough: it describes the image, so it still matches when the
# database beneath it was replaced or restored empty.
# Whether the tables exist, not whether they hold rows: a freshly migrated
# database is empty.
schema_present() {
    [[ "$(db "${DATABASE_URL}" "select 1 from information_schema.tables \
        where table_schema = 'public' and table_name = 'LiteLLM_UserTable'" 2>/dev/null)" == "1" ]]
}

if [[ "$(cat "${SCHEMA_MARKER}" 2>/dev/null || true)" == "${IMAGE_LITELLM_VERSION}" ]] && schema_present; then
    echo "==> Database schema already applied for LiteLLM ${IMAGE_LITELLM_VERSION}"
else
    echo "==> Applying database schema for LiteLLM ${IMAGE_LITELLM_VERSION}"
    # Run in the background and forward SIGTERM: until the exec below, this
    # script is PID 1, which ignores signals with a default disposition. A
    # stop during a migration would become a SIGKILL, leaving a half-applied
    # migration that every later boot refuses to move past.
    # The trap is installed first: between starting the child and installing
    # it, this script is still PID 1 with a default disposition, which drops
    # the signal outright.
    migrate_pid=""
    trap 'kill -TERM "${migrate_pid:-}" 2>/dev/null || true' TERM INT
    DISABLE_SCHEMA_UPDATE=False /app/code/venv/bin/litellm --skip_server_startup \
        --enforce_prisma_migration_check --use_v2_migration_resolver &
    migrate_pid=$!
    # A trapped signal interrupts `wait` and it returns 128+signal while the
    # child is still running, so waiting once would forward SIGTERM and then
    # abandon the migration a few milliseconds later — the very thing the
    # trap exists to prevent. Wait again until the child is really gone.
    set +e
    while true; do
        wait "${migrate_pid}"
        migrate_status=$?
        [[ ${migrate_status} -gt 128 ]] && kill -0 "${migrate_pid}" 2>/dev/null && continue
        break
    done
    set -e
    trap - TERM INT
    [[ ${migrate_status} -eq 0 ]] || {
        echo "ERROR: database migration failed (exit ${migrate_status})" >&2
        exit "${migrate_status}"
    }
    echo "${IMAGE_LITELLM_VERSION}" > "${SCHEMA_MARKER}"
fi

# --- 5. run ---------------------------------------------------------------
echo "==> Starting proxy on port ${PORT}"
exec /app/code/venv/bin/litellm \
    --config "${CONFIG_FILE}" --host 0.0.0.0 --port "${PORT}" --num_workers 1
