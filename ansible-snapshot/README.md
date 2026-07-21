# ansible-snapshot

Ansible playbooks to manage snapshots/checkpoints of a VM hosted on
**VMware** (vSphere/ESXi) or **Hyper-V** — create, list, remove, and
revert. Companion project to `ansible-resizedisk`, sharing its overall
design (ServiceNow-triggered, no static per-VM inventory, hypervisor
auto-detection, SCVMM awareness), but for a different operation:
snapshots are purely hypervisor-side, so unlike `ansible-resizedisk` this
project never connects to the guest OS at all — VMware Tools and
Hyper-V's VSS integration component handle guest-side consistency
(quiescing / application-consistent checkpoints) on their own.

Designed to be triggered by a **ServiceNow workflow** (Flow Designer /
Orchestration, via an AWX/Ansible Automation Platform job template, or a
MID Server): no static per-VM inventory - everything is driven by
extra-vars resolved from the CI/RITM/change request. Four separate
playbooks, one per action, so each can be exposed as its own ServiceNow
catalog item with its own approval/RBAC (reverting a VM is a very
different risk profile from listing its snapshots).

## How it works

All four playbooks share the same first two steps, then branch:

1. **`preflight_platform`** — identical role to `ansible-resizedisk`'s
   (adapted variable names, `snapshot_` instead of `resizedisk_`):
   validates that the target is actually a VM, detects the hypervisor
   (`snapshot_hypervisor_type`) and, for Hyper-V, whether the VM is
   **managed by SCVMM** (`snapshot_managed_by_scvmm`). Can be
   short-circuited with `hypervisor_type`/`managed_by_scvmm` extra-vars.
   Also validates that `vm_name` only contains a safe character set
   (letters, digits, space, `.`, `_`, `-`) — it's interpolated into
   single-quoted PowerShell string literals throughout this project, so
   this is a command-injection guardrail, not a real VMware/Hyper-V
   naming restriction.

2. **`snapshot_lock`** (mutating playbooks only — `snapshot_create`,
   `snapshot_remove`, `snapshot_revert`; `snapshot_list` is read-only and
   skips this) — takes a per-VM lock before any other action, same
   design as `ansible-resizedisk`'s lock (atomic file on Hyper-V,
   best-effort VM annotation marker on VMware), but its own namespace
   (`SNAPSHOT_LOCK` / `C:\ProgramData\ansible-snapshot\`) — **the two
   projects don't coordinate with each other**; running a disk resize
   and a snapshot revert against the same VM at the same time is still
   the operator's responsibility to avoid.

Then, per playbook:

### `snapshot_create`

3. **`preflight_snapshot_create_constraints`** — fails fast if the
   snapshot isn't safe/possible to create (see table below), including
   refusing a duplicate name (both platforms technically allow it, but
   this project's own remove/revert logic needs names to be unique to
   safely resolve a target).
4. **`snapshot_create_vmware`** / **`snapshot_create_scvmm`** /
   **`snapshot_create_hyperv`** — the actual creation call
   (`vmware_guest_snapshot` `state=present`, `New-SCVMCheckpoint`, or
   `Checkpoint-VM`, chosen the same way `ansible-resizedisk` picks
   between `resize_disk_scvmm`/`resize_disk_hyperv`).

### `snapshot_list`

3. **`snapshot_list_vmware`** / **`snapshot_list_hyperv`** — queries the
   VM's current snapshot tree and normalizes it into a common shape
   (`snapshot_list_result`: a flat list of `{id, name, description,
   creation_time, ...}`, plus `snapshot_list_current_id`) regardless of
   platform. Always queries the native Hyper-V cmdlets directly, **even
   for an SCVMM-managed VM** — listing is non-mutating, so there's no
   risk of SCVMM's database drifting out of sync the way there is for
   create/remove/revert, and `Get-VMSnapshot` doesn't need SCVMM's
   management layer to return an accurate answer. This same normalized
   shape is reused internally by `snapshot_remove`/`snapshot_revert` to
   resolve their target.

### `snapshot_remove`

3. **`preflight_snapshot_remove_constraints`** — resolves exactly one
   snapshot matching `snapshot_name` (or `snapshot_id` if given),
   refusing to guess if the name is ambiguous, and blocks removal on a
   clustered Hyper-V VM whose owner node has drifted since
   `preflight_platform` ran.
4. **`snapshot_remove_vmware`** / **`snapshot_remove_scvmm`** /
   **`snapshot_remove_hyperv`** — the actual removal call, always
   targeting the resolved snapshot by **id** (VMware) or a validated
   **GUID**/**name** (Hyper-V/SCVMM — see the security note below),
   never by re-interpolating raw user input.

### `snapshot_revert`

3. **`preflight_snapshot_revert_constraints`** — same target-resolution
   and cluster-placement logic as `snapshot_remove`'s constraints role,
   plus refuses to "revert" to the snapshot the VM is already running
   from, and — unless `snapshot_revert_safety_checkpoint` is set to
   `false` — names an automatic safety checkpoint
   (`pre-revert-<timestamp>`).
4. **The safety checkpoint** — `preflight_snapshot_create_constraints`
   followed by `snapshot_create_vmware`/`_scvmm`/`_hyperv` are
   re-included with `snapshot_name` overridden to that generated name,
   creating a checkpoint of the VM's **current** state immediately
   before the revert happens. Neither platform's API protects against
   this on its own — see the security/safety note below.
5. **`snapshot_revert_vmware`** / **`snapshot_revert_scvmm`** /
   **`snapshot_revert_hyperv`** — the actual revert call
   (`vmware_guest_snapshot` `state=revert`, `Restore-SCVMCheckpoint`, or
   `Restore-VMSnapshot`).

A structured summary (`snapshot_summary`) is published via
`ansible.builtin.set_stats` on every playbook — retrievable as an
AWX/Tower job *artifact* and therefore readable by ServiceNow on return
from the call.

**No automatic safety net for `snapshot_revert` in the underlying
platforms.** Hyper-V Manager's GUI has a "Create Checkpoint and Apply"
option that snapshots the VM's current state before applying an older
one — but there is no PowerShell/API equivalent (`Restore-VMSnapshot`
just applies the checkpoint directly and discards the current state for
good; confirmed against Microsoft's own docs, not assumed). VMware's
`state=revert` behaves the same way. `snapshot_revert_safety_checkpoint`
(default `true`) closes this gap at the Ansible level instead, since the
platforms themselves don't.

### Resolving a snapshot safely by name

Both `snapshot_remove` and `snapshot_revert` need to turn `snapshot_name`
(or `snapshot_id`) into exactly one snapshot before doing anything
destructive. This project's approach, deliberately more defensive than
just trusting the first match:

- **Both platforms technically allow duplicate snapshot names** —
  `snapshot_create` refuses to create one, but a snapshot taken outside
  this project (directly in vCenter/Hyper-V Manager) could still
  collide. If more than one snapshot matches, the playbook fails and
  lists the candidate `id`s rather than acting on the first one found —
  the community.vmware module (VMware) already fails this way natively;
  Hyper-V's `Remove-VMSnapshot -Name`/`Restore-VMSnapshot -Name` do
  **not**, so this project adds the same guarantee explicitly for
  Hyper-V.
- **`snapshot_name` (and `snapshot_description`) are interpolated into
  single-quoted PowerShell string literals** on the Hyper-V/SCVMM paths,
  so they're validated against a safe character set before use —
  otherwise a stray `'` or `;` would be a command-injection vector. This
  also rules out `*`/`?`, which `Remove-VMSnapshot -Name` treats as
  wildcards (could otherwise delete more than one checkpoint).
- Once `snapshot_remove`/`snapshot_revert` have resolved a **unique**
  target, they act on it via **id** wherever the platform supports that
  (VMware's `snapshot_id` module parameter — a typed argument, not a
  shell string, so no injection risk there at all), or a
  regex-validated **GUID** (Hyper-V's `Get-VMSnapshot | Where-Object
  {$_.Id -eq ...}`) — sidestepping the need to re-interpolate a name a
  second time. SCVMM's checkpoint objects aren't confirmed to expose the
  same GUID as the underlying Hyper-V checkpoint, so that one path still
  matches by (validated) name.

### Resize-blocking conditions checked in preflight

| Condition | VMware | Hyper-V |
|---|---|---|
| Duplicate snapshot name (create only) | any snapshot on the VM already has this name | same |
| VM = template (create only) | `hw_is_template = true` | — |
| Memory-included snapshot on a powered-off VM (create only) | `hw_power_status != 'poweredOn'` | — (Hyper-V always includes memory automatically when running, no separate flag) |
| Quiesce requested without a running VM + active Tools (create only) | `hw_power_status != 'poweredOn'` or `guest_tools_status != 'guestToolsRunning'` | — |
| Quiesce requested but the VM's `CheckpointType` can't honor it (create only) | — | `CheckpointType not in ['Production', 'ProductionOnly']` |
| Checkpoints disabled on the VM (create only) | — | `CheckpointType == 'Disabled'` |
| Pass-through (physical) disk attached anywhere on the VM (create only) | — | any `VMHardDiskDrive.Path` empty |
| Shared VHDX used as a guest-cluster CSV (create only) | — | any `VMHardDiskDrive.SupportPersistentReservations = true` |
| Snapshot count at/above the policy cap (create only) | `snapshot_vmware_max_count` (default 3) | `snapshot_hyperv_max_count` (default 50, Hyper-V's own hard ceiling) |
| Datastore low on free space (create only) | `freeSpace` < `snapshot_datastore_free_margin_gb` | — (AVHDX lands on whatever volume already hosts the parent VHD/VHDX) |
| No snapshot matches the given name/id (remove, revert) | module fails natively | explicit "no match" check |
| More than one snapshot matches the given name (remove, revert) | module fails natively | explicit "ambiguous match" check |
| Reverting to the snapshot already running (revert only) | — | — (checked in Ansible, both platforms: `snapshot_list_current_id`) |
| Clustered (highly-available) VM, owner node ≠ detected host (all mutating actions) | — | `Get-ClusterGroup -Name <vm>` → `OwnerNode` ≠ `snapshot_hyperv_host` - **hard failure, no override possible** (signals an in-progress failover) |
| Clustered (highly-available) VM, no override (all mutating actions) | — | same, without `-e snapshot_allow_clustered_vm=true` |
| Degraded S2D/pooled storage (create only) | — | `Get-StoragePool`/`Get-PhysicalDisk` → `HealthStatus != 'Healthy'` on a non-primordial pool or a physical disk |

**Hyper-V CSV cluster and S2D checks** use the exact same technique as
`ansible-resizedisk` (`Get-ClusterGroup`, `Get-StoragePool`/
`Get-PhysicalDisk`) — see that project's README for the full reasoning;
it isn't repeated here. Same caveat applies: cluster detection is
best-effort, silently unverifiable (`ClusterCheckAvailable = false`) if
the `FailoverClusters` module isn't installed on the Hyper-V host.

**SCVMM integration.** When `snapshot_managed_by_scvmm` is true, only the
final create/remove/revert action changes (`New-`/`Remove-`/
`Restore-SCVMCheckpoint` instead of the native Hyper-V cmdlets) — the
preflight checks above still query `snapshot_hyperv_host` directly via
Hyper-V PowerShell, not through SCVMM, same reasoning as
`ansible-resizedisk`'s `resize_disk_scvmm`. `snapshot_list` never routes
through SCVMM at all (see "How it works" above).

**Quiesce and memory options, in detail.** VMware and Hyper-V expose
consistency options very differently:
- **VMware**: `snapshot_quiesce` (needs VMware Tools running) and
  `snapshot_include_memory` are independent per-call flags, passed
  straight through to `vmware_guest_snapshot`.
- **Hyper-V**: consistency is governed by the VM's own `CheckpointType`
  setting (`Set-VM -CheckpointType Standard|Production|ProductionOnly|
  Disabled`), which applies to **every** checkpoint taken on that VM,
  not just this one call. This project deliberately **never changes
  it** — `snapshot_quiesce=true` only checks that the current
  `CheckpointType` would actually honor the request and fails clearly
  if not, rather than silently taking a lesser (Standard) checkpoint or
  reaching into a persistent VM setting an operator didn't ask to
  change. An operator has to run `Set-VM -CheckpointType Production`
  themselves first. There's also no separate "include memory" flag on
  Hyper-V: a Standard checkpoint of a running VM always includes memory
  state automatically.

## Supported versions

Snapshot/checkpoint operations don't touch the guest OS at all (no
WinRM/SSH, no Python/PowerShell version requirements on the guest side)
— compatibility is purely a function of the **hypervisor**, not the
guest OS or its version. Any VMware vSphere/ESXi version reachable
through `community.vmware`, and any Hyper-V host from Windows Server
2012 onward (checkpoints/`Get-VMSnapshot` exist since Server 2012;
`CheckpointType`/Production checkpoints since Server 2016), is supported
regardless of what guest OS - and how old a version of it - is installed
inside the VM.

## Directory layout

```
ansible-snapshot/
├── ansible.cfg
├── requirements.yml                          # required collections (pinned <8.0.0, see note in the file)
├── .ansible-lint                             # basic profile, with our deliberate deviations documented
├── .yamllint                                 # yamllint config (max line length raised to 200)
├── inventory/
│   ├── hosts.yml.example                     # fleet of Hyper-V hosts to query
│   └── group_vars/all.yml                    # vCenter connection + policy caps/margins
├── playbooks/
│   ├── snapshot_create.yml
│   ├── snapshot_list.yml
│   ├── snapshot_remove.yml
│   └── snapshot_revert.yml
├── scripts/
│   ├── extract_embedded_scripts.py           # pulls embedded PowerShell out into standalone files (for CI)
│   └── PSScriptAnalyzerSettings.psd1         # documented excluded rules
└── roles/
    ├── preflight_platform/                   # VM? VMware or Hyper-V? SCVMM-managed?
    ├── snapshot_lock/                        # per-VM lock (acquire/release), anti double-run
    ├── snapshot_list_vmware/ , snapshot_list_hyperv/
    ├── preflight_snapshot_create_constraints/
    ├── snapshot_create_vmware/ , snapshot_create_hyperv/ , snapshot_create_scvmm/
    ├── preflight_snapshot_remove_constraints/
    ├── snapshot_remove_vmware/ , snapshot_remove_hyperv/ , snapshot_remove_scvmm/
    ├── preflight_snapshot_revert_constraints/
    └── snapshot_revert_vmware/ , snapshot_revert_hyperv/ , snapshot_revert_scvmm/
```

## Continuous integration

- **`.github/workflows/ansible-snapshot-ci.yml`** (triggered on changes
  under `ansible-snapshot/`): `yamllint`, `ansible-lint` (`basic`
  profile), and `ansible-playbook --syntax-check` against all four
  playbooks. No `shellcheck` job here — unlike `ansible-resizedisk`, this
  project has no guest-touching bash at all.
- **`.github/workflows/powershell-quality.yml`** (pre-existing at the
  repo level, extended here alongside `ansible-resizedisk`'s entry):
  `scripts/extract_embedded_scripts.py` pulls the Jinja-templated
  PowerShell out of the role task YAML into standalone `.ps1` files
  (Jinja `{{ ... }}` placeholders replaced with a plain number), then
  `PSScriptAnalyzer` runs against those with
  `scripts/PSScriptAnalyzerSettings.psd1`.

Every `win_shell` task in this project uses the explicit `cmd: |` form
rather than the "free-form" form — `ansible-resizedisk` hit a real
Ansible parsing bug with free-form PowerShell containing Jinja braces
when a role is loaded in isolation (exactly what `ansible-lint` does);
this project was written with the `cmd:` form from the start to avoid
that bug class entirely rather than relying on always using
`include_role`.

## Prerequisites

- Ansible >= 2.15
- Collections: `ansible-galaxy collection install -r requirements.yml`
  (`community.vmware`, `ansible.windows`, `community.windows`)
- `pyvmomi` and `pywinrm` installed on the control node (or the AWX
  execution environment image)
- vCenter service account with read access to the inventory and
  snapshot-management rights on the relevant VMs
- Hyper-V host service account with rights to manage checkpoints
  (`Checkpoint-VM`/`Remove-VMSnapshot`/`Restore-VMSnapshot`)
- **Quiesced VMware snapshots**: requires VMware Tools running in the
  guest. Without it, `snapshot_quiesce=true` is refused at preflight
  rather than silently taking a crash-consistent snapshot.
- **Production (application-consistent) Hyper-V checkpoints**: requires
  the VM's `CheckpointType` to already be set to `Production`/
  `ProductionOnly` (an operator action, outside this playbook — see
  "Quiesce and memory options" above) and, in the guest, VSS (Windows)
  or the Hyper-V Linux Integration Services' `fsfreeze` support (modern
  Linux kernels).
- **Clustered Hyper-V (CSV)**: the `FailoverClusters` PowerShell module
  must be installed on `snapshot_hyperv_host` for clustered-VM detection
  to work. Service account with read access to the cluster.
- **SCVMM** (if `scvmm_server` is configured): the `virtualmachinemanager`
  PowerShell module must be installed on `scvmm_server`, and the service
  account needs the SCVMM rights required for `Get-SCVirtualMachine`/
  `New-`/`Remove-`/`Restore-SCVMCheckpoint`. Without `scvmm_server`
  configured, this project always uses the native Hyper-V cmdlets.

## Usage

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml: the list of Hyper-V hosts to query
# edit inventory/group_vars/all.yml: vCenter connection (credentials via vault)

ansible-galaxy collection install -r requirements.yml
```

Create:

```bash
ansible-playbook playbooks/snapshot_create.yml \
  -e vm_name=WINSRV01 -e snapshot_name=pre-patch \
  -e snapshot_description="Before July patch Tuesday" \
  --vault-password-file .vault_pass
```

List:

```bash
ansible-playbook playbooks/snapshot_list.yml -e vm_name=WINSRV01
```

Remove:

```bash
ansible-playbook playbooks/snapshot_remove.yml \
  -e vm_name=WINSRV01 -e snapshot_name=pre-patch \
  --vault-password-file .vault_pass
```

Revert (with the automatic safety checkpoint left on by default):

```bash
ansible-playbook playbooks/snapshot_revert.yml \
  -e vm_name=WINSRV01 -e snapshot_name=pre-patch \
  --vault-password-file .vault_pass
```

### ServiceNow integration

Typical use case: a ServiceNow *Catalog Item* / *Change Request* triggers,
via **Ansible Automation Platform** (job template + webhook) or a **MID
Server** running `ansible-playbook` directly, a call to one of the four
playbooks with the CI's attributes as extra-vars (`vm_name`,
`snapshot_name`, ...). The result (`snapshot_summary` via `set_stats`, or
the job's exit code) lets ServiceNow update the associated ticket/task.
Exposing each action as a separate catalog item/job template (rather
than one generic "manage snapshot" item with an action parameter) lets
RBAC differ per action — `snapshot_list` is read-only and low-risk;
`snapshot_revert` discards changes and warrants a stricter approval
chain.

## Variables

### Required (extra-vars, supplied by the calling workflow)

| Variable | Used by | Description |
|---|---|---|
| `vm_name` | all | Name of the CI / VM, as known to vCenter and/or Hyper-V |
| `snapshot_name` | create; remove/revert (or `snapshot_id`) | Name of the snapshot/checkpoint. Letters, digits, space, `.`, `_`, `-` only (1-80 chars) |

### Optional

| Variable | Default | Used by | Description |
|---|---|---|---|
| `hypervisor_type` | auto-detected | all | `vmware` or `hyperv`, to skip the search |
| `managed_by_scvmm` | auto-detected if `scvmm_server` is configured | all | `true`/`false`, to skip SCVMM detection |
| `snapshot_id` | — | remove, revert | VMware: numeric snapshot id. Hyper-V: checkpoint GUID. Disambiguates when `snapshot_name` alone matches more than one snapshot |
| `snapshot_description` | `""` | create | VMware only — Hyper-V checkpoints have no description field |
| `snapshot_include_memory` | `false` | create | VMware only — capture running memory state (needs the VM powered on) |
| `snapshot_quiesce` | `false` | create | VMware: quiesce via VMware Tools. Hyper-V: only validated against the VM's current `CheckpointType`, never sets it |
| `snapshot_remove_children` | `false` | remove | VMware: `remove_children` module param. Hyper-V: `-IncludeAllChildSnapshots` |
| `snapshot_revert_safety_checkpoint` | `true` | revert | `false` to skip the automatic pre-revert safety checkpoint |
| `snapshot_vmware_max_count` / `snapshot_hyperv_max_count` | `3` / `50` | create | policy caps on existing snapshot count before refusing to create another |
| `snapshot_datastore_free_margin_gb` | `10` | create | safety margin required on the VMware datastore backing the VM |
| `snapshot_allow_clustered_vm` | `false` | create, remove, revert | `true` to act on a clustered Hyper-V VM once coordination has been done manually (has no effect if the owner node has changed — see above) |
| `snapshot_lock_timeout_seconds` | `1800` | create, remove, revert | delay before a per-VM lock is considered abandoned (crashed run) and can be broken by a new run |
| `disk_controller_number` / `disk_unit_number` | `0` / `0` | create | which VMware disk's datastore to check for free space |

### Per environment (`inventory/group_vars/all.yml`)

| Variable | Description |
|---|---|
| `vcenter_hostname` / `vcenter_username` / `vcenter_password` / `vcenter_datacenter` | vCenter API connection (a single one, for the whole VMware estate) |
| `scvmm_server` / `scvmm_username` / `scvmm_password` | optional SCVMM server (`inventory_hostname` of the `scvmm_management` group); leaving `scvmm_server` empty disables SCVMM detection entirely |
| `hyperv_hypervisor` group (inventory) | fleet of Hyper-V hosts to query when locating a VM |

These variables (and the "Optional" defaults above) live at this level
rather than in role `defaults/` for the same reason as
`ansible-resizedisk`: `preflight_snapshot_create_constraints`,
`snapshot_create_vmware`, etc. are separate roles included independently
via `include_role`, which does not share role-scoped defaults across
role boundaries the way the static `roles:` playbook keyword does.

See `inventory/hosts.yml.example` and each playbook's header for the
full detail.
