# ansible-deletevm

Ansible playbooks to decommission and permanently delete a VM on
**VMware** (vSphere/ESXi) or **Hyper-V**. Fifth project in this series
alongside `ansible-resizedisk`, `ansible-snapshot`, `ansible-resizecompute`
and `ansible-createvm`, sharing their overall design (ServiceNow-
triggered, hypervisor auto-detection, per-VM locking, SCVMM awareness).

Three playbooks supporting an optional **two-phase decommission**
workflow - stop the VM now, delete it later, or change your mind before
that happens:

- **`decommission_stop.yml`** — gracefully stops the VM and marks it for
  deletion at a later date, recording the driving ServiceNow ticket as a
  note on the VM itself. Does not delete anything.
- **`decommission_cancel.yml`** — the rollback: removes that marker and
  restores the VM to the power state it was in before `decommission_stop`
  touched it. Only undoes the *stop-and-mark* half of the workflow - see
  "Rollback" below for why an actual deletion has no equivalent.
- **`delete_vm.yml`** — permanently deletes the VM and its disk files.
  **Does not require the VM to already be powered off** - it handles
  that itself, gracefully, as part of its own execution. All three
  playbooks are independent, not a strict sequence: running
  `delete_vm.yml` directly against a running VM works fine on its own;
  `decommission_stop.yml` is there for when a grace period between
  "stop" and "actually delete" is wanted, not a required first step.

The one hard, non-negotiable gate on `delete_vm.yml` is
`confirm_delete=true`.

## How it works

Both playbooks share the same first two steps, then branch:

1. **`preflight_platform`** — identical role to the other four projects'
   (adapted variable names, `deletevm_` instead of `resizedisk_`/
   `snapshot_`/`compute_`): validates that the target is actually a VM,
   detects the hypervisor (`deletevm_hypervisor_type`) and, for Hyper-V,
   whether it's **managed by SCVMM** (`deletevm_managed_by_scvmm`, fully
   optional here - see "SCVMM is optional" below). Same `vm_name`
   safe-charset validation as the other projects.

2. **`delete_vm_lock`** — takes a per-VM lock before any other action,
   same design as the other projects' locks (atomic file on Hyper-V,
   best-effort VM annotation marker on VMware), own namespace
   (`DELETEVM_LOCK` / `C:\ProgramData\ansible-deletevm\`) - none of these
   projects coordinate with each other.

Then, per playbook:

### `decommission_stop`

3. **`preflight_decommission_constraints`** — validates
   `vm_delete_scheduled_at` looks like a date and `servicenow_ticket` is
   supplied and safe to interpolate into PowerShell, records the VM's
   *current* power state (`deletevm_was_running` - captured here,
   before anything touches it, specifically so `decommission_cancel`
   can restore exactly that state later rather than blindly powering
   the VM back on), and blocks on a clustered Hyper-V VM whose owner
   node has drifted or that hasn't been explicitly signed off (stopping
   a clustered VM here bypasses cluster orchestration).
4. **`decommission_stop_vmware`** / **`decommission_stop_scvmm`** /
   **`decommission_stop_hyperv`** — gracefully shuts the VM down (if
   running) and writes a
   `DECOMMISSION_SCHEDULED:<date>:<ticket>:<was_running>:<reason>`
   marker into the VM's annotation (VMware) / Notes (Hyper-V) / SCVMM
   Description field, **preserving any existing content** in that field
   (only the marker itself is replaced on a re-run, e.g. to push the
   date back or correct the ticket number). Nothing is deleted.

### `decommission_cancel`

3. **`preflight_cancel_constraints`** — reads whichever field
   `decommission_stop` would have written into, parses the marker, and
   **fails clearly if there isn't one** - the guardrail against rolling
   back a VM that was never actually marked for deletion (e.g. a
   `vm_name` typo that happens to match a real, unrelated VM).
4. **`decommission_cancel_vmware`** / **`decommission_cancel_scvmm`** /
   **`decommission_cancel_hyperv`** — removes the marker (preserving any
   other content in the field, same as the write side) and powers the VM
   back on **only if** the parsed marker says it was running before
   `decommission_stop` ran; a VM that was already off stays off.

### `delete_vm`

3. **`preflight_delete_constraints`** — requires `confirm_delete=true`
   (the one hard gate on this playbook), blocks on a clustered Hyper-V
   VM whose owner node has drifted or that hasn't been explicitly signed
   off, and **reports** (never blocks on) any snapshots/checkpoints that
   will be destroyed along with the VM, and any prior
   `decommission_stop` marker found on it.
4. **`delete_vm_vmware`** / **`delete_vm_scvmm`** / **`delete_vm_hyperv`**
   — gracefully shuts the VM down if it's still running, then permanently
   deletes it and its disk files. See "Platform differences, in detail"
   below for what each path actually does and why they're not identical.

A structured summary (`deletevm_summary`) is published via
`ansible.builtin.set_stats` on both playbooks — retrievable as an
AWX/Tower job *artifact* and therefore readable by ServiceNow on return
from the call.

### `vm_delete_scheduled_at` does not itself delay anything

Same design as `ansible-resizecompute`'s `vm_restart_scheduled_at`:
`decommission_stop` requires and records the date, but neither playbook
in this project waits for it, polls for it, or enforces it against the
current time. It's a required confirmation that a deletion date was
actually chosen (for the audit trail and for whoever finds the VM
stopped and wonders why), not a scheduling mechanism - actually running
`delete_vm.yml` *on* that date is the calling workflow's job (an
AWX/Tower job scheduled for that date, or a ServiceNow Scheduled Job).

### Rollback

`decommission_cancel.yml` is the rollback for `decommission_stop.yml` -
before `delete_vm.yml` has run, it fully reverses the stop-and-mark step
(remove the marker, restore the prior power state). **There is no
equivalent rollback for `delete_vm.yml` itself.** Once a VM has actually
been deleted - its configuration and disk files removed - there is
nothing left in this project's control to restore it from. If
`delete_vm.yml` already ran, the only way back is a backup/restore
process outside this project's scope (this project doesn't take or
manage backups). This asymmetry is deliberate, not a gap: the two-phase
workflow (`decommission_stop` → grace period → `delete_vm`) exists
precisely so that "rollback" is possible for as long as it's meaningful
to offer it, and stops being offered exactly where it would otherwise be
a false promise.

`decommission_cancel_hyperv`/`decommission_cancel_scvmm` interpolate the
*existing* Notes/Description content back into a PowerShell here-string
rather than a plain quoted string (the same technique used for passwords
elsewhere in this series) - that field can contain arbitrary text an
operator typed in previously, unvalidated, so it needs the same
injection-safe handling as any other free-form input reaching a
PowerShell script.

### Why snapshots/checkpoints don't block deletion

Every other playbook in this series that touches a disk or a snapshot
(`ansible-resizedisk`, `ansible-snapshot`) treats existing
snapshots/checkpoints as a blocking condition, because they represent a
technical incompatibility with the operation being attempted (you can't
safely resize a VHDX with checkpoints, for instance). Deletion is
different: destroying the VM's snapshots along with the VM itself is the
*expected* outcome, not a misconfiguration to guard against - blocking
here would just get in the way of the playbook's actual purpose.
`preflight_delete_constraints` reports them (so nobody deletes a VM
without realizing it had uncommitted snapshot state) but never refuses
to proceed because of them.

### Platform differences, in detail

**VMware** (`delete_vm_vmware`): a graceful `shutdown-guest` (if
running), then `community.vmware.vmware_guest` `state=absent` with
`force: true`. `force` here is a safety-net fallback, not the primary
mechanism - it powers the VM off (hard, if necessary) before deleting
only if the graceful shutdown above didn't already leave it off (e.g. it
timed out). The module deletes the VM's disk files from the datastore as
part of removing it - no separate cleanup step needed.

**Hyper-V, native** (`delete_vm_hyperv`): `Remove-VM` does **not**
delete the VM's VHD/VHDX files on its own - confirmed against current
behavior, not assumed. This role captures every attached disk's path
*before* removing the VM, then deletes those files itself afterwards;
skipping this would silently leave storage behind, defeating half the
point of a decommission. It also does not refuse on a clustered VM the
way `Remove-VM` alone would - if the VM is still a member of a Failover
Cluster role (checked in `preflight_delete_constraints`, which already
blocks on a stale owner node or a missing override), the cluster role is
removed first (`Remove-ClusterGroup -RemoveResources`) before `Remove-VM`
runs; that cmdlet only removes cluster *management* of the VM, it
doesn't touch the VM itself.

**Hyper-V, via SCVMM** (`delete_vm_scvmm`): `Remove-SCVirtualMachine`,
**with no `-Force` switch** - a genuinely dangerous gotcha caught while
building this. On `Remove-VM`, `-Force` means "don't prompt for
confirmation." On `Remove-SCVirtualMachine`, per Microsoft's own
documentation, `-Force` means something entirely different: *"this
cmdlet only deletes the virtual machine from the VMM database. It does
not delete the virtual machine itself."* Passing it here would have made
this role silently leave the real VM and its disks behind while
reporting success - the exact opposite of what a delete playbook is for.
Plain `Remove-SCVirtualMachine` (no extra switches) already deletes the
VM record, all its files, and removes it from the host in one step -
confirmed from the same documentation, which is also why this role
doesn't need its own separate disk-cleanup step the way the native
Hyper-V path does.

## Directory layout

```
ansible-deletevm/
├── ansible.cfg
├── requirements.yml                          # required collections
├── .ansible-lint                             # basic profile, with our deliberate deviations documented
├── .yamllint                                 # yamllint config (max line length raised to 200)
├── inventory/
│   ├── hosts.yml.example                     # fleet of Hyper-V hosts + optional scvmm_management group
│   └── group_vars/all.yml                    # vCenter/SCVMM connection + policy vars
├── playbooks/
│   ├── decommission_stop.yml
│   ├── decommission_cancel.yml
│   └── delete_vm.yml
├── scripts/
│   ├── extract_embedded_scripts.py           # pulls embedded PowerShell out into standalone files (for CI)
│   └── PSScriptAnalyzerSettings.psd1         # documented excluded rules
└── roles/
    ├── preflight_platform/                   # VM? VMware or Hyper-V? SCVMM-managed?
    ├── delete_vm_lock/                       # per-VM lock (acquire/release), anti double-run
    ├── preflight_decommission_constraints/
    ├── decommission_stop_vmware/ , decommission_stop_hyperv/ , decommission_stop_scvmm/
    ├── preflight_cancel_constraints/
    ├── decommission_cancel_vmware/ , decommission_cancel_hyperv/ , decommission_cancel_scvmm/
    ├── preflight_delete_constraints/
    └── delete_vm_vmware/ , delete_vm_hyperv/ , delete_vm_scvmm/
```

## Continuous integration

- **`.github/workflows/ansible-deletevm-ci.yml`** (triggered on changes
  under `ansible-deletevm/`): `yamllint`, `ansible-lint` (`basic`
  profile), and `ansible-playbook --syntax-check` against all three
  playbooks. No `shellcheck` job - this project has no guest-touching
  bash.
- **`.github/workflows/powershell-quality.yml`** (pre-existing at the
  repo level, extended here alongside the other four projects' entries):
  `scripts/extract_embedded_scripts.py` pulls the Jinja-templated
  PowerShell out of the role task YAML into standalone `.ps1` files,
  then `PSScriptAnalyzer` runs against those with
  `scripts/PSScriptAnalyzerSettings.psd1`.

## Prerequisites

- Ansible >= 2.15
- Collections: `ansible-galaxy collection install -r requirements.yml`
  (`community.vmware`, `ansible.windows`, `community.windows`)
- `pyvmomi` and `pywinrm` installed on the control node (or the AWX
  execution environment image)
- vCenter service account with rights to power off and delete VMs
- Hyper-V host service account with rights to stop/remove VMs and delete
  files on the volume(s) hosting their VHD/VHDX
- **SCVMM** (optional - see "SCVMM is optional" below): the
  `virtualmachinemanager` PowerShell module must be installed on
  `scvmm_server`, and the service account needs rights to stop/remove
  VMs.
- **Clustered Hyper-V (CSV)**: the `FailoverClusters` PowerShell module
  must be installed on the Hyper-V host for clustered-VM detection to
  work, and the service account needs rights to remove a cluster role
  (`Remove-ClusterGroup`).

### SCVMM is optional

Unlike `ansible-createvm` (where SCVMM is a hard requirement for
Hyper-V - native Hyper-V has no template/customization API of its own),
stopping and removing a VM are both things native Hyper-V can do
perfectly well unassisted. `scvmm_server` here only changes *which* API
performs the same action, so SCVMM's inventory doesn't drift out of sync
with a VM it thinks it still manages - it's about consistency, not
capability. Leave it unconfigured and this project always uses the
native Hyper-V cmdlets.

## Usage

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml: the list of Hyper-V hosts (+ scvmm_management if used)
# edit inventory/group_vars/all.yml: vCenter/SCVMM connection (credentials via vault)

ansible-galaxy collection install -r requirements.yml
```

Two-phase: stop now, delete later:

```bash
ansible-playbook playbooks/decommission_stop.yml \
  -e vm_name=WINSRV01 -e vm_delete_scheduled_at=2026-08-15 \
  -e servicenow_ticket=CHG0012345 -e decommission_reason='app retired' \
  --vault-password-file .vault_pass

# ... grace period elapses (whatever process/schedule triggers this next run) ...

ansible-playbook playbooks/delete_vm.yml \
  -e vm_name=WINSRV01 -e confirm_delete=true \
  --vault-password-file .vault_pass
```

Changed your mind before that second run happens:

```bash
ansible-playbook playbooks/decommission_cancel.yml \
  -e vm_name=WINSRV01 \
  --vault-password-file .vault_pass
```

One-shot, immediate deletion (no prior `decommission_stop` needed - the
VM can even still be running):

```bash
ansible-playbook playbooks/delete_vm.yml \
  -e vm_name=WINSRV01 -e confirm_delete=true \
  --vault-password-file .vault_pass
```

### ServiceNow integration

Typical use case: a ServiceNow *Change Request* / decommission workflow
triggers, via **Ansible Automation Platform** (job template + webhook)
or a **MID Server** running `ansible-playbook` directly, a call to
`decommission_stop` when the change is approved (capturing the agreed
deletion date and the driving ticket - `servicenow_ticket` ends up
written directly onto the VM, so anyone who finds it stopped can trace
why without a CMDB lookup), then a separately scheduled call to
`delete_vm` once that date arrives - or a single `delete_vm` call for an
immediate decommission. If the change gets withdrawn or rescheduled
before that second call happens, `decommission_cancel` reverses the stop
and restores the VM to service. The result (`deletevm_summary` via
`set_stats`, or the job's exit code) lets ServiceNow update the CI
record (retire it, or leave it active on a cancel) and the associated
ticket/task.

## Variables

### Required (extra-vars, supplied by the calling workflow)

| Variable | Used by | Description |
|---|---|---|
| `vm_name` | all three | Name of the CI / VM, as known to vCenter and/or Hyper-V |
| `vm_delete_scheduled_at` | `decommission_stop` | Date (or date/time) this VM is approved to be deleted, e.g. `2026-08-15` |
| `servicenow_ticket` | `decommission_stop` | The change/request ticket driving this decommission, e.g. `CHG0012345` - recorded as part of the marker on the VM itself |
| `confirm_delete` | `delete_vm` | Must be explicitly `true` - the one hard gate on this playbook |

`decommission_cancel` has no playbook-specific required variable beyond
`vm_name` - it reads everything else it needs back out of the marker
`decommission_stop` wrote, and fails if that marker isn't there (see
"How it works" above).

### Optional

| Variable | Default | Used by | Description |
|---|---|---|---|
| `hypervisor_type` | auto-detected | all three | `vmware` or `hyperv`, to skip the search |
| `managed_by_scvmm` | auto-detected if `scvmm_server` is configured | all three | `true`/`false`, to skip SCVMM detection |
| `decommission_reason` | `""` | `decommission_stop` | Free text recorded alongside the deletion marker |
| `deletevm_allow_clustered_vm` | `false` | `decommission_stop`, `delete_vm` | `true` to proceed on a highly-available Hyper-V VM once failover has been coordinated manually |
| `deletevm_poweroff_timeout_seconds` | `300` | `decommission_stop`, `delete_vm` | How long to wait for a graceful shutdown before giving up |
| `deletevm_lock_timeout_seconds` | `1800` | all three | Delay before a per-VM lock is considered abandoned and can be broken by a new run |

### Per environment (`inventory/group_vars/all.yml`)

| Variable | Description |
|---|---|
| `vcenter_hostname` / `vcenter_username` / `vcenter_password` / `vcenter_datacenter` | vCenter API connection |
| `scvmm_server` / `scvmm_username` / `scvmm_password` | Optional SCVMM server (`inventory_hostname` of the `scvmm_management` group); leaving `scvmm_server` empty disables SCVMM detection entirely |
| `hyperv_hypervisor` group (inventory) | Fleet of Hyper-V hosts to query when locating a VM |

See `inventory/hosts.yml.example` and each playbook's header for the
full detail.
