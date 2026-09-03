#!/bin/bash
set -euo pipefail

echo "==> Starting LiteLLM"

RUN_DIR=/run/litellm
DATA_DIR=/app/data
ENV_FILE="${DATA_DIR}/env"
CONFIG_FILE="${DATA_DIR}/config.yaml"

: "${CLOUDRON_POSTGRESQL_URL:?is required — is the postgresql addon enabled?}"
: "${CLOUDRON_APP_ORIGIN:?is required}"

mkdir -p "${RUN_DIR}/.cache"

# --- 1. first run: templates and secrets ---------------------------------
[[ -s "${CONFIG_FILE}" ]] || cp /app/code/config.yaml.template "${CONFIG_FILE}"
[[ -s "${ENV_FILE}" ]] || cp /app/code/env.template "${ENV_FILE}"

# LITELLM_SALT_KEY encrypts provider credentials stored in the database.
# It is generated exactly once: changing it makes stored credentials
# undecryptable, so never regenerate it for an existing installation.
append_secret() {
    local name="$1" value="$2"
    grep -qE "^${name}=" "${ENV_FILE}" && return 0
    printf '%s=%s\n' "${name}" "${value}" >> "${ENV_FILE}"
}

# Without a trailing newline the appends below would glue the key onto the
# last line, hiding it from the grep above and regenerating it every boot.
sed -i -e '$a\' "${ENV_FILE}"

append_secret LITELLM_MASTER_KEY "sk-$(openssl rand -hex 24)"
append_secret LITELLM_SALT_KEY "$(openssl rand -hex 32)"
chmod 600 "${ENV_FILE}"

# --- 2. platform-derived environment -------------------------------------
# The user's env file is sourced last, so anything set there wins.
set -o allexport

DATABASE_URL="${CLOUDRON_POSTGRESQL_URL}"
PROXY_BASE_URL="${CLOUDRON_APP_ORIGIN}"
LITELLM_MODE=PRODUCTION
STORE_MODEL_IN_DB=True
DISABLE_SCHEMA_UPDATE=True
HOME="${RUN_DIR}"
XDG_CACHE_HOME="${RUN_DIR}/.cache"
TMPDIR=/tmp
LITELLM_MIGRATION_DIR="${DATA_DIR}/migrations"

if [[ -n "${CLOUDRON_REDIS_HOST:-}" ]]; then
    REDIS_HOST="${CLOUDRON_REDIS_HOST}"
    REDIS_PORT="${CLOUDRON_REDIS_PORT:-6379}"
    REDIS_PASSWORD="${CLOUDRON_REDIS_PASSWORD}"
fi

# Cloudron SSO -> LiteLLM generic OIDC. Absent when the app is installed
# without SSO, in which case the master key is the only admin login.
if [[ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]]; then
    echo "==> Cloudron SSO detected, enabling OIDC login"
    GENERIC_CLIENT_ID="${CLOUDRON_OIDC_CLIENT_ID}"
    GENERIC_CLIENT_SECRET="${CLOUDRON_OIDC_CLIENT_SECRET:?the oidc addon must set it}"
    GENERIC_AUTHORIZATION_ENDPOINT="${CLOUDRON_OIDC_AUTH_ENDPOINT:?the oidc addon must set it}"
    GENERIC_TOKEN_ENDPOINT="${CLOUDRON_OIDC_TOKEN_ENDPOINT:?the oidc addon must set it}"
    GENERIC_USERINFO_ENDPOINT="${CLOUDRON_OIDC_PROFILE_ENDPOINT:?the oidc addon must set it}"
    GENERIC_SCOPE="openid profile email"
    GENERIC_USER_ID_ATTRIBUTE=sub
    GENERIC_USER_EMAIL_ATTRIBUTE=email
    GENERIC_USER_DISPLAY_NAME_ATTRIBUTE=name
fi

# shellcheck disable=SC1090
source "${ENV_FILE}" || {
    echo "ERROR: /app/data/env is not valid shell. Quote values containing spaces or \$." >&2
    exit 1
}

set +o allexport

# --- 3. database schema ---------------------------------------------------
# LiteLLM applies its own migrations. Its migration package lives in the
# read-only image, so LITELLM_MIGRATION_DIR points it at a writable copy —
# upstream provides this variable exactly for read-only filesystems. The
# server itself then runs with DISABLE_SCHEMA_UPDATE so it never retries.
mkdir -p "${LITELLM_MIGRATION_DIR}"
chown -R cloudron:cloudron "${RUN_DIR}" "${DATA_DIR}"

# Migrations only need to run when the LiteLLM version changed — that is, on a
# first install or after an app update. Skipping them on an ordinary restart
# takes well over a minute off the boot time. The marker is written only after
# a successful run, so a failed migration is retried on the next start.
SCHEMA_MARKER="${DATA_DIR}/.schema-version"

if [[ "$(cat "${SCHEMA_MARKER}" 2>/dev/null || true)" == "${LITELLM_VERSION}" ]]; then
    echo "==> Database schema already applied for LiteLLM ${LITELLM_VERSION}"
else
    echo "==> Applying database schema for LiteLLM ${LITELLM_VERSION}"
    gosu cloudron:cloudron env DISABLE_SCHEMA_UPDATE=False \
        /app/code/venv/bin/litellm --skip_server_startup \
            --enforce_prisma_migration_check --use_v2_migration_resolver
    echo "${LITELLM_VERSION}" > "${SCHEMA_MARKER}"
    chown cloudron:cloudron "${SCHEMA_MARKER}"
fi

# --- 4. run ---------------------------------------------------------------
echo "==> Starting proxy on port 4000"
exec gosu cloudron:cloudron /app/code/venv/bin/litellm \
    --config "${CONFIG_FILE}" --host 0.0.0.0 --port 4000 --num_workers 1
