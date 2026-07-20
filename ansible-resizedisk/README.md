# ansible-resizedisk

Playbook Ansible pour agrandir le disque virtuel d'une VM Windows — que
celle-ci soit hébergée sur **VMware** (vSphere/ESXi) ou **Hyper-V** — puis
étendre automatiquement la partition/le système de fichiers Windows qui
repose dessus.

Conçu pour être déclenché par un **workflow ServiceNow** (Flow Designer /
Orchestration, via un job template AWX/Ansible Automation Platform ou un
MID Server) : pas d'inventaire statique par VM, tout est piloté par des
extra-vars résolues depuis la CI/le RITM/le change request.

## Fonctionnement

Le playbook s'exécute en une seule play (`hosts: localhost`) qui orchestre
tout le reste par délégation, en 5 étapes :

1. **`preflight_platform`** — valide que la cible est bien une VM et
   détecte l'hyperviseur :
   - interroge vCenter (`community.vmware.vmware_guest_info`) et chaque
     hôte Hyper-V connu (`Get-VM -Name`) à la recherche d'une VM portant
     ce nom ;
   - échoue explicitement si le nom n'est trouvé sur **aucun** des deux
     (pas une VM gérée / mal orthographié) ou sur les **deux** à la fois
     (ambiguïté) ;
   - expose `resizedisk_hypervisor_type` (`vmware`/`hyperv`) et, pour
     Hyper-V, `resizedisk_hyperv_host` (l'hôte qui héberge la VM).
   - Peut être court-circuité en passant `hypervisor_type` en extra-var
     si le workflow ServiceNow connaît déjà la plateforme (ex. classe CMDB).

2. **`preflight_disk_constraints`** — bloque tôt, avant toute sonde de
   connectivité et toute action, si le disque n'est pas sûr à agrandir
   (snapshots, RDM/virtual FC, passthrough, VHDX partagé... voir tableau
   ci-dessous). Fait aussi le lookup du disque une seule fois
   (`vmware_target_disk` / `hyperv_vhd_info`), réutilisé tel quel par
   `resize_disk_vmware` / `resize_disk_hyperv` qui ne refont plus l'appel.

3. **`preflight_connectivity`** — détermine le canal pour parler au système
   invité :
   - teste WinRM (`win_ping`, avec `ignore_unreachable`) ;
   - si WinRM ne répond pas :
     - VM VMware → bascule sur les **opérations invité VMware Tools**
       (`community.vmware.vmware_vm_shell` / `vmware_guest_file_operation`) :
       aucun accès réseau à l'invité requis, tout transite par l'API
       vCenter jusqu'à VMware Tools dans l'invité ;
     - VM Hyper-V → bascule sur **PowerShell Direct** (canal **VMBus**,
       `Invoke-Command -VMName`), exécuté localement sur l'hôte Hyper-V ;
   - échoue si aucun canal n'est disponible (WinRM down + pas d'agent
     invité fonctionnel).
   - expose `resizedisk_exec_method` (`winrm` / `vmware_tools` / `powershell_direct`).

   Volontairement placée *après* `preflight_disk_constraints` : inutile de
   payer le coût d'un timeout WinRM + repli VMware Tools/PowerShell Direct
   pour une requête de toute façon vouée à l'échec côté disque.

4. **Agrandissement du disque côté hyperviseur** (`resize_disk_vmware` ou
   `resize_disk_hyperv` selon `resizedisk_hypervisor_type`) — API vCenter
   pour VMware, `Resize-VHD` délégué à l'hôte Hyper-V. Ne fait plus que
   l'action elle-même, les contrôles ayant déjà eu lieu à l'étape 2.

5. **`resize_windows_filesystem`** — rescan du stockage, remise en ligne
   du disque si besoin, puis `Resize-Partition` jusqu'à la taille max.
   Exécuté via `run_guest_command`, un rôle générique qui envoie le même
   script PowerShell par le canal choisi à l'étape 3 (WinRM direct,
   VMware Tools, ou PowerShell Direct), en un seul aller-retour.

Un résumé structuré (`resizedisk_summary`) est publié via
`ansible.builtin.set_stats` — récupérable comme *artifact* de job
AWX/Tower et donc lisible par ServiceNow en retour de l'appel.

Les rôles de resize disque sont **idempotents et refusent de rétrécir ou
de ne rien faire** : si la taille demandée n'est pas au moins
`resizedisk_min_growth_gb` (par défaut 1 Go) au-dessus de la taille
actuelle, la tâche échoue explicitement.

### Conditions bloquantes vérifiées en preflight

`preflight_disk_constraints` échoue explicitement (avant toute sonde de
connectivité, sans rien modifier) si l'une de ces conditions est détectée :

| Condition | VMware | Hyper-V |
|---|---|---|
| VM éteinte / non démarrée | `hw_power_status != 'poweredOn'` | `$vm.State != 'Running'` |
| VM = template | `hw_is_template = true` | — |
| Consolidation de snapshot en attente | `guest_consolidation_needed = true` | — |
| Snapshots / checkpoints présents | `vmware_guest_snapshot_info` → `guest_snapshots.snapshots` non vide | `Get-VMSnapshot` → count > 0 |
| RDM (physique ou virtuel) / virtual FC (NPIV) | `backing_type != 'FlatVer2'` (RDM = `RawDiskMappingVer1`, y compris RDM sur FC virtuel) | — (voir passthrough) |
| Disque physique en passthrough | — | `VMHardDiskDrive.Path` vide (`DiskNumber` utilisé à la place) |
| Disque système sur contrôleur IDE (Generation 1) | — | `VMHardDiskDrive.ControllerType == 'IDE'` |
| VHDX partagé (cluster invité) | — | `SupportPersistentReservations = true` |
| Disque de différenciation | — | `Get-VHD.VhdType -eq 'Differencing'` |
| Réplication active (DR) | — | `Get-VMReplication` → `State != 'Disabled'` |
| Espace libre insuffisant sur le stockage sous-jacent | `freeSpace` du datastore < croissance demandée + `resizedisk_datastore_free_margin_gb` | `PSDrive.Free` du volume hôte < croissance demandée + `resizedisk_host_free_margin_gb` |

Un RDM (physique, virtuel, ou présenté via un adaptateur Fibre Channel
virtuel/NPIV) n'est de toute façon pas agrandissable via l'API vCenter :
il faut agrandir le LUN côté baie de stockage puis rescanner. Ces
disques sont donc simplement exclus, pas traités différemment.

Sous Hyper-V, une VM **Generation 1** démarre toujours depuis un
contrôleur **IDE**, et Hyper-V ne supporte pas le resize à chaud d'un
disque attaché en IDE (contrairement au SCSI, `Resize-VHD` échoue tant
que le fichier est verrouillé par une VM démarrée). Le disque système
d'une Generation 1 est donc systématiquement bloqué tant que la VM
tourne - seule option : éteindre la VM (hors fenêtre de ce playbook, qui
suppose la VM allumée pour l'étape d'extension du système de fichiers).
Une Generation 1 avec un disque de données en SCSI n'est, elle, pas
concernée par ce blocage.

La VM doit être allumée : au-delà du disque lui-même, l'étape 5
(extension du système de fichiers) a besoin d'un OS démarré pour être
jointe par WinRM, VMware Tools ou PowerShell Direct - une VM éteinte est
donc bloquée dès le preflight plutôt que de laisser échouer la sonde de
connectivité avec un message moins parlant.

> **Note** : les noms de champs `hw_power_status`, `hw_is_template` et
> `guest_consolidation_needed` proviennent de `community.vmware.vmware_guest_info`
> (déjà appelé par `preflight_platform`, donc sans coût supplémentaire) -
> à valider contre la version de la collection réellement installée.

## Arborescence

```
ansible-resizedisk/
├── ansible.cfg
├── requirements.yml                     # collections requises
├── inventory/
│   ├── hosts.yml.example                # parc d'hôtes Hyper-V à interroger
│   └── group_vars/all.yml               # connexion vCenter + garde-fou anti-shrink
├── playbooks/resize_disk.yml            # playbook principal (hosts: localhost)
└── roles/
    ├── preflight_platform/              # VM ? VMware ou Hyper-V ?
    ├── preflight_disk_constraints/      # snapshot/RDM/passthrough/VHDX partagé... -> bloque tôt
    ├── preflight_connectivity/          # WinRM, sinon VMware Tools / PowerShell Direct
    ├── resize_disk_vmware/              # resize via API vCenter
    ├── resize_disk_hyperv/              # resize via Resize-VHD sur l'hôte Hyper-V
    ├── run_guest_command/               # exécution PowerShell multi-canal dans l'invité
    └── resize_windows_filesystem/       # extension partition/FS dans l'invité
```

## Prérequis

- Ansible >= 2.15 (utilise `ignore_unreachable`)
- Collections : `ansible-galaxy collection install -r requirements.yml`
  (`community.vmware`, `ansible.windows`, `community.windows`)
- `pyvmomi` et `pywinrm` installés sur le nœud de contrôle (ou l'image
  d'exécution AWX)
- Compte de service vCenter avec droits de lecture sur l'inventaire et
  d'édition des disques des VM concernées
- Compte Windows invité avec les droits d'administration nécessaires pour
  `Resize-Partition` / `Update-HostStorageCache`
- **Fallback VMware Tools** : nécessite VMware Tools démarré dans
  l'invité (sinon WinRM down + Tools down = aucun canal disponible, le
  playbook échoue proprement).
- **Fallback Hyper-V / PowerShell Direct** : nécessite Hyper-V PowerShell
  sur l'hôte (`Invoke-Command -VMName`), disponible uniquement depuis
  l'hôte Hyper-V lui-même — d'où la délégation vers `resizedisk_hyperv_host`.
- **Hyper-V, resize à chaud** : le disque doit être rattaché à un
  contrôleur SCSI (VM Generation 2, ou disque de données SCSI sur une
  Generation 1). Un disque IDE nécessite l'arrêt de la VM.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# éditer inventory/hosts.yml : la liste des hôtes Hyper-V à interroger
# éditer inventory/group_vars/all.yml : connexion vCenter (identifiants via vault)

ansible-galaxy collection install -r requirements.yml

ansible-playbook playbooks/resize_disk.yml \
  -e vm_name=WINSRV01 \
  -e disk_new_size_gb=200 \
  -e windows_drive_letter=C \
  -e guest_username=Administrator \
  -e guest_password=*** \
  --vault-password-file .vault_pass
```

### Intégration ServiceNow

Cas d'usage typique : un *Catalog Item* / *Change Request* ServiceNow
déclenche, via **Ansible Automation Platform** (job template + webhook)
ou un **MID Server** exécutant `ansible-playbook` directement, un appel
avec les attributs de la CI en extra-vars (`vm_name`, `disk_new_size_gb`,
`windows_drive_letter`) et les identifiants invité issus du Credential
Store. Le résultat (`resizedisk_summary` via `set_stats`, ou le code de
sortie du job) permet à ServiceNow de mettre à jour le ticket/tâche
associé (succès, taille finale, canal d'exécution utilisé en cas de
repli WinRM indisponible).

## Variables

### Requises (extra-vars, fournies par le workflow appelant)

| Variable | Description |
|---|---|
| `vm_name` | Nom de la CI / VM, tel que connu de vCenter et/ou Hyper-V |
| `disk_new_size_gb` | Taille cible en Go |
| `windows_drive_letter` | Lettre de lecteur à étendre (ex. `C`) |
| `guest_username` / `guest_password` | Identifiants admin de l'OS invité |

### Optionnelles

| Variable | Défaut | Description |
|---|---|---|
| `hypervisor_type` | auto-détecté | `vmware` ou `hyperv`, pour sauter la recherche |
| `target_ip` | `vm_name` | IP/FQDN pour joindre l'invité en WinRM |
| `disk_controller_number` / `disk_unit_number` | `0` / `0` | disque SCSI VMware à agrandir |
| `disk_number_hyperv` | `0` | index du `VMHardDiskDrive` Hyper-V |
| `resizedisk_min_growth_gb` | `1` | garde-fou anti-shrink/no-op |
| `resizedisk_datastore_free_margin_gb` | `10` | marge de sécurité exigée sur le datastore VMware, en plus de la croissance demandée |
| `resizedisk_host_free_margin_gb` | `10` | marge de sécurité exigée sur le volume hôte Hyper-V, en plus de la croissance demandée |

### Par environnement (`inventory/group_vars/all.yml`)

| Variable | Description |
|---|---|
| `vcenter_hostname` / `vcenter_username` / `vcenter_password` / `vcenter_datacenter` | connexion API vCenter (une seule, pour tout le parc VMware) |
| `disk_controller_type` / `disk_controller_number` / `disk_unit_number` / `disk_number_hyperv` | défauts du disque ciblé (voir tableau "Optionnelles" ci-dessus) |
| groupe `hyperv_hypervisor` (inventaire) | parc des hôtes Hyper-V à interroger pour localiser une VM |

Ces variables vivent à ce niveau (plutôt qu'en `defaults/` de rôle) car
`preflight_disk_constraints`, `resize_disk_vmware` et `resize_disk_hyperv`
sont des rôles distincts inclus séparément : ils ne partagent pas leurs
`defaults/` respectifs, seulement les variables de portée plus large
(extra-vars, group_vars, facts).

Voir `inventory/hosts.yml.example` et `playbooks/resize_disk.yml` (en-tête)
pour le détail complet.
