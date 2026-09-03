#!/bin/bash
set -euo pipefail

echo "==> Starting LiteLLM"

# --- 1. required platform environment ------------------------------------
missing=()
for var in CLOUDRON_POSTGRESQL_URL CLOUDRON_APP_ORIGIN; do
    [[ -n "${!var:-}" ]] || missing+=("${var}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing required environment variable(s): ${missing[*]}" >&2
    exit 1
fi

RUN_DIR=/run/litellm
DATA_DIR=/app/data
ENV_FILE="${DATA_DIR}/env"
CONFIG_FILE="${DATA_DIR}/config.yaml"

mkdir -p "${DATA_DIR}" "${RUN_DIR}/.cache"

# --- 2. first run: templates and secrets ---------------------------------
[[ -s "${CONFIG_FILE}" ]] || cp /app/code/config.yaml.template "${CONFIG_FILE}"
[[ -e "${ENV_FILE}" ]] || cp /app/code/env.template "${ENV_FILE}"

# LITELLM_SALT_KEY encrypts provider credentials stored in the database.
# It is generated exactly once: changing it makes stored credentials
# undecryptable, so never regenerate it for an existing installation.
append_secret() {
    local name="$1" value="$2"
    grep -qE "^${name}=" "${ENV_FILE}" && return 0
    printf '%s=%s\n' "${name}" "${value}" >> "${ENV_FILE}"
}

append_secret LITELLM_MASTER_KEY "sk-$(openssl rand -hex 24)"
append_secret LITELLM_SALT_KEY "$(openssl rand -hex 32)"
chmod 600 "${ENV_FILE}"

# --- 3. platform-derived environment -------------------------------------
# Written fresh on every start; the user's env file is sourced afterwards so
# anything set there wins.
cat > "${RUN_DIR}/env" <<EOF
DATABASE_URL=${CLOUDRON_POSTGRESQL_URL}
PROXY_BASE_URL=${CLOUDRON_APP_ORIGIN}
LITELLM_MODE=PRODUCTION
HOME=${RUN_DIR}
XDG_CACHE_HOME=${RUN_DIR}/.cache
TMPDIR=/tmp
STORE_MODEL_IN_DB=True
DISABLE_SCHEMA_UPDATE=True
EOF

if [[ -n "${CLOUDRON_REDIS_HOST:-}" ]]; then
    cat >> "${RUN_DIR}/env" <<EOF
REDIS_HOST=${CLOUDRON_REDIS_HOST}
REDIS_PORT=${CLOUDRON_REDIS_PORT}
REDIS_PASSWORD=${CLOUDRON_REDIS_PASSWORD:-}
EOF
fi

# Cloudron SSO -> LiteLLM generic OIDC. Absent when the app is installed
# without SSO, in which case the master key is the only admin login.
if [[ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]]; then
    echo "==> Cloudron SSO detected, enabling OIDC login"
    cat >> "${RUN_DIR}/env" <<EOF
GENERIC_CLIENT_ID=${CLOUDRON_OIDC_CLIENT_ID}
GENERIC_CLIENT_SECRET=${CLOUDRON_OIDC_CLIENT_SECRET}
GENERIC_AUTHORIZATION_ENDPOINT=${CLOUDRON_OIDC_AUTH_ENDPOINT}
GENERIC_TOKEN_ENDPOINT=${CLOUDRON_OIDC_TOKEN_ENDPOINT}
GENERIC_USERINFO_ENDPOINT=${CLOUDRON_OIDC_PROFILE_ENDPOINT}
GENERIC_SCOPE="openid profile email"
GENERIC_USER_ID_ATTRIBUTE=sub
GENERIC_USER_EMAIL_ATTRIBUTE=email
GENERIC_USER_DISPLAY_NAME_ATTRIBUTE=name
EOF
fi

cat "${ENV_FILE}" >> "${RUN_DIR}/env"

set -o allexport
# shellcheck disable=SC1091
source "${RUN_DIR}/env"
set +o allexport

# --- 4. admin UI ----------------------------------------------------------
# LiteLLM rewrites the exported UI in place on first serve so that routes like
# /ui/login resolve, which it cannot do inside the read-only image. Staging a
# copy in /run gives it somewhere writable; it is rebuilt on every start, so an
# app update always serves the UI shipped with the new version.
UI_SRC="$(cat /app/code/prisma-schema-dir)/_experimental/out"
export LITELLM_UI_PATH="${RUN_DIR}/ui"
rm -rf "${LITELLM_UI_PATH}"
cp -r "${UI_SRC}" "${LITELLM_UI_PATH}"

# --- 5. database schema ---------------------------------------------------
# LiteLLM applies its own migrations. Its migration package lives in the
# read-only image, so LITELLM_MIGRATION_DIR points it at a writable copy —
# upstream provides this variable exactly for read-only filesystems. The
# server itself then runs with DISABLE_SCHEMA_UPDATE so it never retries.
export LITELLM_MIGRATION_DIR="${DATA_DIR}/migrations"
mkdir -p "${LITELLM_MIGRATION_DIR}"
chown -R cloudron:cloudron "${RUN_DIR}" "${DATA_DIR}"

# Migrations only need to run when the LiteLLM version changed — that is, on a
# first install or after an app update. Skipping them on an ordinary restart
# takes well over a minute off the boot time. The marker is written only after
# a successful run, so a failed migration is retried on the next start.
SCHEMA_MARKER="${DATA_DIR}/.schema-version"
LITELLM_VERSION="$(cat /app/code/litellm-version)"

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

# --- 6. run ---------------------------------------------------------------
echo "==> Starting proxy on port 4000"
exec gosu cloudron:cloudron /app/code/venv/bin/litellm \
    --config "${CONFIG_FILE}" --host 0.0.0.0 --port 4000 --num_workers 1
