FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

LABEL org.opencontainers.image.source="https://github.com/manfromtunis/cloudron-litellm-app"

ARG LITELLM_VERSION=1.99.0

RUN apt-get update && apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/*

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
    LITELLM_NON_ROOT=true

RUN python3 -m venv "${VIRTUAL_ENV}" \
    && "${VIRTUAL_ENV}/bin/pip" install --no-cache-dir --upgrade pip \
    && "${VIRTUAL_ENV}/bin/pip" install --no-cache-dir \
        "litellm[proxy,extra_proxy,proxy-runtime]==${LITELLM_VERSION}"

# The Prisma client is generated into the image: regenerating it would write
# into site-packages, which is read-only at runtime. schema.prisma lives inside
# the installed package, so its location is recorded for start.sh.
RUN set -eux; \
    schema="$(find "${VIRTUAL_ENV}/lib" -name schema.prisma -path '*litellm/proxy*' | head -n1)"; \
    test -n "${schema}"; \
    dirname "${schema}" > /app/code/prisma-schema-dir; \
    mkdir -p "${PRISMA_HOME_DIR}"; \
    "${VIRTUAL_ENV}/bin/prisma" generate --schema="${schema}"; \
    rm -rf "${PRISMA_HOME_DIR}/.npm" "${PRISMA_HOME_DIR}/.cache/checkpoint-nodejs" \
           "${PRISMA_NODEENV_CACHE_DIR}/src" \
           "${PRISMA_NODEENV_CACHE_DIR}/share/man" "${PRISMA_NODEENV_CACHE_DIR}/share/doc"; \
    test -x "${PRISMA_NODEENV_CACHE_DIR}/bin/node"

RUN echo "${LITELLM_VERSION}" > /app/code/litellm-version

COPY start.sh config.yaml.template env.template /app/code/
RUN chmod +x /app/code/start.sh

EXPOSE 4000

CMD ["/app/code/start.sh"]
