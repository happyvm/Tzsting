# ansible-createvm

Ansible playbook to create a new VM by cloning a template on **VMware**
(vSphere/ESXi) or **Hyper-V** (via **SCVMM**), sizing it, placing it, and
applying guest customization - sysprep for Windows, cloud-init (VMware)
or an injected SSH key (SCVMM) for Linux. Fourth project in this series
alongside `ansible-resizedisk`, `ansible-snapshot` and
`ansible-resizecompute`, sharing their overall design (ServiceNow-
triggered, per-request locking), but structurally different in one
important way: **there is no existing VM to detect a hypervisor from**.
`hypervisor_type` is always a required extra-var here, not
auto-detected.

## How it works

1. **`create_vm_lock`** — takes a per-`vm_name` lock before anything
   else, so two ServiceNow-triggered requests for the same VM name don't
   race into creating two VMs. Because there's no existing VM object to
   hang a marker on yet, the lock mechanism itself differs by platform -
   see "Locking, in detail" below.

2. **`preflight_create_constraints`** — validates every input before
   anything is created: `hypervisor_type` is one of the two supported
   values, `vm_name` is free (not already in use anywhere on the chosen
   platform) and safe to interpolate into PowerShell, the template
   exists, sizing is within policy caps, the Windows computer name fits
   the 15-character NetBIOS limit, domain-join credentials are complete
   if a domain was requested, and - for Hyper-V - that `scvmm_server` is
   actually configured (see "Hyper-V requires SCVMM" below).

3. **`create_vm_vmware`** / **`create_vm_scvmm`** — the actual clone,
   sizing, placement and customization, in a single call per platform
   (VMware) or a scripted sequence (SCVMM).

A structured summary (`createvm_summary`) is published via
`ansible.builtin.set_stats` — retrievable as an AWX/Tower job *artifact*
and therefore readable by ServiceNow on return from the call.

### Hyper-V requires SCVMM

Unlike the other three projects, where SCVMM is optional (native
Hyper-V is always a fully supported fallback), **this project has no
native-Hyper-V creation path at all.** Native `New-VM` has no concept of
a "template" with built-in sysprep/answer-file customization - the
closest native equivalent is a manual golden-image workflow (build a
reference VM, sysprep it, `Export-VM` it, then copy/import the VHDX for
each new VM), which has no clean, scriptable customization API
comparable to VMware's `customization` dict or SCVMM's `New-SCVirtualMachine`
guest OS profile parameters. Rather than build something fragile on top
of manual VHDX copying and offline answer-file injection, this project
treats **SCVMM as a hard requirement for `hypervisor_type=hyperv`** -
`preflight_create_constraints` fails clearly if `scvmm_server` isn't
configured, rather than silently attempting something native Hyper-V
can't actually do.

### Locking, in detail

Both platforms lock by `vm_name`, but the mechanism itself differs -
there's no existing VM to write a marker onto the way the other three
projects' locks do:

- **Hyper-V/SCVMM**: a lock file created with `FileMode.CreateNew` on
  `scvmm_server` (always available on this path, since SCVMM is
  required - see above). Atomic at the OS level, a real mutex lock, same
  technique as the other three projects' Hyper-V-side locks.
- **VMware**: a lock file on the **Ansible control node itself**
  (`delegate_to: localhost`), using the POSIX `noclobber` idiom for an
  atomic create. This is a narrower guarantee than the other three
  projects' VMware lock (a vCenter-side VM annotation marker): it only
  protects concurrent runs launched from the *same* control node /
  execution environment. In an AWX/AAP deployment where each job runs in
  an isolated execution environment with no shared filesystem between
  concurrent jobs, **this lock provides no protection at all** - there's
  no vCenter-side object to attach a marker to before the VM exists, and
  this project doesn't invent one (e.g. a placeholder VM) just to hold a
  lock. Worth knowing if your AWX topology runs jobs on ephemeral,
  per-job execution environments.

### Windows vs. Linux customization, per platform

| | VMware | Hyper-V (SCVMM) |
|---|---|---|
| **Windows** | `customization` dict (sysprep): hostname, domain-join or workgroup, local admin password, product key, timezone, DNS | `New-SCVirtualMachine` guest OS profile parameters: `-ComputerName`, `-Domain`/`-DomainJoinCredential` or `-Workgroup`, `-LocalAdministratorCredential`, `-ProductKey`, `-TimeZone` |
| **Linux** | `customization` dict for hostname/network/DNS, plus `guestinfo.userdata`/`guestinfo.metadata` (base64) for cloud-init, if `cloud_init_userdata` is supplied | `-LinuxDomainName` / `-LinuxAdministratorSSHKeyString` (SCVMM's own Linux integration - conceptually similar to cloud-init's SSH-key injection, but it's SCVMM's own mechanism, not literal cloud-init) |
| **Network** | Full support: DHCP or static (IP/netmask/gateway/DNS), any portgroup (`networks` list) | **DHCP only for v1** - whatever the template's network adapter is already configured with carries over unchanged. Static IP would need `Grant-SCIPAddress` against an SCVMM IP pool, not implemented yet - a documented gap, not an oversight |
| **Disk sizing beyond the template** | `disk_gb` grows the primary disk past the template's default in the same call | **Not supported yet** - a documented gap; resize the OS disk after creation with `ansible-resizedisk` instead |

**Why cloud-init via `guestinfo`, not the legacy `script_text`
mechanism.** VMware's classic Linux customization (`customization.script_text`)
needs the old Perl-based Linux customization package installed in the
guest - something most modern, minimal, cloud-image-based templates
don't ship with. cloud-init's own VMware datasource reads
`guestinfo.userdata`/`guestinfo.metadata` (both base64-encoded, with a
matching `*.encoding` key set to `base64`) directly from VM "extra
config" on first boot - no in-guest customization package needed beyond
cloud-init itself, which is already present on essentially every modern
cloud-ready Linux image. This project still sets the
`customization` dict's `hostname`/network/DNS fields too (they configure
the standard VM network interface regardless of the guest's own init
mechanism), so hostname/network setup goes through the same reliable
path whether or not cloud-init userdata was supplied.

**`vm_timezone` is a numeric code on both platforms, not an IANA
string** - VMware's Windows customization `timezone` field and SCVMM's
`-TimeZone` parameter both expect a Microsoft-style numeric timezone
index (e.g. `035` for Pacific Time), not `America/Los_Angeles`. Consult
each platform's own reference table; this project passes the value
through as-is without validating or translating it.

## Directory layout

```
ansible-createvm/
├── ansible.cfg
├── requirements.yml                          # required collections
├── .ansible-lint                             # basic profile, with our deliberate deviations documented
├── .yamllint                                 # yamllint config (max line length raised to 200)
├── inventory/
│   ├── hosts.yml.example                     # fleet of Hyper-V hosts + the required scvmm_management group
│   └── group_vars/all.yml                    # vCenter/SCVMM connection + policy caps
├── playbooks/create_vm.yml
├── scripts/
│   ├── extract_embedded_scripts.py           # pulls embedded PowerShell out into standalone files (for CI)
│   └── PSScriptAnalyzerSettings.psd1         # documented excluded rules
└── roles/
    ├── create_vm_lock/                       # per-vm_name lock (acquire/release), anti double-create
    ├── preflight_create_constraints/         # every input validated before anything is created
    ├── create_vm_vmware/                     # clone + size + place + customize, one module call
    └── create_vm_scvmm/                      # New-SCVirtualMachine from template + OS profile
```

## Continuous integration

- **`.github/workflows/ansible-createvm-ci.yml`** (triggered on changes
  under `ansible-createvm/`): `yamllint`, `ansible-lint` (`basic`
  profile), and `ansible-playbook --syntax-check`. No `shellcheck` job -
  this project has no guest-touching bash.
- **`.github/workflows/powershell-quality.yml`** (pre-existing at the
  repo level, extended here alongside the other three projects' entries):
  `scripts/extract_embedded_scripts.py` pulls the Jinja-templated
  PowerShell out of the role task YAML into standalone `.ps1` files,
  then `PSScriptAnalyzer` runs against those with
  `scripts/PSScriptAnalyzerSettings.psd1`.

**A real bug caught during development, worth calling out**: Ansible's
`default(omit)` placeholder only works for a module's own **top-level**
parameters - it does *not* work for keys nested inside a dict or list
value (a known, still-open Ansible limitation,
[ansible/ansible#45907](https://github.com/ansible/ansible/issues/45907)).
An early draft of `create_vm_vmware`'s `customization` dict built
optional keys with `'domain': domain_name | default(omit)` nested inside
a dict literal - which does *not* strip the key when unset, it hands the
module a literal unresolved placeholder value instead. Fixed by building
the dict with `combine()`, only merging in a key when its source
variable is actually defined (`{'domain': domain_name} if domain_name is
defined else {}`), which is the correct pattern for optional keys nested
inside module suboptions.

## Prerequisites

- Ansible >= 2.15
- Collections: `ansible-galaxy collection install -r requirements.yml`
  (`community.vmware`, `ansible.windows`, `community.windows`)
- `pyvmomi` and `pywinrm` installed on the control node (or the AWX
  execution environment image)
- vCenter service account with rights to clone/reconfigure VMs in the
  target cluster/datastore/folder
- **SCVMM** (required for `hypervisor_type=hyperv`): the
  `virtualmachinemanager` PowerShell module must be installed on
  `scvmm_server`, and the service account needs rights to create VMs
  from templates (`New-SCVirtualMachine`) on the target host/path.
- A VM template already exists and is reachable by name on the target
  platform - this project only clones, it doesn't build templates.
- For domain join: an account with rights to join computers to the
  target AD domain.

## Usage

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml: the list of Hyper-V hosts + the scvmm_management group
# edit inventory/group_vars/all.yml: vCenter/SCVMM connection (credentials via vault)

ansible-galaxy collection install -r requirements.yml
```

VMware, Windows, domain-joined, static IP:

```bash
ansible-playbook playbooks/create_vm.yml \
  -e hypervisor_type=vmware -e vm_name=WINSRV02 \
  -e template_name='Windows Server 2022 Template' -e guest_os=windows \
  -e vcpu_count=4 -e memory_gb=16 -e disk_gb=120 \
  -e vmware_cluster=Prod-Cluster01 -e vmware_datastore=datastore-ssd \
  -e network_name=VLAN-Production -e network_type=static \
  -e ip_address=10.0.1.50 -e netmask=255.255.255.0 -e gateway=10.0.1.1 \
  -e domain_name=corp.example.com -e domain_admin_username=svc-join \
  -e domain_admin_password=*** -e local_admin_password=*** \
  --vault-password-file .vault_pass
```

VMware, Linux, cloud-init:

```bash
ansible-playbook playbooks/create_vm.yml \
  -e hypervisor_type=vmware -e vm_name=LINSRV02 \
  -e template_name='Ubuntu-24.04-cloudimg-Template' -e guest_os=linux \
  -e vcpu_count=2 -e memory_gb=4 \
  -e vmware_cluster=Prod-Cluster01 -e vmware_datastore=datastore-ssd \
  -e network_name=VLAN-Production \
  -e cloud_init_userdata="$(cat cloud-init.yaml)" \
  --vault-password-file .vault_pass
```

Hyper-V via SCVMM, Windows, workgroup (DHCP network):

```bash
ansible-playbook playbooks/create_vm.yml \
  -e hypervisor_type=hyperv -e vm_name=WINSRV03 \
  -e template_name='WindowsServer2022' -e guest_os=windows \
  -e vcpu_count=4 -e memory_gb=16 \
  -e vm_host=hyperv-host01.example.local -e vm_path='D:\VMs' \
  -e workgroup_name=WORKGROUP -e local_admin_password=*** \
  --vault-password-file .vault_pass
```

### ServiceNow integration

Typical use case: a ServiceNow *Catalog Item* / *Request* triggers, via
**Ansible Automation Platform** (job template + webhook) or a **MID
Server** running `ansible-playbook` directly, a call to `create_vm` with
the requester's choices as extra-vars (template, sizing, network,
domain/workgroup, ...) and credentials pulled from the Credential Store.
The result (`createvm_summary` via `set_stats`, or the job's exit code)
lets ServiceNow update the CI record and the associated ticket/task with
the new VM's actual configuration and IP (VMware only - see the network
table above).

## Variables

### Required (extra-vars, supplied by the calling workflow)

| Variable | Description |
|---|---|
| `hypervisor_type` | `vmware` or `hyperv` - always required, no auto-detection possible |
| `vm_name` | Name for the new VM/CI |
| `template_name` | Name of the VM template to clone |
| `guest_os` | `windows` or `linux` |
| `vcpu_count` | vCPU count |
| `memory_gb` | Memory size in GB |

### Required, VMware only

| Variable | Description |
|---|---|
| `vmware_datastore` | Target datastore |
| `network_name` | Target portgroup / VM network |
| `vmware_cluster` or `esxi_host` | Target cluster or a specific ESXi host (one of the two) |

### Required, Hyper-V/SCVMM only

| Variable | Description |
|---|---|
| `vm_host` | SCVMM-managed Hyper-V host to place the VM on |
| `vm_path` | Storage path for the VM's files |

### Optional

| Variable | Default | Platform | Description |
|---|---|---|---|
| `computer_name` | `vm_name` | both | In-guest computer name - must fit the 15-char NetBIOS limit if `guest_os=windows` |
| `disk_gb` | template default | VMware only | Grow the primary disk beyond the template's default |
| `vcpu_cores_per_socket` | `1` | VMware only | Cores per socket topology |
| `domain_name` / `workgroup_name` | — | both | Mutually exclusive |
| `domain_admin_username` / `domain_admin_password` | — | both | Required together with `domain_name` |
| `local_admin_password` | — | both | Windows: sysprep local admin password |
| `product_key` | — | Windows only | |
| `vm_timezone` | template default | both | Numeric timezone code (see above) |
| `ssh_public_key` | — | Linux, SCVMM only | |
| `network_type` | `dhcp` | VMware only | `dhcp` or `static` |
| `ip_address` / `netmask` / `gateway` / `dns_servers` | — | VMware only | Required with `network_type=static` |
| `cloud_init_userdata` / `cloud_init_metadata` | — | VMware + Linux only | See "Windows vs. Linux customization" above |
| `wait_for_ip` / `wait_for_ip_timeout_seconds` | `true` / `600` | VMware only | Wait for VMware Tools to report an IP before returning |
| `createvm_max_vcpu_count` / `createvm_max_memory_gb` / `createvm_max_disk_gb` | `32` / `512` / `4000` | both | Policy caps against a mistyped value |
| `createvm_lock_timeout_seconds` | `1800` | both | Delay before a per-`vm_name` lock is considered abandoned and can be broken by a new run |

### Per environment (`inventory/group_vars/all.yml`)

| Variable | Description |
|---|---|
| `vcenter_hostname` / `vcenter_username` / `vcenter_password` / `vcenter_datacenter` | vCenter API connection |
| `scvmm_server` / `scvmm_username` / `scvmm_password` | Required for `hypervisor_type=hyperv` (`inventory_hostname` of the `scvmm_management` group) |
| `hyperv_hypervisor` group (inventory) | Not used for placement here (that's `vm_host`) - kept for consistency with the other three projects' inventory shape |

See `inventory/hosts.yml.example` and the playbook header for the full
detail.
