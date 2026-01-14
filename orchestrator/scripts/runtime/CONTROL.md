# SPPMon Control (Target Host)

Each deployed release ships a lightweight control utility:

- Script: `current/bin/control.sh`
- Documentation: `current/meta/CONTROL.md`

This control plane manages the services of the **current** release only.

## Directory layout

A deployment is installed under:

- `<base>/releases/<release_id>/`  (immutable release content)
- `<base>/current`                 (symlink to the active release)
- `<base>/volumes/`                (persistent data/logs/runtime state)

Runtime convention:

- `volumes/data/`  : persistent state
- `volumes/logs/`  : service logs
- `volumes/run/`   : pid files

## Usage

From the deployment base directory:

```bash
./current/bin/control.sh --help