# ansible-resizecompute

Ansible playbooks to change a VM's **vCPU count** and **memory size** on
**VMware** (vSphere/ESXi) or **Hyper-V** — growing or shrinking. Third
project in this series alongside `ansible-resizedisk` and
`ansible-snapshot`, sharing their overall design (ServiceNow-triggered,
no static per-VM inventory, hypervisor auto-detection, SCVMM awareness),
but with a fundamentally different technical profile: CPU/memory
hot-*add* exists on both platforms with real prerequisites, hot-*remove*
essentially does not exist anywhere, and Hyper-V has no CPU hot-add at
all. This project applies a change live whenever the platform genuinely
allows it, and falls back to a coordinated power-cycle (graceful
shutdown → change → power back on, only if it was running before)
everywhere else — never a silent downgrade to "wait for a maintenance
window", and never a guess at a capability that isn't actually there.

Like `ansible-snapshot`, this never connects to the guest OS — every
operation here is hypervisor-side.

Two separate playbooks (`resize_cpu`, `resize_ram`) rather than one
combined "reconfigure" playbook, so each can be exposed as its own
ServiceNow catalog item/job template with its own RBAC, and so a request
that only touches one resource doesn't pay for a power-cycle on the
other if it isn't hot-eligible.

## How it works

Both playbooks share the same first two steps, then branch:

1. **`preflight_platform`** — identical role to the other two projects'
   (adapted variable names, `compute_` instead of `resizedisk_`/
   `snapshot_`): validates that the target is actually a VM, detects the
   hypervisor (`compute_hypervisor_type`) and, for Hyper-V, whether it's
   **managed by SCVMM** (`compute_managed_by_scvmm`). Same `vm_name`
   safe-charset validation as the other two projects (command-injection
   guardrail, not a real naming restriction).

2. **`compute_lock`** — takes a per-VM lock before any other action,
   same design as the other two projects' locks (atomic file on
   Hyper-V, best-effort VM annotation marker on VMware), but its own
   namespace (`COMPUTE_LOCK` / `C:\ProgramData\ansible-resizecompute\`)
   — **none of the three projects coordinate with each other**. This one
   matters more than usual here: the cold path power-cycles the VM, and
   two overlapping runs power-cycling the same VM at once would be
   actively dangerous, not just wasteful.

Then, per playbook:

3. **`preflight_cpu_constraints`** / **`preflight_ram_constraints`** —
   determines whether the request is a **grow**, a **shrink**, or a
   **no-op** (compared against the current value), whether it can be
   applied **live** or needs the VM **power-cycled** (see the decision
   table below), enforces a policy cap/floor, and blocks on a clustered
   Hyper-V VM whose owner node has drifted or that hasn't been
   explicitly signed off.

4. **`resize_cpu_vmware`** / **`resize_cpu_scvmm`** / **`resize_cpu_hyperv`**
   (and the `resize_ram_*` equivalents) — the actual change, routed the
   same way `ansible-resizedisk`/`ansible-snapshot` route between direct
   Hyper-V cmdlets and SCVMM. The cold path is self-contained in a
   single delegated script: capture the VM's current power state,
   gracefully stop it if running (polling for the stopped state up to
   `compute_poweroff_timeout_seconds`), apply the change, then start it
   back up only if it was running before.

A structured summary (`compute_summary`) is published via
`ansible.builtin.set_stats` on both playbooks — retrievable as an
AWX/Tower job *artifact* and therefore readable by ServiceNow on return
from the call.

### Hot vs. cold path, per platform

These are the actual, verified constraints of each platform (checked
against current Broadcom/VMware and Microsoft documentation while
building this, not assumed) — not a simplification:

| | VMware | Hyper-V (native) | Hyper-V (via SCVMM) |
|---|---|---|---|
| **CPU grow, live possible?** | Yes - CPU Hot Add, if already enabled on the VM and it's powered on | **Never** - no vCPU hot-add exists on Hyper-V | **Never** |
| **CPU shrink, live possible?** | **Never** - vSphere has no CPU hot-*remove* | **Never** | **Never** |
| **RAM grow, live possible?** | Yes - Memory Hot Add, if already enabled and powered on | Yes, but only the *ceiling* - raising `-MaximumBytes` on a VM that already has Dynamic Memory enabled and running (the guest claims the extra memory based on demand, not immediately, unlike VMware's hot-add) | **Never** - always cold, matching Microsoft's own documented `Set-SCVirtualMachine` examples (which power off the VM before every memory change shown, including enabling Dynamic Memory) |
| **RAM shrink, live possible?** | **Never** - vSphere has no memory hot-*remove* | **Never** - lowering `-MaximumBytes`, raising `-MinimumBytes`, or changing `-StartupBytes` all require Dynamic Memory to be turned off first, which itself needs the VM off | **Never** |

Everything not marked "live possible" goes through the cold path
automatically - there's no separate "refuse to shrink" rule anywhere in
this project the way `ansible-resizedisk` refuses to shrink a disk:
**the cold path is itself the safety mechanism for a shrink.** The guest
is never running with a resource configuration mismatch, because it's
off while the change happens and boots directly into the final state -
there's no in-guest coordination this project could add anyway, since it
never connects to the guest OS.

**VMware Hot Add prerequisites**, both CPU and memory: the corresponding
`*HotAddEnabled` VM setting must already be `true` (toggling it itself
requires the VM to be powered off - a catch-22 this playbook doesn't try
to resolve automatically, since flipping it as a side effect of a
resize request would be a surprising, persistent change to the VM's
configuration outside what was asked for), the guest OS must support
hot-add, VM hardware version must be 7+, VMware Tools must be running,
and Fault Tolerance must be disabled (memory only). Enabling either Hot
Add setting also **disables vNUMA** for the VM - a VMware-wide behavior
this playbook only reports (informational, non-blocking), not something
it controls.

**Detecting VMware Hot Add eligibility is best-effort.** It's read via a
`vsphere`-schema `vmware_guest_info` query
(`config.cpuHotAddEnabled`/`config.memoryHotAddEnabled`) rather than the
default summary schema, which doesn't expose these fields. If that
query ever comes back empty for any reason, this project defaults to
**not eligible** - the safe direction is always to fall back to the cold
(power-cycle) path, never to assume hot-add is available when it might
not be.

**Hyper-V has no CPU hot-add or hot-remove at all.** `Set-VMProcessor`
unconditionally requires the VM to be turned off, for both a grow and a
shrink, confirmed against current Microsoft documentation - so every
Hyper-V/SCVMM CPU change is a power-cycle, with no eligibility check
needed at all (unlike RAM, where Dynamic Memory gives Hyper-V a genuine,
if partial, live path).

**Hyper-V's live memory raise only moves the ceiling.** Unlike VMware's
hot-add, which immediately gives the guest more usable memory,
`Set-VMMemory -MaximumBytes` on a running Dynamic-Memory VM just raises
how high the balloon driver is *allowed* to inflate to - the guest still
claims it based on actual demand. `resize_ram` reports this distinction
explicitly rather than implying an immediate change the way VMware's
hot-add genuinely is one.

**Hyper-V cold-path memory change preserves Dynamic Memory bounds.**
When the target VM already has Dynamic Memory enabled and the change
takes the cold path (a shrink, or a grow with the VM not running), the
existing Minimum/Maximum bounds are **widened** (never narrowed) around
the new Startup value - `Minimum = min(currentMinimum, target)`,
`Maximum = max(currentMaximum, target)` - so `Set-VMMemory` never gets
handed an inconsistent Min/Startup/Max combination. A static-memory VM
just gets its Startup value changed directly.

**Known gap: SCVMM's cold-path memory change does not manage Dynamic
Memory bounds.** `resize_ram_scvmm` calls `Set-SCVirtualMachine -MemoryMB`
with a flat value only - unlike the native Hyper-V path above, it
doesn't widen an existing Dynamic Memory Minimum/Maximum around the new
target, because SCVMM's read-side property names for the current bounds
weren't confirmed reliably enough to script against safely. An operator
managing Dynamic Memory bounds on an SCVMM-managed VM should adjust them
directly (SCVMM console, or `Set-SCVirtualMachine -DynamicMemory*`)
rather than through this playbook, for now.

### Resize-blocking conditions checked in preflight

| Condition | VMware | Hyper-V |
|---|---|---|
| VM = template | `hw_is_template = true` | — |
| `vcpu_count` not an exact multiple of `vcpu_cores_per_socket` | hard requirement (whole number of sockets) | — (Hyper-V has no cores-per-socket split, the var is ignored) |
| vCPU count at/above the policy cap | `compute_cpu_max_count` (default 32) | same |
| Memory outside the policy floor/cap | `compute_ram_min_gb` / `compute_ram_max_gb` (default 1 / 512 GB) | same |
| Clustered (highly-available) VM, owner node ≠ detected host | — | `Get-ClusterGroup -Name <vm>` → `OwnerNode` ≠ `compute_hyperv_host` - **hard failure, no override possible** (signals an in-progress failover) |
| Clustered (highly-available) VM, cold-path change, no override | — | same, without `-e compute_allow_clustered_vm=true` - **not required for a live change**, since only the cold path power-cycles the VM and introduces failover risk |

Cluster detection uses the exact same technique as `ansible-resizedisk`
and `ansible-snapshot` (`Get-ClusterGroup`) - see those projects' READMEs
for the full reasoning; it isn't repeated here. Same caveat applies:
best-effort, silently unverifiable (`ClusterCheckAvailable = false`) if
the `FailoverClusters` module isn't installed on the Hyper-V host.

**SCVMM integration.** When `compute_managed_by_scvmm` is true, only the
final change action changes (`Set-SCVirtualMachine` instead of the
native Hyper-V cmdlets) - the preflight checks above still query
`compute_hyperv_host` directly via Hyper-V PowerShell, not through SCVMM,
same reasoning as the other two projects' `*_scvmm` roles.

## Directory layout

```
ansible-resizecompute/
├── ansible.cfg
├── requirements.yml                          # required collections
├── .ansible-lint                             # basic profile, with our deliberate deviations documented
├── .yamllint                                 # yamllint config (max line length raised to 200)
├── inventory/
│   ├── hosts.yml.example                     # fleet of Hyper-V hosts to query
│   └── group_vars/all.yml                    # vCenter connection + policy caps/margins
├── playbooks/
│   ├── resize_cpu.yml
│   └── resize_ram.yml
├── scripts/
│   ├── extract_embedded_scripts.py           # pulls embedded PowerShell out into standalone files (for CI)
│   └── PSScriptAnalyzerSettings.psd1         # documented excluded rules
└── roles/
    ├── preflight_platform/                   # VM? VMware or Hyper-V? SCVMM-managed?
    ├── compute_lock/                         # per-VM lock (acquire/release), anti double-run
    ├── preflight_cpu_constraints/
    ├── resize_cpu_vmware/ , resize_cpu_hyperv/ , resize_cpu_scvmm/
    ├── preflight_ram_constraints/
    └── resize_ram_vmware/ , resize_ram_hyperv/ , resize_ram_scvmm/
```

## Continuous integration

- **`.github/workflows/ansible-resizecompute-ci.yml`** (triggered on
  changes under `ansible-resizecompute/`): `yamllint`, `ansible-lint`
  (`basic` profile), and `ansible-playbook --syntax-check` against both
  playbooks. No `shellcheck` job — like `ansible-snapshot`, this project
  has no guest-touching bash at all.
- **`.github/workflows/powershell-quality.yml`** (pre-existing at the
  repo level, extended here alongside the other two projects' entries):
  `scripts/extract_embedded_scripts.py` pulls the Jinja-templated
  PowerShell out of the role task YAML into standalone `.ps1` files,
  then `PSScriptAnalyzer` runs against those with
  `scripts/PSScriptAnalyzerSettings.psd1`.

Every `win_shell` task in this project uses the explicit `cmd: |` form
rather than the "free-form" form, from the start - see
`ansible-resizedisk`'s README for the real Ansible parsing bug that
convention avoids.

## Prerequisites

- Ansible >= 2.15
- Collections: `ansible-galaxy collection install -r requirements.yml`
  (`community.vmware`, `ansible.windows`, `community.windows`)
- `pyvmomi` and `pywinrm` installed on the control node (or the AWX
  execution environment image)
- vCenter service account with read access to the inventory and
  reconfigure rights on the relevant VMs
- Hyper-V host service account with rights to manage VM processor/memory
  configuration and power state (`Set-VMProcessor`/`Set-VMMemory`/
  `Stop-VM`/`Start-VM`)
- **VMware CPU/Memory Hot Add**: must already be enabled on the VM (an
  operator action, outside this playbook - see "Hot vs. cold path"
  above) for a live grow to be attempted at all; otherwise every change
  falls back to the cold path automatically, no separate configuration
  needed on this playbook's side.
- **VMware cold path**: requires VMware Tools running in the guest for
  the graceful `shutdown-guest` power operation to succeed. Without it,
  the shutdown step fails/times out rather than falling back to a hard
  power-off - a deliberate choice to avoid an unclean stop by default.
- **Clustered Hyper-V (CSV)**: the `FailoverClusters` PowerShell module
  must be installed on `compute_hyperv_host` for clustered-VM detection
  to work. Service account with read access to the cluster.
- **SCVMM** (if `scvmm_server` is configured): the `virtualmachinemanager`
  PowerShell module must be installed on `scvmm_server`, and the service
  account needs the SCVMM rights required for `Get-SCVirtualMachine`/
  `Set-SCVirtualMachine`/`Stop-SCVirtualMachine`/`Start-SCVirtualMachine`.
  Without `scvmm_server` configured, this project always uses the native
  Hyper-V cmdlets.

## Usage

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml: the list of Hyper-V hosts to query
# edit inventory/group_vars/all.yml: vCenter connection (credentials via vault)

ansible-galaxy collection install -r requirements.yml
```

Grow CPU:

```bash
ansible-playbook playbooks/resize_cpu.yml \
  -e vm_name=WINSRV01 -e vcpu_count=8 \
  --vault-password-file .vault_pass
```

Shrink RAM (always a power-cycle - see the decision table above):

```bash
ansible-playbook playbooks/resize_ram.yml \
  -e vm_name=WINSRV01 -e memory_gb=16 \
  --vault-password-file .vault_pass
```

### ServiceNow integration

Typical use case: a ServiceNow *Catalog Item* / *Change Request* triggers,
via **Ansible Automation Platform** (job template + webhook) or a **MID
Server** running `ansible-playbook` directly, a call to `resize_cpu`
and/or `resize_ram` with the CI's attributes as extra-vars (`vm_name`,
`vcpu_count`/`memory_gb`, ...). The result (`compute_summary` via
`set_stats`, or the job's exit code) lets ServiceNow update the
associated ticket/task - in particular `power_cycled`, so the change
window/downtime communicated to the requester matches what actually
happened (a live Hot Add change vs. a scheduled reboot).

## Variables

### Required (extra-vars, supplied by the calling workflow)

| Variable | Used by | Description |
|---|---|---|
| `vm_name` | both | Name of the CI / VM, as known to vCenter and/or Hyper-V |
| `vcpu_count` | `resize_cpu` | Target vCPU count |
| `memory_gb` | `resize_ram` | Target memory size in GB |

### Optional

| Variable | Default | Used by | Description |
|---|---|---|---|
| `hypervisor_type` | auto-detected | both | `vmware` or `hyperv`, to skip the search |
| `managed_by_scvmm` | auto-detected if `scvmm_server` is configured | both | `true`/`false`, to skip SCVMM detection |
| `vcpu_cores_per_socket` | `1` | `resize_cpu` | VMware only - cores per socket topology |
| `compute_cpu_max_count` | `32` | `resize_cpu` | policy cap against a mistyped vCPU count |
| `compute_ram_min_gb` / `compute_ram_max_gb` | `1` / `512` | `resize_ram` | policy floor/cap against a mistyped memory size |
| `compute_allow_clustered_vm` | `false` | both | `true` to cold-path-change a clustered Hyper-V VM once coordination has been done manually (has no effect if the owner node has changed, and not required for a live change - see above) |
| `compute_poweroff_timeout_seconds` | `300` | both | how long to wait for a graceful shutdown before giving up |
| `compute_lock_timeout_seconds` | `1800` | both | delay before a per-VM lock is considered abandoned (crashed run) and can be broken by a new run |

### Per environment (`inventory/group_vars/all.yml`)

| Variable | Description |
|---|---|
| `vcenter_hostname` / `vcenter_username` / `vcenter_password` / `vcenter_datacenter` | vCenter API connection (a single one, for the whole VMware estate) |
| `scvmm_server` / `scvmm_username` / `scvmm_password` | optional SCVMM server (`inventory_hostname` of the `scvmm_management` group); leaving `scvmm_server` empty disables SCVMM detection entirely |
| `hyperv_hypervisor` group (inventory) | fleet of Hyper-V hosts to query when locating a VM |

These variables (and the "Optional" defaults above) live at this level
rather than in role `defaults/` for the same reason as the other two
projects: `preflight_cpu_constraints`, `resize_cpu_vmware`, etc. are
separate roles included independently via `include_role`, which does
not share role-scoped defaults across role boundaries the way the
static `roles:` playbook keyword does.

See `inventory/hosts.yml.example` and each playbook's header for the
full detail.
