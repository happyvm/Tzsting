# ansible-resizedisk

Playbook Ansible pour agrandir le disque virtuel d'une VM **Windows ou
Linux** — que celle-ci soit hébergée sur **VMware** (vSphere/ESXi) ou
**Hyper-V** — puis étendre automatiquement la partition/le système de
fichiers (Windows : NTFS via `Resize-Partition` ; Linux : `growpart` +
`resize2fs`/`xfs_growfs`/`btrfs`, avec prise en charge LVM) qui repose
dessus.

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
   Résout également `resizedisk_guest_os` (`windows`/`linux`) :
   auto-détecté côté VMware (`hw_guest_id`), à fournir explicitement via
   `guest_os` côté Hyper-V (voir note plus bas).

3. **`preflight_connectivity`** — détermine le canal pour parler au système
   invité, selon `resizedisk_guest_os` :
   - **Windows** : teste WinRM (`win_ping`, avec `ignore_unreachable`) ;
     si WinRM ne répond pas, bascule sur les **opérations invité VMware
     Tools** (VMware) ou **PowerShell Direct** (Hyper-V, canal **VMBus**,
     `Invoke-Command -VMName`, exécuté localement sur l'hôte Hyper-V).
   - **Linux** : teste SSH (module `ping`, avec `ignore_unreachable`) ;
     si SSH ne répond pas :
     - VM VMware → même repli VMware Tools que Windows (`vm_shell` avec
       `/bin/bash` au lieu de `powershell.exe`) : aucun accès réseau à
       l'invité requis, tout transite par l'API vCenter.
     - VM Hyper-V → **pas de repli agentless** : PowerShell Direct est un
       composant d'intégration propre à Windows, sans équivalent Linux
       natif. SSH down sur un Linux Hyper-V = échec net.
   - échoue si aucun canal n'est disponible, avec un message qui précise
     lequel manque (WinRM/SSH, VMware Tools, ou l'absence de repli
     Hyper-V+Linux).
   - expose `resizedisk_exec_method` (`winrm` / `ssh` / `vmware_tools` / `powershell_direct`).

   Volontairement placée *après* `preflight_disk_constraints` : inutile de
   payer le coût d'un timeout WinRM/SSH + repli pour une requête de toute
   façon vouée à l'échec côté disque.

4. **Agrandissement du disque côté hyperviseur** (`resize_disk_vmware` ou
   `resize_disk_hyperv` selon `resizedisk_hypervisor_type`) — API vCenter
   pour VMware, `Resize-VHD` délégué à l'hôte Hyper-V. Ne fait plus que
   l'action elle-même, les contrôles ayant déjà eu lieu à l'étape 2.
   Strictement identique pour Windows et Linux : au niveau hyperviseur, le
   disque n'a pas d'OS.

5. **`resize_windows_filesystem`** (Windows) ou **`resize_linux_filesystem`**
   (Linux), selon `resizedisk_guest_os` :
   - **Windows** : rescan du stockage, remise en ligne du disque si
     besoin, puis `Resize-Partition` jusqu'à la taille max.
   - **Linux** : rescan SCSI (`/sys/class/scsi_host/*/scan`, fonctionne
     pareil que le disque soit présenté en pvscsi/lsilogic VMware ou en
     hv_storvsc Hyper-V), détection LVM vs partition simple via `lsblk`,
     `growpart` sur la bonne partition (et, si LVM, `pvresize` +
     `lvextend -l +100%FREE` sur tous les PV de la VG concernée), puis
     resize du filesystem selon son type (`resize2fs`/`xfs_growfs`/`btrfs
     filesystem resize`).

   Les deux rôles s'exécutent via `run_guest_command`, un rôle générique
   qui envoie le même script (PowerShell ou bash) par le canal choisi à
   l'étape 3, en un seul aller-retour.

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
| `guest_os` manquant/invalide | auto-détecté depuis `hw_guest_id`, sauf override | **requis explicitement** (voir note) |
| Consolidation de snapshot en attente | `guest_consolidation_needed = true` | — |
| Snapshots / checkpoints présents | `vmware_guest_snapshot_info` → `guest_snapshots.snapshots` non vide | `Get-VMSnapshot` → count > 0 |
| RDM (physique ou virtuel) / virtual FC (NPIV) | `backing_type != 'FlatVer2'` (RDM = `RawDiskMappingVer1`, y compris RDM sur FC virtuel) | — (voir passthrough) |
| Disque introuvable (mauvais controller/unit/index) | liste des disques existants renvoyée dans le message d'erreur | déjà géré : `Get-VMHardDiskDrive` lève une exception explicite |
| Disque physique en passthrough | — | `VMHardDiskDrive.Path` vide (`DiskNumber` utilisé à la place) |
| Disque système sur contrôleur IDE (Generation 1) | — | `VMHardDiskDrive.ControllerType == 'IDE'` |
| VHD legacy au-delà de 2040GB | — | `Get-VHD.VhdFormat -eq 'VHD'` et taille demandée > 2040GB |
| VHDX partagé (cluster invité) | — | `SupportPersistentReservations = true` |
| Disque de différenciation | — | `Get-VHD.VhdType -eq 'Differencing'` |
| Réplication active (DR) | — | `Get-VMReplication` → `State != 'Disabled'` |
| Datastore/volume inaccessible | `accessible = false` sur le datastore | — |
| Espace libre insuffisant sur le stockage sous-jacent | `freeSpace` du datastore < croissance demandée + `resizedisk_datastore_free_margin_gb` | `PSDrive.Free` du volume hôte < croissance demandée + `resizedisk_host_free_margin_gb` |
| Taille demandée au-delà du plafond de politique | `disk_new_size_gb > resizedisk_max_size_gb` (les deux plateformes) | idem |
| Partition qui ne gagne aucun espace malgré le disque agrandi | vérifié après coup dans `resize_windows_filesystem` (voir note) | idem |

**Disque multi-writer (VMware) - non implémenté.** Ce flag (utilisé pour
Oracle RAC ou d'autres clusters partageant un même VMDK) n'est exposé en
lecture par aucun module de `community.vmware` ni de `vmware.vmware`
installés ici - seul le module de *convergence* `vmware.vmware.vm` le
connaît (`backing.sharing`), et s'en servir en lecture seule risquerait
de déclencher une modification involontaire du disque. Vérification
manuelle recommandée pour les VM concernées (clusters applicatifs
partageant un disque) tant qu'aucun module dédié ne l'expose proprement.

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
jointe par WinRM/SSH, VMware Tools ou PowerShell Direct - une VM éteinte
est donc bloquée dès le preflight plutôt que de laisser échouer la sonde
de connectivité avec un message moins parlant.

**`guest_os` : auto-détecté côté VMware, obligatoire côté Hyper-V.**
Côté VMware, `hw_guest_id` (déjà en cache depuis `preflight_platform`)
suffit à distinguer Windows de Linux avant même de savoir si WinRM/SSH
répond. Côté Hyper-V, `Get-VM` n'expose pas nativement l'OS invité sans
déjà parler à la VM (WinRM/CIM) - ce qui casserait l'ordre volontaire
"disque avant connectivité" - donc `guest_os` doit être fourni
explicitement en extra-var pour toute VM Hyper-V. Dans les deux cas,
passer `guest_os` explicitement court-circuite toujours la détection.

**Cohérence disque agrandi / cible visée.** Rien ne garantit, avant
d'agrandir, que `windows_drive_letter`/`linux_target` réside bien sur le
disque identifié par `disk_controller_number`/`disk_unit_number` (VMware)
ou `disk_number_hyperv` (Hyper-V) - une erreur de paramétrage ServiceNow
grandirait silencieusement le mauvais disque. Plutôt que de tenter une
corrélation d'identifiants fragile avant même de savoir parler à l'invité,
`resize_windows_filesystem`/`resize_linux_filesystem` vérifient le
résultat réel côté invité après coup : si le disque a été agrandi (le
preflight l'a déjà garanti) mais que la partition/le filesystem visé n'a
gagné aucun espace, c'est un signal fort d'un mauvais paramétrage - le
playbook échoue explicitement plutôt que de rapporter silencieusement
"déjà à la taille max". Côté Linux, ce même échec peut aussi signaler
qu'un volume group LVM a des PV sur plusieurs disques dont un seul a été
agrandi.

> **Note** : les noms de champs `hw_power_status`, `hw_is_template`,
> `hw_guest_id`/`hw_guest_full_name` et `guest_consolidation_needed`
> proviennent de `community.vmware.vmware_guest_info` (déjà appelé par
> `preflight_platform`, donc sans coût supplémentaire) - à valider contre
> la version de la collection réellement installée.

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
    ├── preflight_disk_constraints/      # snapshot/RDM/passthrough/VHDX partagé... -> bloque tôt + guest_os
    ├── preflight_connectivity/          # WinRM/SSH, sinon VMware Tools / PowerShell Direct
    ├── resize_disk_vmware/              # resize via API vCenter
    ├── resize_disk_hyperv/              # resize via Resize-VHD sur l'hôte Hyper-V
    ├── run_guest_command/               # exécution PowerShell/bash multi-canal dans l'invité
    ├── resize_windows_filesystem/       # extension partition NTFS dans l'invité Windows
    └── resize_linux_filesystem/         # growpart + resize2fs/xfs_growfs/btrfs (+ LVM) dans l'invité Linux
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
- Compte Linux invité root, ou avec sudo (`linux_become: true` +
  éventuellement `linux_become_password`), et les paquets `growpart`
  (`cloud-guest-utils` Debian/Ubuntu, `cloud-utils-growpart` RHEL/SUSE)
  + `parted`/`partprobe`, `resize2fs` (ext*), `xfsprogs` (XFS) ou
  `btrfs-progs` (Btrfs) selon le filesystem ; `lvm2` en plus si LVM est
  utilisé. Aucun de ces paquets n'est installé automatiquement par le
  playbook - échec explicite si l'outil requis manque.
- **Fallback VMware Tools** (Windows et Linux) : nécessite VMware Tools/
  `open-vm-tools` démarré dans l'invité (sinon WinRM/SSH down + Tools down
  = aucun canal disponible, le playbook échoue proprement).
- **Fallback Hyper-V / PowerShell Direct** (Windows uniquement) : nécessite
  Hyper-V PowerShell sur l'hôte (`Invoke-Command -VMName`), disponible
  uniquement depuis l'hôte Hyper-V lui-même — d'où la délégation vers
  `resizedisk_hyperv_host`. **Pas d'équivalent pour un invité Linux** : sur
  Hyper-V, SSH doit être joignable, il n'y a pas de repli agentless.
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

Exemple Linux (VM Hyper-V, donc `guest_os` obligatoire ; clé SSH plutôt
que mot de passe ; compte non-root avec sudo) :

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

### Intégration ServiceNow

Cas d'usage typique : un *Catalog Item* / *Change Request* ServiceNow
déclenche, via **Ansible Automation Platform** (job template + webhook)
ou un **MID Server** exécutant `ansible-playbook` directement, un appel
avec les attributs de la CI en extra-vars (`vm_name`, `disk_new_size_gb`,
`windows_drive_letter` ou `linux_target` selon l'OS) et les identifiants
invité issus du Credential Store. Le résultat (`resizedisk_summary` via
`set_stats`, ou le code de sortie du job) permet à ServiceNow de mettre à
jour le ticket/tâche associé (succès, taille finale, canal d'exécution
utilisé en cas de repli WinRM/SSH indisponible).

## Variables

### Requises (extra-vars, fournies par le workflow appelant)

| Variable | Description |
|---|---|
| `vm_name` | Nom de la CI / VM, tel que connu de vCenter et/ou Hyper-V |
| `disk_new_size_gb` | Taille cible en Go |
| `guest_username` | Identifiant admin de l'OS invité |
| `guest_password` | Mot de passe invité - requis pour Windows ; pour Linux, alternative à `guest_ssh_private_key_file` |
| `windows_drive_letter` | Lettre de lecteur à étendre (ex. `C`) - **requis si l'invité est Windows** |
| `linux_target` | Point de montage à étendre (ex. `/`, `/data`) - **requis si l'invité est Linux** (défaut `/` si omis) |

### Optionnelles

| Variable | Défaut | Description |
|---|---|---|
| `hypervisor_type` | auto-détecté | `vmware` ou `hyperv`, pour sauter la recherche |
| `guest_os` | auto-détecté (VMware) | `windows` ou `linux` - **obligatoire pour une VM Hyper-V** (voir note plus haut) |
| `target_ip` | `vm_name` | IP/FQDN pour joindre l'invité en WinRM/SSH |
| `guest_ssh_private_key_file` | — | Linux : clé privée SSH, alternative à `guest_password` |
| `linux_ssh_port` | `22` | port SSH |
| `linux_become` | `false` | passer par sudo côté Linux si `guest_username` n'est pas root |
| `linux_become_password` | — | mot de passe sudo, si nécessaire |
| `disk_controller_number` / `disk_unit_number` | `0` / `0` | disque SCSI VMware à agrandir |
| `disk_number_hyperv` | `0` | index du `VMHardDiskDrive` Hyper-V |
| `resizedisk_min_growth_gb` | `1` | garde-fou anti-shrink/no-op |
| `resizedisk_datastore_free_margin_gb` | `10` | marge de sécurité exigée sur le datastore VMware, en plus de la croissance demandée |
| `resizedisk_host_free_margin_gb` | `10` | marge de sécurité exigée sur le volume hôte Hyper-V, en plus de la croissance demandée |
| `resizedisk_max_size_gb` | `2000` | plafond de politique anti-saisie-erronée ; à relever explicitement pour un disque légitimement plus gros |

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
