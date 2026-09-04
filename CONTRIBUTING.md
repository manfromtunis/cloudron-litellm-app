# Contributing

**Where does your issue belong?**

* LiteLLM itself — a model that will not route, a provider error, an Admin UI
  bug, anything you could reproduce with the official Docker image — goes
  upstream: https://github.com/BerriAI/litellm/issues
* This package — installing, updating, backing up or restoring on Cloudron,
  the addon wiring, the generated secrets, the config templates — belongs here.

**Changes.** Run the test suite before opening a pull request:

```sh
docker build -t cloudron-litellm:dev .
./test/local-run.sh
```

It runs the image the way Cloudron does, against a real PostgreSQL and Redis,
and takes a few minutes. CI runs the same script, so a change that does not
pass locally will not pass there.

Bumping LiteLLM means changing `ARG LITELLM_VERSION` in the `Dockerfile`,
`upstreamVersion` and `version` in `CloudronManifest.json`, and adding a
`CHANGELOG` entry. CI checks that those agree.
