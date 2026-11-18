# zalaf-door

Temporary, policy-controlled SSH sessions for multiple remote AI agents.

## Features

- Opens a named seat for 5–1,440 minutes.
- Adds restrictive SSH options and an expiration time to each temporary key.
- Removes only the seat's `zalaf-door-NAME-TIMESTAMP` tag from `authorized_keys`.
- Preserves NOVA, fixed ZALAF, and unrelated owner entries.
- Supports optional command auditing, automatic guards, backups, and safety checks.
- Keeps a small local registry for reusable agent seats.

## Installation

Copy `zalaf_doo.sh` to a trusted location and make it executable:

```bash
chmod 700 zalaf_doo.sh
```

The default runtime directory is `/root/zalaf.net/run` and the default key file
is `/root/.ssh/authorized_keys`. For testing, override them without touching
the real files:

```bash
ZALAF_DOOR_RUNDIR=/tmp/zalaf-door-run \
ZALAF_DOOR_KEYFILE=/tmp/authorized_keys \
bash zalaf_doo.sh --help
```

## Usage

Run the interactive menu:

```bash
sudo bash zalaf_doo.sh
```

Useful commands:

```bash
sudo bash zalaf_doo.sh open -a arena -m 120 -w
sudo bash zalaf_doo.sh list
sudo bash zalaf_doo.sh status -a arena
sudo bash zalaf_doo.sh log -a arena --follow
sudo bash zalaf_doo.sh close -a arena --dry-run
sudo bash zalaf_doo.sh close --all
sudo bash zalaf_doo.sh agents
sudo bash zalaf_doo.sh doctor
```

Use `agent-add NAME --key FILE.pub` to register another agent. Use
`--restricted`, `--no-sftp`, and `--no-pty` to apply additional restrictions.
The `--wrap` option records commands in the agent's audit log; do not enable it
if command contents may contain sensitive data.

## Safety

Every key-file change is backed up first. Before committing a change, the
script verifies that protected NOVA and fixed ZALAF lines are unchanged and
restores the backup if an unexpected line changes. Review backups and audit
logs according to your security policy.

## License

MIT. See [LICENSE](LICENSE).
