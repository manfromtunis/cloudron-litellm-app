LiteLLM is running, but it has no models yet.

1. Open the File Manager and edit `/app/data/env`. It already contains a generated
   `LITELLM_MASTER_KEY` (this is your admin password and API key) and a `LITELLM_SALT_KEY`.
   Add your provider keys there, for example `OPENAI_API_KEY=sk-...`.
2. Add models either from the Admin UI at `/ui` (Models, then Add Model) or by editing
   `/app/data/config.yaml`, which has a commented example per provider.
3. Restart the app after editing files, then call it like OpenAI:
   `curl $APP_ORIGIN/v1/chat/completions -H "Authorization: Bearer $LITELLM_MASTER_KEY" ...`

Never change `LITELLM_SALT_KEY` after installation. It encrypts the provider credentials
stored in the database, and changing it makes them unreadable.

<sso>Sign in to the Admin UI with your Cloudron account. The first SSO user is created as an
internal user, not an admin; to make yourself proxy admin, copy your user id from Internal
Users and set `PROXY_ADMIN_ID=<id>` in `/app/data/env`, then restart. LiteLLM allows up to 5
SSO users on the free tier. The master key still works at `/fallback/login`.</sso>
