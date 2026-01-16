

# Bash Scripts for Orchestration

SPP Monitoring is a lightweight deployment and release-management tool designed to **package, deploy, switch, and roll back monitoring agents and related services** across environments in a controlled and auditable way.

The project focuses on **immutability, simplicity, and operational safety**, while remaining flexible enough to support different applications, environments, and service stacks.

---

## Goals

- Provide a **clean and deterministic deployment model** for monitoring agents (e.g. Alloy, Loki exporters, future agents)
- Enable **safe rollbacks** using immutable releases and symbolic links
- Keep orchestration logic **simple, readable, and auditable** (Bash-first approach)
- Support both **local simulation** and **remote deployment** (via SSH, later)
- Remain compatible with constrained environments (RHEL 7.x, limited internet access)

This project intentionally avoids heavy orchestration frameworks at this stage (Ansible Tower, Kubernetes, etc.) in favor of a transparent, script-based approach.

---

## Core Concepts

### Immutable Releases
Each deployment produces a **new immutable release** identified by:

```
<APP>_<ENV>_<YYYYMMDD_HHMMSS>
```

Example:
```
ICOM_PRD_20260113_145803
```

A release contains:
- `bin/` – service binaries
- `config/` – rendered configuration files
- `meta/` – metadata and manifest

Once created, a release is **never modified**.

---

### `current` Symlink

Each target host has a `current` symbolic link pointing to the active release:

```
current -> releases/ICOM_PRD_20260113_145803
```

Switching versions (deploy or rollback) is done **atomically** by updating this symlink.

This approach enables:
- Instant rollbacks
- Zero file mutation
- Clear auditability

---

### Release Inventory (`.prom`)

Each host maintains a Prometheus-compatible inventory file:

```
releases/version_present.prom
```

Example:
```prom
# HELP sppmon_release Release inventory (1 = present on disk). Label current="true" marks the active release.
# TYPE sppmon_release gauge
sppmon_release{release="ICOM_PRD_20260113_145803",current="true"} 1
sppmon_release{release="ICOM_PRD_20260112_231010",current="false"} 1
```

This allows:
- Monitoring which releases exist
- Identifying the active release
- Integrating deployment state into dashboards and alerts

---

## Repository Structure

...

---

## Supported Operations

### Deploy

Creates a new release and activates it on one or more targets.

Key characteristics:
- Always creates a new immutable release
- Uses a staging directory before activation
- Switches `current` only after successful deployment

### Rollback

Switches `current` to an existing release.

Key characteristics:
- No file copying
- No rebuilding
- Atomic and instant
- Updates monitoring inventory automatically

```
host/<target>/sppmon/
```

This allows:
- Safe development and testing
- No SSH access required
- Full visibility of file layout

Remote (SSH-based) deployment will be enabled later behind an explicit flag.