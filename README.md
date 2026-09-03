# LiteLLM for Cloudron

A [Cloudron](https://cloudron.io) package for [LiteLLM](https://www.litellm.ai), the open
source AI gateway. One OpenAI-compatible endpoint in front of 100+ model providers, with
virtual keys, budgets, spend tracking, fallbacks and caching.

Not affiliated with BerriAI. LiteLLM itself is MIT licensed; so is this package.

## Install

The app is not in the official Cloudron App Store. Install it from this repository's
community catalog:

```sh
cloudron install --versions-url https://raw.githubusercontent.com/manfromtunis/cloudron-litellm-app/main/CloudronVersions.json --location litellm
```

Or, in the Cloudron dashboard, add that URL under **App Store → Community apps** and install
from there. Updates are picked up automatically once the URL is registered.

## First steps after installing

The app starts with no models configured.

1. Open the **File Manager** and edit `/app/data/env`. It already holds a generated
   `LITELLM_MASTER_KEY` — this is both the admin password for the UI and a working API key.
   Add provider credentials here, one `KEY=value` per line:

   ```sh
   OPENAI_API_KEY=sk-...
   ANTHROPIC_API_KEY=sk-ant-...
   GEMINI_API_KEY=...
   ```

2. Add models, either from the Admin UI at `/ui` (**Models → Add Model**, stored in the
   database) or by editing `/app/data/config.yaml`, which ships a commented example per
   provider.

3. Restart the app, then call it exactly like the OpenAI API:

   ```sh
   curl https://litellm.example.com/v1/chat/completions \
     -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     -H "Content-Type: application/json" \
     -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}'
   ```

Hand out **virtual keys** rather than the master key: create them per user, team or project
in the Admin UI, each with its own budget and rate limit, and revoke them without touching
your provider account.

## Authentication

Installed **with Cloudron SSO**, the Admin UI signs in with your Cloudron account through
OIDC. The first SSO user is created as a plain internal user; to make yourself proxy admin,
copy your user id from **Internal Users** and set `PROXY_ADMIN_ID=<id>` in `/app/data/env`,
then restart. LiteLLM's own SSO is free for up to 5 UI users; beyond that it needs a LiteLLM
Enterprise licence.

Installed **without SSO**, the master key is the only UI login. Either way, the API is
authenticated by LiteLLM's own keys, never by Cloudron's proxy, so API clients work
identically in both modes.

## What the package does for you

| Concern | How it is handled |
| --- | --- |
| Database | The `postgresql` addon; `DATABASE_URL` is wired at start |
| Cache and rate limits | The `redis` addon; referenced from `config.yaml` as `os.environ/REDIS_*` |
| Secrets | `LITELLM_MASTER_KEY` and `LITELLM_SALT_KEY` generated once into `/app/data/env` |
| Schema migrations | Applied at start with `LITELLM_MIGRATION_DIR` pointing at a writable copy |
| SSO | `CLOUDRON_OIDC_*` mapped to LiteLLM's generic OIDC variables |
| Health | `/health/liveliness` |

**`LITELLM_SALT_KEY` must never change after installation.** It encrypts the provider
credentials stored in the database; changing it makes them unreadable.

## Configuration files

Both live in `/app/data`, survive updates and restarts, and are included in Cloudron backups.

* `config.yaml` — models, routing, fallbacks, caching.
  See the [LiteLLM config reference](https://docs.litellm.ai/docs/proxy/configs).
* `env` — API keys and any LiteLLM environment variable. Values set here override the
  package's own, so you can change anything the package configures.

## Development

```sh
docker build -t cloudron-litellm:dev .
./test/local-run.sh                  # runs the package under Cloudron's constraints
```

`test/local-run.sh` starts PostgreSQL and Redis, runs the image with a **read-only root
filesystem** and only `/tmp`, `/run` and `/app/data` writable — the same restrictions
Cloudron imposes — then checks first-boot secret generation, the authenticated and
unauthenticated API, the applied schema, key persistence across a restart, and the SSO
redirect. Use `KEEP=1` to leave the stack running on port 14000.

## Releasing

1. Bump `version` in `CloudronManifest.json` (and `upstreamVersion` plus the `LITELLM_VERSION`
   build argument when moving to a new LiteLLM release), and add a matching `[x.y.z]` section
   at the top of `CHANGELOG`.
2. Merge to `main`, then push a `vX.Y.Z` tag. CI builds the amd64 image and pushes it to
   `ghcr.io/manfromtunis/cloudron-litellm-app:X.Y.Z`. The GHCR package must be public.
3. Record the release in the catalog and publish it:

   ```sh
   cloudron versions add --image ghcr.io/manfromtunis/cloudron-litellm-app:X.Y.Z --state testing
   cloudron install --versions-url <raw CloudronVersions.json URL> --location litellm-test
   cloudron versions update --version X.Y.Z --state published
   ```

   Commit the updated `CloudronVersions.json`. Published entries are append-only: never edit
   the manifest or image of a released version, revoke it and publish a new one instead.
