# ansible-resizedisk

Ansible playbook to grow the virtual disk of a **Windows or Linux** VM —
whether hosted on **VMware** (vSphere/ESXi) or **Hyper-V** — and then
automatically extend the partition/filesystem on top of it (Windows: NTFS
via `Resize-Partition`; Linux: `growpart` + `resize2fs`/`xfs_growfs`/
`btrfs`, with LVM support).

Designed to be triggered by a **ServiceNow workflow** (Flow Designer /
Orchestration, via an AWX/Ansible Automation Platform job template, or a
MID Server): no static per-VM inventory - everything is driven by
extra-vars resolved from the CI/RITM/change request.

## How it works

The playbook runs as a single play (`hosts: localhost`) that orchestrates
everything else by delegation, in 6 steps:

1. **`preflight_platform`** — validates that the target is actually a VM
   and detects the hypervisor:
   - queries vCenter (`community.vmware.vmware_guest_info`) and every
     known Hyper-V host (`Get-VM -Name`) looking for a VM with this name;
   - fails explicitly if the name is found on **neither** platform (not a
     managed VM / misspelled) or on **both** at once (ambiguous);
   - exposes `resizedisk_hypervisor_type` (`vmware`/`hyperv`) and, for
     Hyper-V, `resizedisk_hyperv_host` (the host running the VM,
     **always** sourced from this direct inventory search, never from
     whatever hostname SCVMM reports - see just below).
   - Can be short-circuited by passing `hypervisor_type` as an extra-var
     if the ServiceNow workflow already knows the platform (e.g. CMDB class).
   - For a Hyper-V VM, also detects whether it's **managed by SCVMM**
     (`resizedisk_managed_by_scvmm`): if `scvmm_server` is configured, it
     queries SCVMM (`Get-SCVirtualMachine -Name`); otherwise, or to
     short-circuit detection, pass `managed_by_scvmm` as an extra-var.
     This boolean only determines *how* step 5 grows the disk - see below.

2. **`resizedisk_lock`** (`resizedisk_lock_action: acquire`) — takes a
   per-VM lock before any other action, so a double ServiceNow submission
   (or a re-run while one is still in progress) against the same VM
   doesn't collide. The rest of the play (steps 3 to 6) is then wrapped
   in a `block`/`always`: the lock is always released at the end of the
   run, success or failure. Important detail: the two guarantees are
   **not equivalent**:
   - **Hyper-V**: a file created with `FileMode.CreateNew` on the
     Hyper-V host - atomic at the OS level, so this is a real mutex lock.
   - **VMware**: a marker written into the VM's annotation (read then
     write via the vCenter API) - no compare-and-swap operation is
     available on that field, so this is **best-effort**: it heavily
     narrows the race window (covers the common "double-clicked submit"
     case) without being an absolute guarantee against two runs starting
     at the exact same instant.
   - A lock self-expires after `resizedisk_lock_timeout_seconds` (2h by
     default), so it doesn't block indefinitely after a run that crashed
     without ever reaching the `always`.

3. **`preflight_disk_constraints`** — fails fast, before any connectivity
   probing and before any action, if the disk isn't safe to grow
   (snapshots, RDM/virtual FC, passthrough, shared VHDX... see table
   below). Also does the disk lookup once (`vmware_target_disk` /
   `hyperv_vhd_info`), reused as-is by `resize_disk_vmware` /
   `resize_disk_hyperv`, which no longer repeat the call. Also resolves
   `resizedisk_guest_os` (`windows`/`linux`): auto-detected on VMware
   (`hw_guest_id`), must be supplied explicitly via `guest_os` on
   Hyper-V (see note below).

4. **`preflight_connectivity`** — determines the channel to talk to the
   guest OS, based on `resizedisk_guest_os`:
   - **Windows**: tests WinRM (`win_ping`, with `ignore_unreachable`); if
     WinRM doesn't respond, falls back to **VMware Tools guest
     operations** (VMware) or **PowerShell Direct** (Hyper-V, **VMBus**
     channel, `Invoke-Command -VMName`, run locally on the Hyper-V host).
   - **Linux**: tests SSH (`ping` module, with `ignore_unreachable`); if
     SSH doesn't respond:
     - VMware VM → same VMware Tools fallback as Windows (`vm_shell`
       with `/bin/bash` instead of `powershell.exe`): no network access
       to the guest needed, everything goes through the vCenter API.
     - Hyper-V VM → **no agentless fallback**: PowerShell Direct is a
       Windows-only integration component with no Linux equivalent. SSH
       down on a Linux Hyper-V guest is a hard stop.
   - fails if no channel is available, with a message spelling out
     exactly what's missing (WinRM/SSH, VMware Tools, or the absence of
     a Hyper-V+Linux fallback).
   - exposes `resizedisk_exec_method` (`winrm` / `ssh` / `vmware_tools` /
     `powershell_direct`).

   Deliberately placed *after* `preflight_disk_constraints`: no point
   paying for a WinRM/SSH timeout plus fallback for a request that's
   doomed on the disk side anyway.

5. **Growing the disk at the hypervisor layer** — three possible roles
   depending on `resizedisk_hypervisor_type`/`resizedisk_managed_by_scvmm`:
   - **`resize_disk_vmware`** — vCenter API (`vmware_guest_disk`).
   - **`resize_disk_hyperv`** — `Resize-VHD` delegated directly to
     `resizedisk_hyperv_host`.
   - **`resize_disk_scvmm`** — Hyper-V VM managed by SCVMM:
     `Expand-SCVirtualDiskDrive`, delegated to `scvmm_server`, instead of
     `Resize-VHD` directly. Necessary because an out-of-band `Resize-VHD`
     leaves the SCVMM database showing the old size until a manual
     refresh. Targets **exactly** the disk already validated at step 3
     (the `ControllerNumber`/`ControllerLocation` properties captured
     there are reused as SCVMM's `Bus`/`Lun`), not a fresh independent
     selection that could risk pointing at a different disk.

   All three only perform the action itself, the checks having already
   happened at step 3 (identical whether the VM is managed directly or
   via SCVMM - that only changes which API performs the final action,
   not the safety checks, which always query the real Hyper-V host
   directly). Strictly identical for Windows and Linux: at the
   hypervisor layer, the disk has no OS. Skipped (without error) if
   `resizedisk_disk_grow_needed` is false - see "Resuming after a
   partial failure" below.

6. **`resize_windows_filesystem`** (Windows) or **`resize_linux_filesystem`**
   (Linux), based on `resizedisk_guest_os`:
   - **Windows**: rescans storage, brings the disk back online if
     needed, then `Resize-Partition` up to the max size.
   - **Linux**: SCSI rescan (`/sys/class/scsi_host/*/scan`, works the
     same whether the disk is presented via VMware's pvscsi/lsilogic or
     Hyper-V's hv_storvsc), detects plain partition vs LVM logical
     volume via `lsblk`, `growpart`'s the right partition (and, for LVM,
     `pvresize` + `lvextend -l +100%FREE` across every PV in the VG),
     then resizes the filesystem based on its type
     (`resize2fs`/`xfs_growfs`/`btrfs filesystem resize`).

   Both roles run via `run_guest_command`, a generic role that sends the
   same script (PowerShell or bash) over the channel chosen at step 4, in
   a single round trip.

A structured summary (`resizedisk_summary`) is published via
`ansible.builtin.set_stats` — retrievable as an AWX/Tower job *artifact*
and therefore readable by ServiceNow on return from the call.

The disk-resize roles **refuse to shrink** (explicit failure if
`disk_new_size_gb` < current size) and are **idempotent/re-runnable**: if
the disk is already at the requested size (within `resizedisk_min_growth_gb`,
1GB by default, of remaining growth), the hypervisor-level resize is
simply skipped - the playbook continues on to the filesystem step instead
of failing.

### Resuming after a partial failure

Scenario: the disk is grown at the hypervisor layer, then the filesystem
step fails (network blip, VM crashes mid-run...). Re-running the playbook
with the **same parameters** should pick up where it left off, not fail
outright explaining that the requested size has already been reached.

That's the role of `resizedisk_disk_grow_needed`, computed in
`preflight_disk_constraints`:
- `disk_new_size_gb` < current size → failure (shrink attempt, always an
  error).
- `disk_new_size_gb` ≥ current size but growth < `resizedisk_min_growth_gb`
  → `resizedisk_disk_grow_needed = false`: `resize_disk_vmware`/`resize_disk_hyperv`
  skip the API call, but `resize_windows_filesystem`/`resize_linux_filesystem`
  still run.
- Otherwise → `resizedisk_disk_grow_needed = true`, normal resize.

The "partition/filesystem gained no space" check (protection against a
wrong target, see above) is only a hard failure when `resizedisk_disk_grow_needed`
was true *for this run*: on a re-run where the disk was already at the
right size, gaining nothing is the expected outcome (already done), not a
sign of misconfiguration. This protection stays fully active for the
common case (a first run that actually grows the disk).

### Resize-blocking conditions checked in preflight

`preflight_disk_constraints` fails explicitly (before any connectivity
probe, without modifying anything) if any of these conditions is detected:

| Condition | VMware | Hyper-V |
|---|---|---|
| VM powered off / not running | `hw_power_status != 'poweredOn'` | `$vm.State != 'Running'` |
| VM = template | `hw_is_template = true` | — |
| `guest_os` missing/invalid | auto-detected from `hw_guest_id`, unless overridden | **required explicitly** (see note) |
| Snapshot consolidation pending | `guest_consolidation_needed = true` | — |
| Snapshots / checkpoints present | `vmware_guest_snapshot_info` → `guest_snapshots.snapshots` non-empty | `Get-VMSnapshot` → count > 0 |
| RDM (physical or virtual) / virtual FC (NPIV) | `backing_type != 'FlatVer2'` (RDM = `RawDiskMappingVer1`, including RDM over virtual FC) | — (see passthrough) |
| Disk not found (wrong controller/unit/index) | list of existing disks returned in the error message | already handled: `Get-VMHardDiskDrive` throws an explicit exception |
| Physical passthrough disk | — | `VMHardDiskDrive.Path` empty (`DiskNumber` used instead) |
| System disk on an IDE controller (Generation 1) | — | `VMHardDiskDrive.ControllerType == 'IDE'` |
| Legacy VHD beyond 2040GB | — | `Get-VHD.VhdFormat -eq 'VHD'` and requested size > 2040GB |
| Shared VHDX (guest clustering) | — | `SupportPersistentReservations = true` |
| Differencing disk | — | `Get-VHD.VhdType -eq 'Differencing'` |
| Active replication (DR) | — | `Get-VMReplication` → `State != 'Disabled'` |
| Clustered (highly-available) VM, owner node ≠ detected host | — | `Get-ClusterGroup -Name <vm>` → `OwnerNode` ≠ `resizedisk_hyperv_host` - **hard failure, no override possible** (signals an in-progress failover) |
| Clustered (highly-available) VM, no override | — | same, without `-e resizedisk_allow_clustered_vm=true` |
| Degraded S2D/pooled storage | — | `Get-StoragePool`/`Get-PhysicalDisk` → `HealthStatus != 'Healthy'` on a non-primordial pool or a physical disk |
| Datastore/volume inaccessible | `accessible = false` on the datastore | — |
| Size beyond the datastore's max supported VMDK size | 2040GB if VMFS3, else 62TB (VMFS5/6, VVol, NFS, vSAN - vSphere-wide cap since ESXi 5.5) | — |
| Insufficient free space on the underlying storage | `freeSpace` of the datastore < requested growth + `resizedisk_datastore_free_margin_gb` | `PSDrive.Free` of the host volume < requested growth + `resizedisk_host_free_margin_gb` |
| Requested size beyond the policy cap | `disk_new_size_gb > resizedisk_max_size_gb` (both platforms) | same |
| Partition gained no space despite the disk having been grown | checked afterwards in `resize_windows_filesystem` (see note) | same |

**Hyper-V CSV cluster, in detail.** Two distinct guardrails, one
overridable and one not:
- **Owner node different from the detected host** (`ClusterOwnerNode` vs
  `resizedisk_hyperv_host`) → the VM has likely just failed over, our
  gathered information may already be stale. **No override bypasses**
  this specific case - it's a live instability signal, not a matter of
  coordination.
- **Clustered VM, consistent owner node** → blocked by default (it can
  fail over *during* the resize), but overridable with
  `-e resizedisk_allow_clustered_vm=true` once coordination has actually
  been done manually (no pending failover, maintenance window, etc.).

Cluster detection itself is **best-effort**: it depends on the
`FailoverClusters` PowerShell module being present on
`resizedisk_hyperv_host`, a separately-installed Windows feature that
isn't always present even on a host that genuinely belongs to a cluster.
If the module is absent, the check is silently skipped
(`ClusterCheckAvailable = false`) rather than blocking or falsely
reassuring - worth keeping in mind if your clustered Hyper-V hosts don't
have this feature installed.

**S2D/hyperconvergence.** The storage health check (pools/physical
disks) is deliberately generic - it doesn't trace up to the *specific*
pool backing the target CSV (the CSV → Cluster Virtual Disk → Storage
Pool chain is too fragile to correlate reliably), it checks the health
of **all** pooled storage on the host. On a host with no pooled storage
(traditional SAN/DAS), the lists come back empty and the check is a
no-op - no separate "is this S2D" detection is needed.

**SCVMM integration, in detail.** When `resizedisk_managed_by_scvmm` is
true, only the final resize action changes (`resize_disk_scvmm` instead
of `resize_disk_hyperv`) - *all* the checks above (snapshots, cluster,
S2D, IDE/Generation 1, replication...) still query
`resizedisk_hyperv_host` directly via Hyper-V PowerShell, not through
SCVMM. Two reasons for that: SCVMM doesn't change any of these
underlying technical constraints (a VHDX with checkpoints is just as
problematic whether SCVMM manages it or not), and it avoids duplicating
the entire detection logic for a second query system. `resize_disk_scvmm`
targets the disk via `Bus`/`Lun` (SCVMM's addressing), mapped directly
from the `ControllerNumber`/`ControllerLocation` Hyper-V properties
captured by `preflight_disk_constraints` on that same disk - not a fresh
independent selection via `disk_controller_number`/`disk_unit_number`,
which use a different addressing scheme (an ordinal index on the direct
Hyper-V side) and could end up pointing at a different disk if the two
ever disagree.

**Multi-writer disk (VMware) - not implemented.** This flag (used for
Oracle RAC or other clusters sharing a single VMDK) isn't exposed for
reading by any module in the `community.vmware` or `vmware.vmware`
collections installed here - only the *converge* module `vmware.vmware.vm`
knows about it (`backing.sharing`), and using it read-only would risk
triggering an unintended disk modification. Manual verification is
recommended for VMs that might be affected (application clusters sharing
a disk) until a dedicated module exposes it properly.

An RDM (physical, virtual, or presented over a virtual Fibre Channel/NPIV
adapter) can't be grown through the vCenter API anyway: the LUN has to be
grown on the storage array side and then rescanned. These disks are
therefore simply excluded, not handled differently.

On Hyper-V, a **Generation 1** VM always boots from an **IDE** controller,
and Hyper-V doesn't support hot-resizing an IDE-attached disk (unlike
SCSI, `Resize-VHD` fails while the file is locked by a running VM). A
Generation 1 system disk is therefore always blocked while the VM is
running - the only option is to shut the VM down (outside the scope of
this playbook, which assumes the VM is powered on for the filesystem
extension step). A Generation 1 VM with a SCSI-attached data disk isn't
affected by this block.

The VM must be powered on: beyond the disk itself, step 5 (extending the
filesystem) needs a running OS to be reached via WinRM/SSH, VMware Tools,
or PowerShell Direct - a powered-off VM is therefore blocked at preflight
rather than letting the connectivity probe fail with a less informative
message.

**`guest_os`: auto-detected on VMware, required on Hyper-V.** On VMware,
`hw_guest_id` (already cached from `preflight_platform`) is enough to
distinguish Windows from Linux before we even know if WinRM/SSH responds.
On Hyper-V, `Get-VM` doesn't natively expose the guest OS without already
talking to the VM (WinRM/CIM) - which would break the deliberate "disk
before connectivity" ordering - so `guest_os` must be supplied explicitly
as an extra-var for any Hyper-V VM. In both cases, passing `guest_os`
explicitly always short-circuits detection.

**Grown disk / target consistency.** Nothing guarantees, before growing,
that `windows_drive_letter`/`linux_target` actually lives on the disk
identified by `disk_controller_number`/`disk_unit_number` (VMware) or
`disk_number_hyperv` (Hyper-V) - a ServiceNow parameterization mistake
would silently grow the wrong disk. Rather than attempting a fragile
identifier correlation before we even know how to talk to the guest,
`resize_windows_filesystem`/`resize_linux_filesystem` check the actual
result on the guest side afterwards: if the disk was grown (preflight
already guaranteed that) but the target partition/filesystem gained no
space, that's a strong signal of a misconfiguration - the playbook fails
explicitly rather than silently reporting "already at max size". On
Linux, this same failure can also indicate that an LVM volume group has
PVs spread across several disks, only one of which was grown.

> **Note**: the field names `hw_power_status`, `hw_is_template`,
> `hw_guest_id`/`hw_guest_full_name` and `guest_consolidation_needed`
> come from `community.vmware.vmware_guest_info` (already called by
> `preflight_platform`, so at no extra cost) - validate them against the
> actually installed collection version.

## Supported versions

### Windows

| Version | Status | Detail |
|---|---|---|
| Server 2003 / 2003 R2 | ❌ **Not supported** | Ansible's WinRM/PowerShell floor is PowerShell 3.0, whose OS floor is Windows 7 SP1 / Server 2008 SP1 (WMF 3.0). Server 2003 can't go beyond PowerShell 2.0 - Ansible simply can't connect to it, no `ansible.windows`-based architecture can work around that. |
| Server 2008 (non-R2) / 2008 R2 | ⚠️ Supported via a dedicated path | Reachable over WinRM (requires WMF 3.0+ pre-installed on the target - a prerequisite outside this playbook). The Storage module (`Get-Partition`/`Resize-Partition`/`Update-HostStorageCache`) only exists from Server 2012 onward: `resize_windows_filesystem` detects the OS version *from inside the script* (`[System.Environment]::OSVersion.Version`) and switches to a `diskpart /s` + WMI read (`Win32_Volume`) path for these two versions. Accepted simplification: bringing an offline disk back online isn't handled on this path (the default SAN policy already brought new disks online automatically before Server 2012 changed that default). |
| Server 2012/2012R2/2016/2019/2022/2025 | ✅ Supported (main path) | Native Storage module. |

### Linux (RHEL/CentOS)

| Version | Status | Detail |
|---|---|---|
| 5 | ❌ **Not supported** | Python 2.4 by default. Modern Ansible (ansible-core 2.16+) requires Python 3.7+ on the target to run any module - `ansible.builtin.shell` (used throughout here) is one of them. The only workaround would be rewriting everything in `ansible.builtin.raw` (pure SSH, no Python), losing nearly all of this playbook's safety checks - not done, EOL since 2017. |
| 6 | ⚠️ Best-effort | Python 2.6 by default: same wall as RHEL5, unless Python 3 was **manually provisioned beforehand** on the target (outside this playbook). In that case, pointing `linux_python_interpreter` at it is enough to make the target reachable; `growpart` still needs checking (EPEL-only package on RHEL6, not in the base repos). |
| 7 | ⚠️ Supported with a prerequisite | Python 2.7 by default, insufficient for recent ansible-core. Install `python3` (available in the base repo since RHEL 7.7) and supply `linux_python_interpreter=/usr/bin/python3` - without that, execution fails outright at the connectivity stage, before even reaching `preflight_connectivity`. |
| 8/9/10 | ✅ Supported (main path) | Python 3 by default, no prerequisite. |

## Directory layout

```
ansible-resizedisk/
├── ansible.cfg
├── requirements.yml                     # required collections
├── .ansible-lint                        # basic profile, with our deliberate deviations documented
├── .yamllint                            # yamllint config (max line length raised to 200)
├── inventory/
│   ├── hosts.yml.example                # fleet of Hyper-V hosts to query
│   └── group_vars/all.yml               # vCenter connection + anti-shrink guardrail
├── playbooks/resize_disk.yml            # main playbook (hosts: localhost)
├── scripts/
│   ├── extract_embedded_scripts.py      # pulls embedded PS/bash out into standalone files (for CI)
│   └── PSScriptAnalyzerSettings.psd1    # documented excluded rules (password -> PSCredential, etc.)
└── roles/
    ├── preflight_platform/              # VM? VMware or Hyper-V?
    ├── resizedisk_lock/                 # per-VM lock (acquire/release), anti double-run
    ├── preflight_disk_constraints/      # snapshot/RDM/passthrough/shared VHDX... -> fails fast + guest_os
    ├── preflight_connectivity/          # WinRM/SSH, else VMware Tools / PowerShell Direct
    ├── resize_disk_vmware/              # resize via the vCenter API
    ├── resize_disk_hyperv/              # resize via Resize-VHD on the Hyper-V host
    ├── resize_disk_scvmm/               # resize via Expand-SCVirtualDiskDrive (SCVMM-managed VM)
    ├── run_guest_command/               # multi-channel PowerShell/bash execution in the guest
    ├── resize_windows_filesystem/       # NTFS partition extension in the Windows guest
    └── resize_linux_filesystem/         # growpart + resize2fs/xfs_growfs/btrfs (+ LVM) in the Linux guest
```

## Continuous integration

Two GitHub Actions workflows cover this project:

- **`.github/workflows/ansible-resizedisk-ci.yml`** (triggered on changes
  under `ansible-resizedisk/`):
  - `yamllint` and `ansible-lint` (`basic` profile, two deliberate
    deviations documented in `.ansible-lint`: intentional cross-role
    variable prefixing, and `ignore_errors` on best-effort cleanups);
  - `ansible-playbook --syntax-check`.
- **`.github/workflows/powershell-quality.yml`** (pre-existing at the
  repo level, extended here): this project's PowerShell is embedded as
  Jinja-templated YAML string literals, invisible to a plain `-Recurse`
  scan that only looks at `.ps1` files. `scripts/extract_embedded_scripts.py`
  first pulls it out into standalone files (Jinja `{{ ... }}` placeholders
  are replaced with a number, which stays syntactically valid in every
  context used here - a quoted string or a numeric literal), then
  `PSScriptAnalyzer` runs against those with
  `scripts/PSScriptAnalyzerSettings.psd1` (a couple of documented
  exclusions: converting a plaintext password into a `PSCredential`, and
  a false positive on the Jinja `{{ scvmm_server }}` placeholder looking
  like a hardcoded hostname). The bash in `resize_linux_filesystem` is
  extracted and passed to `shellcheck` in the first workflow.

These two extraction steps were genuinely useful in practice:
`extract_embedded_scripts.py` was used to actually validate (parse +
`PSScriptAnalyzer` + `shellcheck`) all of this project's embedded code
during development - and it caught a real bug (see note below), not just
a manual review.

> **Technical note**: every `win_shell`/`shell` task in this project uses
> the explicit `cmd: |` form rather than the "free-form" form
> (`win_shell: |` directly). The free-form syntax triggers a real Ansible
> parsing bug ("unbalanced jinja2 block or quotes") on some of our
> PowerShell scripts (code-block braces mixed with Jinja `{{ }}`
> delimiters) when the role is loaded via the classic `roles:` syntax
> rather than `include_role` - which is exactly what `ansible-lint` does
> to validate a role in isolation, which is how this was caught. Our
> playbook uses `include_role` everywhere and was therefore never
> actually affected in practice, but the `cmd:` form is the recommended
> practice anyway (`ansible-lint` has a dedicated rule, `no-free-form`)
> and avoids the whole bug class rather than relying on never switching
> role-inclusion mechanisms.

## Prerequisites

- Ansible >= 2.15 (uses `ignore_unreachable`)
- Collections: `ansible-galaxy collection install -r requirements.yml`
  (`community.vmware`, `ansible.windows`, `community.windows`)
- `pyvmomi` and `pywinrm` installed on the control node (or the AWX
  execution environment image)
- vCenter service account with read access to the inventory and disk-edit
  rights on the relevant VMs
- Windows guest account with the administrative rights needed for
  `Resize-Partition` / `Update-HostStorageCache`
- Linux guest account that's root, or has sudo (`linux_become: true` +
  optionally `linux_become_password`), and the packages `growpart`
  (`cloud-guest-utils` on Debian/Ubuntu, `cloud-utils-growpart` on
  RHEL/SUSE) + `parted`/`partprobe`, `resize2fs` (ext*), `xfsprogs` (XFS)
  or `btrfs-progs` (Btrfs) depending on the filesystem; `lvm2` as well if
  LVM is in use. None of these packages are installed automatically by
  the playbook - explicit failure if a required tool is missing.
- **VMware Tools fallback** (Windows and Linux): requires VMware Tools/
  `open-vm-tools` running in the guest (otherwise WinRM/SSH down + Tools
  down = no channel available, the playbook fails cleanly).
- **Hyper-V / PowerShell Direct fallback** (Windows only): requires
  Hyper-V PowerShell on the host (`Invoke-Command -VMName`), only
  available from the Hyper-V host itself — hence the delegation to
  `resizedisk_hyperv_host`. **No equivalent for a Linux guest**: on
  Hyper-V, SSH must be reachable, there is no agentless fallback.
- **Hyper-V, hot resize**: the disk must be attached to a SCSI
  controller (Generation 2 VM, or a SCSI-attached data disk on a
  Generation 1). An IDE disk requires shutting the VM down.
- **Clustered Hyper-V (CSV)**: the `FailoverClusters` PowerShell module
  must be installed on `resizedisk_hyperv_host` for clustered-VM
  detection to work (otherwise silently unverifiable, see above). Service
  account with read access to the cluster.
- **SCVMM** (if `scvmm_server` is configured): the `virtualmachinemanager`
  PowerShell module must be installed on `scvmm_server` (present by
  default on an SCVMM management server), and the service account needs
  the SCVMM rights required for `Get-SCVirtualMachine`/
  `Expand-SCVirtualDiskDrive`. Without `scvmm_server` configured, this
  project behaves exactly as before (direct resize via `Resize-VHD`).

## Usage

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml: the list of Hyper-V hosts to query
# edit inventory/group_vars/all.yml: vCenter connection (credentials via vault)

ansible-galaxy collection install -r requirements.yml

ansible-playbook playbooks/resize_disk.yml \
  -e vm_name=WINSRV01 \
  -e disk_new_size_gb=200 \
  -e windows_drive_letter=C \
  -e guest_username=Administrator \
  -e guest_password=*** \
  --vault-password-file .vault_pass
```

Linux example (Hyper-V VM, so `guest_os` is required; SSH key instead of
a password; non-root account with sudo):

```bash
ansible-playbook playbooks/resize_disk.yml \
  -e vm_name=LINSRV01 \
  -e disk_new_size_gb=200 \
  -e linux_target=/data \
  -e guest_os=linux \
  -e guest_username=ansible \
  -e guest_ssh_private_key_file=~/.ssh/id_rsa \
  -e linux_become=true \
  --vault-password-file .vault_pass
```

### ServiceNow integration

Typical use case: a ServiceNow *Catalog Item* / *Change Request* triggers,
via **Ansible Automation Platform** (job template + webhook) or a **MID
Server** running `ansible-playbook` directly, a call with the CI's
attributes as extra-vars (`vm_name`, `disk_new_size_gb`,
`windows_drive_letter` or `linux_target` depending on the OS) and guest
credentials pulled from the Credential Store. The result
(`resizedisk_summary` via `set_stats`, or the job's exit code) lets
ServiceNow update the associated ticket/task (success, final size,
execution channel used in case of a WinRM/SSH fallback).

## Variables

### Required (extra-vars, supplied by the calling workflow)

| Variable | Description |
|---|---|
| `vm_name` | Name of the CI / VM, as known to vCenter and/or Hyper-V |
| `disk_new_size_gb` | Target size in GB |
| `guest_username` | Guest OS admin login |
| `guest_password` | Guest password - required for Windows; for Linux, an alternative to `guest_ssh_private_key_file` |
| `windows_drive_letter` | Drive letter to extend (e.g. `C`) - **required if the guest is Windows** |
| `linux_target` | Mountpoint to extend (e.g. `/`, `/data`) - **required if the guest is Linux** (defaults to `/` if omitted) |

### Optional

| Variable | Default | Description |
|---|---|---|
| `hypervisor_type` | auto-detected | `vmware` or `hyperv`, to skip the search |
| `guest_os` | auto-detected (VMware) | `windows` or `linux` - **mandatory for a Hyper-V VM** (see note above) |
| `target_ip` | `vm_name` | IP/FQDN to reach the guest over WinRM/SSH |
| `guest_ssh_private_key_file` | — | Linux: SSH private key, an alternative to `guest_password` |
| `linux_ssh_port` | `22` | SSH port |
| `linux_become` | `false` | use sudo on Linux if `guest_username` isn't root |
| `linux_become_password` | — | sudo password, if needed |
| `linux_python_interpreter` | auto-detected | path to `python3` on the guest - required on RHEL/CentOS 7 (and 6 if Python 3 was manually provisioned there), see "Supported versions" |
| `disk_controller_number` / `disk_unit_number` | `0` / `0` | VMware SCSI disk to grow |
| `disk_number_hyperv` | `0` | index of the Hyper-V `VMHardDiskDrive` |
| `resizedisk_min_growth_gb` | `1` | anti-shrink/no-op guardrail |
| `resizedisk_datastore_free_margin_gb` | `10` | safety margin required on the VMware datastore, on top of the requested growth |
| `resizedisk_host_free_margin_gb` | `10` | safety margin required on the Hyper-V host volume, on top of the requested growth |
| `resizedisk_max_size_gb` | `2000` | policy cap against a mistyped size; raise explicitly for a legitimately larger disk |
| `resizedisk_lock_timeout_seconds` | `7200` | delay before a per-VM lock is considered abandoned (crashed run) and can be broken by a new run |
| `managed_by_scvmm` | auto-detected if `scvmm_server` is configured | `true`/`false`, to skip SCVMM detection |
| `resizedisk_allow_clustered_vm` | `false` | `true` to grow a clustered Hyper-V VM's disk once coordination has been done manually (has no effect if the owner node has changed - see above) |

### Per environment (`inventory/group_vars/all.yml`)

| Variable | Description |
|---|---|
| `vcenter_hostname` / `vcenter_username` / `vcenter_password` / `vcenter_datacenter` | vCenter API connection (a single one, for the whole VMware estate) |
| `scvmm_server` / `scvmm_username` / `scvmm_password` | optional SCVMM server (`inventory_hostname` of the `scvmm_management` group); leaving `scvmm_server` empty disables SCVMM detection entirely |
| `disk_controller_type` / `disk_controller_number` / `disk_unit_number` / `disk_number_hyperv` | defaults for the targeted disk (see "Optional" table above) |
| `hyperv_hypervisor` group (inventory) | fleet of Hyper-V hosts to query when locating a VM |

These variables live at this level (rather than in role `defaults/`)
because `preflight_disk_constraints`, `resize_disk_vmware` and
`resize_disk_hyperv` are separate roles included independently: they
don't share each other's `defaults/`, only variables with wider scope
(extra-vars, group_vars, facts).

See `inventory/hosts.yml.example` and `playbooks/resize_disk.yml` (header)
for the full detail.
