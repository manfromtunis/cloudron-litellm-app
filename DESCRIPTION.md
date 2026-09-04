LiteLLM is an open source AI gateway. It exposes one OpenAI-compatible API in front of
100+ model providers, so every application, script and agent you run can point at a single
endpoint and you decide behind it which model actually answers.

### What it gives you

* **One API for every provider.** OpenAI, Anthropic, Google Gemini and Vertex AI, AWS Bedrock,
  Azure OpenAI, Mistral, Groq, DeepSeek, OpenRouter, Ollama and many more, all called with the
  OpenAI request format at `/v1/chat/completions`, `/v1/embeddings` and friends.
* **Virtual keys instead of provider keys.** Provider credentials stay on the server. You hand
  out per-user, per-team or per-project keys that you can budget, rate limit, rotate and revoke
  from the Admin UI, without touching the upstream account.
* **Spend tracking.** Every request is costed and logged per key, user, team and model, so you
  can see where the money goes and cap it before it goes further.
* **Fallbacks and load balancing.** Route a model name across several deployments, fail over to
  a second provider when the first errors or rate limits, and retry automatically.
* **Caching.** Repeated requests are served from the Redis this app provisions for you.

### On Cloudron

The app provisions its own PostgreSQL and Redis. Models are added from the Admin UI or from
`/app/data/config.yaml`, and provider API keys live in `/app/data/env`, both reachable through
the File Manager. When installed with Cloudron SSO, the Admin UI signs in with your Cloudron
account; the generated master key remains the admin fallback and the credential your API
clients can use. Note that LiteLLM's own SSO support is free for up to 5 UI users.
