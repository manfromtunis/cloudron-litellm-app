FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

LABEL org.opencontainers.image.source="https://github.com/manfromtunis/cloudron-litellm-app"

ARG LITELLM_VERSION=1.99.0

RUN apt-get update && apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && for tool in openssl gosu psql flock; do command -v "${tool}" > /dev/null || exit 1; done

# Everything Prisma needs — the CLI, its Node runtime and the query engines —
# is resolved from these fixed image paths instead of $HOME, so nothing has to
# be downloaded or written at runtime on Cloudron's read-only filesystem.
ENV VIRTUAL_ENV=/app/code/venv \
    PATH=/app/code/venv/bin:$PATH \
    PRISMA_HOME_DIR=/app/code/prisma \
    PRISMA_BINARY_CACHE_DIR=/app/code/prisma/binaries \
    PRISMA_NODEENV_CACHE_DIR=/app/code/prisma/nodeenv \
    PRISMA_CLI_QUERY_ENGINE_TYPE=binary \
    PRISMA_SKIP_POSTINSTALL_GENERATE=1 \
    PRISMA_HIDE_UPDATE_MESSAGE=1 \
    LITELLM_UI_PATH=/app/code/ui \
    LITELLM_VERSION=${LITELLM_VERSION}

RUN python3 -m venv "${VIRTUAL_ENV}" \
    && "${VIRTUAL_ENV}/bin/pip" install --no-cache-dir --upgrade pip \
    && "${VIRTUAL_ENV}/bin/pip" install --no-cache-dir \
        "litellm[proxy,extra_proxy,proxy-runtime]==${LITELLM_VERSION}" \
    && "${VIRTUAL_ENV}/bin/pip" uninstall -y litellm-enterprise

# litellm-enterprise arrives as a dependency of the proxy extra, but it is not
# MIT: its licence forbids redistribution, and this image is published. LiteLLM
# imports it inside a try/except ImportError, so the proxy runs without it —
# minus the enterprise-only features, which need a BerriAI subscription anyway.
# Asserted through the interpreter rather than with a negated import, which
# would also "pass" if python itself were broken.
RUN "${VIRTUAL_ENV}/bin/python" -c \
    "import importlib.util, litellm, sys; sys.exit(1 if importlib.util.find_spec('litellm_enterprise') else 0)"

# The Prisma client is generated into the image: regenerating it would write
# into site-packages, which is read-only at runtime. The exported admin UI is
# lifted out of the package for the same reason — LiteLLM rewrites its UI
# directory in place unless it is already laid out one directory per route,
# which the assertion below is what guarantees.
RUN set -eux; \
    schema="$(find "${VIRTUAL_ENV}/lib" -name schema.prisma -path '*litellm/proxy*' | head -n1)"; \
    test -n "${schema}"; \
    cp -r "$(dirname "${schema}")/_experimental/out" "${LITELLM_UI_PATH}"; \
    test -f "${LITELLM_UI_PATH}/index.html"; \
    test -f "${LITELLM_UI_PATH}/login/index.html"; \
    touch "${LITELLM_UI_PATH}/.litellm_ui_ready"; \
    mkdir -p "${PRISMA_HOME_DIR}"; \
    "${VIRTUAL_ENV}/bin/prisma" generate --schema="${schema}"; \
    rm -rf "${PRISMA_HOME_DIR}/.npm" "${PRISMA_HOME_DIR}/.cache/checkpoint-nodejs" \
           "${PRISMA_NODEENV_CACHE_DIR}/src" \
           "${PRISMA_NODEENV_CACHE_DIR}/include" \
           "${PRISMA_NODEENV_CACHE_DIR}/lib/node_modules/npm" \
           "${PRISMA_NODEENV_CACHE_DIR}/share/man" \
           "${PRISMA_NODEENV_CACHE_DIR}/share/doc"; \
    strip --strip-unneeded "${PRISMA_NODEENV_CACHE_DIR}/bin/node"; \
    find "${PRISMA_HOME_DIR}" -name 'query-engine-linux-musl*' -delete; \
    find "${PRISMA_HOME_DIR}" -name '*-debian-openssl-1.1.x' -delete; \
    test -x "${PRISMA_NODEENV_CACHE_DIR}/bin/node"

COPY --chmod=0755 start.sh /app/code/
COPY config.yaml.template env.template /app/code/

EXPOSE 4000

CMD ["/app/code/start.sh"]
