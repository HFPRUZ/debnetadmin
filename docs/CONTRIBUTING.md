# Contributing to DebNetAdmin

Thanks for your interest in improving DebNetAdmin.

## Ground rules

- Keep the script **dependency-free**: only Bash and tools shipped with a base Debian system, plus packages installed on demand by a command.
- Every command that changes the system must:
  1. call `require_root`,
  2. go through the `run` / `write_file` helpers so `--dry-run` works,
  3. back up files it overwrites (`backup_file`),
  4. validate configuration before reloading a service when a test exists.
- Never put secrets in the repository or in the script.
- Prefer idempotent behaviour: running a command twice must be safe.

## Development setup

```bash
git clone https://github.com/<your-user>/debnetadmin.git
cd debnetadmin
bash -n debnetadmin.sh          # syntax check
shellcheck debnetadmin.sh       # static analysis (apt install shellcheck)
```

Test in a disposable Debian VM or container, never on production first:

```bash
docker run --rm -it -v "$PWD":/src debian:stable bash
# inside: apt-get update && apt-get install -y sudo iproute2 procps && /src/debnetadmin.sh --dry-run health
```

Note that systemd-dependent commands will not fully work in a plain container;
use a VM for those.

## Adding a new service

1. Add an entry to the four arrays at the top of the script: `SERVICE_PKGS`, `SERVICE_UNITS`, `SERVICE_PORTS` and, if a validation command exists, `CONFIG_TESTS`.
2. Add a row to the tables in `docs/USAGE.md` and the list in `README.md`.
3. Run `shellcheck` and test `install`, `svc`, `fw-preset`, `logs` and `check-config` for the new key.

## Extending the HTML report

Each report section is a `rep_*` function in `debnetadmin.sh` that writes HTML
through the helpers (`rep_open`, `kv`, `rep_table`, `rep_cmd`, `rep_sh`, `bar`,
`badge`) and records results with `finding <crit|warn|info|ok> "message" "fix command"`.

- Escape everything that comes from the system: the helpers do it, so never `echo` raw values into the page. Cells starting with `@@` in `rep_table` are raw HTML and must be built from `badge`/`bar` only.
- Never rely on a pipeline to set findings (a piped `while` runs in a subshell): read with `done < <(command)`.
- Every check must degrade gracefully without root: call `limited "reason"` and do not fail.
- Keep the page self-contained: inline CSS only, no JavaScript, no external requests.
- Register new sections in the navigation list inside `report_assemble`.

## Adding a command

1. Write a `cmd_<name>` function (validate every argument first, call `require_root` when it changes the system, use `run`/`write_file` so `--dry-run` works).
2. Add it to the dispatcher in `main()` and to `usage()`.
3. If it is read-only, add it to the list of commands that skip the OS check.
4. Add a menu entry or wizard in the interactive section and document it in `docs/USAGE.md` and `CHANGELOG.md`.

## Style

- 2-space indentation, `snake_case` function names, `cmd_` prefix for commands.
- Quote all variable expansions.
- Use `[[ ... ]]` and `$(...)`.
- Messages in English, short and actionable.

## Pull requests

- One logical change per pull request.
- Describe what you tested and on which Debian release.
- Update the documentation together with the code.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](../LICENSE).

## Reporting security issues

Please do not open a public issue for vulnerabilities. Contact the maintainer
privately with details and reproduction steps.
