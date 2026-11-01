# Contributing

Issues and pull requests are welcome.

## Changing or adding an app

Each app lives in `apps/<slug>/` with two files:

- `install.sh`: the installer, run as root on Ubuntu 24.04. It sources `lib/recipe-lib.sh` and reports its results with `vm_output`.
- `recipe.json`: name, version, minimum spec, ports, health check, declared outputs and upstream licence.

Rules:

- Pin every version. Container images are pinned by tag and `@sha256` digest; downloaded files are verified against a published checksum or signature.
- Generate secrets on the host with `vm_secret`. Never print them, never put them on a command line that is logged, never use `set -x`.
- Install upstream software unmodified. Check the licence before adding an app and record it in `recipe.json` and the README.
- Installers must be safe to run again after a failure.
- Bind internal services to `127.0.0.1` and publish only through the reverse proxy.

## Checks

```bash
find . -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck -x install.sh lib/recipe-lib.sh apps/*/install.sh
```

Run from each script's own directory if `shellcheck` cannot follow the `source` directives. CI runs the same checks.

Test a change on a fresh Ubuntu 24.04 server at the app's minimum spec and say what you ran in the pull request.

By contributing you agree that your contribution is licensed under the MIT licence in `LICENSE`.
