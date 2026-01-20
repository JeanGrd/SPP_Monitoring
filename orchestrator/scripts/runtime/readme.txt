SPPMon Control (Target Host)
----------------------------

Each deployed release ships a lightweight control utility:

- Script: current/bin/control.sh
- Documentation: current/bin/control.txt

This control plane manages the services of the current release only.

Directory layout
-----------------------------

A deployment is installed under:

- <base>/releases/<release_id>/   (immutable release content)
- <base>/current                  (symlink to the active release)
- <base>/volumes/                 (persistent data, logs, runtime state)

Runtime convention:

- volumes/data/   : persistent state
- volumes/logs/   : service logs
- volumes/run/    : pid files

Usage
-----------------------------

From the deployment base directory:

Example:
./current/bin/control.sh --help

Commands
-----------------------------

- ./current/bin/control.sh list
    List available services.
- ./current/bin/control.sh status [service]
    Show status for all or a specific service.
- ./current/bin/control.sh start <service|all>
    Start a service or all services.
- ./current/bin/control.sh stop <service|all>
    Stop a service or all services.
- ./current/bin/control.sh restart <service|all>
    Restart a service or all services.
- ./current/bin/control.sh logs <service> [--tail N]
    Show logs for a service (optionally tail last N lines).
- ./current/bin/control.sh clean logs|run
    Clean logs or runtime files.
- ./current/bin/control.sh clean data --force
    Remove persistent data (requires --force).

Note: The script reloads environment.sh on each invocation so edits are picked up immediately.