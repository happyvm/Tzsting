# ansible-resizedisk

Playbook Ansible pour agrandir le disque virtuel d'une VM Windows — que
celle-ci soit hébergée sur **VMware** (vSphere/ESXi) ou **Hyper-V** — puis
étendre automatiquement la partition/le système de fichiers Windows qui
repose dessus.

## Fonctionnement

Le play se déroule en deux temps, pilotés par la variable d'inventaire
`hypervisor_type` définie sur chaque hôte :

1. **Agrandissement du disque côté hyperviseur**
   - `hypervisor_type: vmware` → rôle `resize_disk_vmware`, exécuté en
     local (`delegate_to: localhost`) via l'API vCenter
     (module `community.vmware.vmware_guest_disk`).
   - `hypervisor_type: hyperv` → rôle `resize_disk_hyperv`, délégué à
     l'hôte Hyper-V (`delegate_to: "{{ hyperv_host }}"`) via WinRM,
     en pilotant `Resize-VHD` en PowerShell (pas d'API distante
     équivalente à vCenter côté Hyper-V).

2. **Extension du système de fichiers côté invité** (`resize_windows_filesystem`)
   - Identique quel que soit l'hyperviseur : rescan du stockage
     (`Update-HostStorageCache`), remise en ligne du disque si besoin,
     puis `Resize-Partition` jusqu'à la taille maximale disponible.

Les deux rôles de resize disque sont **idempotents et refusent de
rétrécir ou de ne rien faire** : si la taille demandée n'est pas au
moins `resizedisk_min_growth_gb` (par défaut 1 Go) au-dessus de la
taille actuelle, la tâche échoue explicitement plutôt que de silencieusement
ne rien faire.

## Arborescence

```
ansible-resizedisk/
├── ansible.cfg
├── requirements.yml                 # collections requises
├── inventory/hosts.yml.example      # exemple d'inventaire (VMware + Hyper-V)
├── group_vars/all.yml               # garde-fou anti-shrink
├── playbooks/resize_disk.yml        # playbook principal
└── roles/
    ├── resize_disk_vmware/          # resize via API vCenter
    ├── resize_disk_hyperv/          # resize via Resize-VHD sur l'hôte Hyper-V
    └── resize_windows_filesystem/   # extension partition/FS dans l'invité
```

## Prérequis

- Ansible >= 2.15
- Collections : `ansible-galaxy collection install -r requirements.yml`
  (`community.vmware`, `ansible.windows`, `community.windows`)
- `pyvmomi` installé sur le nœud de contrôle (requis par `community.vmware`)
- WinRM activé et joignable sur : l'hôte Hyper-V (si applicable) et la VM
  Windows invitée
- Compte Windows invité avec les droits d'administration nécessaires pour
  `Resize-Partition` / `Update-HostStorageCache`
- **Hyper-V uniquement** : pour un resize à chaud, le disque doit être
  rattaché à un contrôleur SCSI (VM Generation 2, ou disque de données
  SCSI sur une Generation 1). Un disque IDE nécessite l'arrêt de la VM.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# éditer inventory/hosts.yml avec vos VMs, identifiants (idéalement via ansible-vault)

ansible-galaxy collection install -r requirements.yml

# Resize d'une VM précise, avec la taille définie dans l'inventaire
ansible-playbook playbooks/resize_disk.yml -l winsrv01

# Ou en surchargeant la taille cible à la volée
ansible-playbook playbooks/resize_disk.yml -l winsrv01 -e disk_new_size_gb=200
```

## Variables principales (par hôte, dans `guest_windows`)

| Variable | Utilisée par | Description |
|---|---|---|
| `hypervisor_type` | routing | `vmware` ou `hyperv` |
| `vm_name` | les deux rôles resize disque | nom de la VM sur l'hyperviseur |
| `disk_new_size_gb` | les deux rôles resize disque | taille cible en Go |
| `windows_drive_letter` | `resize_windows_filesystem` | lettre de lecteur à étendre |
| `vcenter_hostname/username/password/datacenter` | `resize_disk_vmware` | connexion API vCenter |
| `disk_controller_number` / `disk_unit_number` | `resize_disk_vmware` | identification du disque SCSI |
| `hyperv_host` | `resize_disk_hyperv` | hôte Hyper-V (doit être dans le groupe `hyperv_hypervisor`) |
| `disk_number_hyperv` | `resize_disk_hyperv` | index du `VMHardDiskDrive` sur la VM |

Voir `inventory/hosts.yml.example` pour un exemple complet des deux cas.
