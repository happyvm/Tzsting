# Documentation Ansible du dépôt

Ce document est le **point d'entrée commun** de tout le code Ansible présent
dans ce dépôt. Il décrit le catalogue des automatisations, leur architecture,
leur exploitation avec Ansible Automation Platform (AAP)/ServiceNow, les
variables communes, les contrôles de sécurité et les commandes de validation.

Les détails techniques propres à une opération restent documentés dans le
`README.md` de chaque répertoire : ce guide ne les remplace pas, il les relie
et fournit une vue d'ensemble cohérente.

L'analyse des phases du cycle de vie **non couvertes** (matériel, OS,
hyperviseurs) et les options à prévoir sont regroupées dans
[`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md).

## Sommaire

- [Catalogue des projets](#catalogue-des-projets)
- [Matrice fonctionnelle](#matrice-fonctionnelle)
- [Architecture commune](#architecture-commune)
- [Prérequis du nœud de contrôle](#prérequis-du-nœud-de-contrôle)
- [Inventaire et credentials](#inventaire-et-credentials)
- [Intégration AAP et ServiceNow](#intégration-aap-et-servicenow)
- [Exploitation par projet](#exploitation-par-projet)
- [Sécurité et garde-fous](#sécurité-et-garde-fous)
- [Tests et analyse statique](#tests-et-analyse-statique)
- [Dépannage](#dépannage)

## Catalogue des projets

### `ansible-createvm`

Création d'une VM depuis un template, dimensionnement et personnalisation de
l'OS invité :

- VMware : clonage vSphere, sysprep Windows ou cloud-init Linux ;
- Hyper-V : création via SCVMM (pas de chemin Hyper-V natif) ;
- verrou par nom de VM avant création ;
- contrôle d'unicité du nom, des limites CPU/RAM/disque et des paramètres de
  personnalisation ;
- artefact AAP : `createvm_summary`.

Playbook : `ansible-createvm/playbooks/create_vm.yml`.

Documentation complète : [`ansible-createvm/README.md`](ansible-createvm/README.md).

### `ansible-deletevm`

Arrêt, annulation d'une décommission ou suppression définitive d'une VM :

- `decommission_stop.yml` : arrêt gracieux et marquage pour suppression ;
- `decommission_cancel.yml` : retrait du marqueur et restauration de l'état ;
- `delete_vm.yml` : suppression définitive des fichiers et de la VM ;
- VMware, Hyper-V natif et Hyper-V géré par SCVMM ;
- confirmation explicite `confirm_delete=true` pour la suppression.

Documentation complète : [`ansible-deletevm/README.md`](ansible-deletevm/README.md).

### `ansible-resizecompute`

Modification du nombre de vCPU ou de la mémoire :

- `resize_cpu.yml` et `resize_ram.yml` séparés pour permettre des droits et
  workflows d'approbation distincts ;
- hot-add VMware lorsque la plateforme et la VM l'autorisent ;
- arrêt/redémarrage coordonné lorsque la modification à chaud est impossible ;
- Hyper-V natif ou SCVMM ;
- aucun accès à l'OS invité.

Documentation complète :
[`ansible-resizecompute/README.md`](ansible-resizecompute/README.md).

### `ansible-resizedisk`

Extension d'un disque virtuel puis de la partition et du système de fichiers :

- VMware, Hyper-V natif ou SCVMM ;
- invité Windows : `Resize-Partition` ;
- invité Linux : partitions classiques, LVM, ext, XFS ou Btrfs ;
- connexion WinRM/SSH, avec mécanismes de repli documentés dans le projet ;
- refus des réductions, snapshots/checkpoints incompatibles, disques partagés,
  pass-through et stockages dégradés.

Playbook : `ansible-resizedisk/playbooks/resize_disk.yml`.

Documentation complète :
[`ansible-resizedisk/README.md`](ansible-resizedisk/README.md).

### `ansible-snapshot`

Gestion du cycle de vie des snapshots VMware et checkpoints Hyper-V :

- `snapshot_create.yml` : création ;
- `snapshot_list.yml` : inventaire en lecture seule ;
- `snapshot_remove.yml` : suppression ciblée ;
- `snapshot_revert.yml` : retour arrière, avec checkpoint de sécurité par
  défaut ;
- résolution non ambiguë des noms et identifiants ;
- aucune connexion à l'OS invité.

Documentation complète : [`ansible-snapshot/README.md`](ansible-snapshot/README.md).

### `ansible-inplace-upgrade`

Montée de version sur place d'un OS invité :

- Windows Server avec `setup.exe` en mode unattended ;
- Red Hat Enterprise Linux avec Leapp ;
- détection VMware/Hyper-V puis connexion dynamique WinRM/SSH ;
- allowlist des chemins de versions, espace libre minimal et contrôles de
  reboot/inhibiteurs ;
- snapshot/checkpoint de rollback avant mutation ;
- vérification de la version active après redémarrage ;
- artefact AAP : `inplace_upgrade_summary`.

Playbook : `ansible-inplace-upgrade/playbooks/inplace_upgrade.yml`.

Documentation complète :
[`ansible-inplace-upgrade/README.md`](ansible-inplace-upgrade/README.md).

### `ansible-purestorage-conf`

Configuration des services d’une baie FlashArray : Active Directory, NTP,
syslog, timezone, rotation du mot de passe du compte local `pureuser`, relais
SMTP/destinataires d’alerte email et SNMP (manager de traps et agent,
SNMPv3 ou v2c).

Playbook : `ansible-purestorage-conf/playbooks/configure_array.yml`.

Documentation complète :
[`ansible-purestorage-conf/README.md`](ansible-purestorage-conf/README.md).

### `ansible-purestorage-volhost-create`

Création et maintien déclaratif des volumes, hosts FC/iSCSI/NVMe, hostgroups et
connexions host-volume d’une baie FlashArray.

Playbook : `ansible-purestorage-volhost-create/playbooks/maintain_storage.yml`.

Documentation complète :
[`ansible-purestorage-volhost-create/README.md`](ansible-purestorage-volhost-create/README.md).

### `ansible-purestorage-volhost-remove`

Suppression ordonnée des mappings, hostgroups, hosts et volumes, avec double
confirmation pour l’éradication irréversible.

Playbook : `ansible-purestorage-volhost-remove/playbooks/remove_storage.yml`.

Documentation complète :
[`ansible-purestorage-volhost-remove/README.md`](ansible-purestorage-volhost-remove/README.md).

### `ansible-synergy-conf`

Configuration NTP, timezone, Active Directory et administrateur local d’une
appliance HPE OneView/Synergy, plus redirection syslog, alertes SMTP et
SNMPv3 (utilisateurs et destinations de traps) en options.

Documentation : [`ansible-synergy-conf/README.md`](ansible-synergy-conf/README.md).

### `ansible-synergy-vlan-add` / `ansible-synergy-vlan-remove`

Ajout ou suppression ordonnée d’un VLAN dans OneView, un Network Set Virtual
Connect et le Server Profile affecté à une lame.

Documentation : [`ansible-synergy-vlan-add/README.md`](ansible-synergy-vlan-add/README.md)
et [`ansible-synergy-vlan-remove/README.md`](ansible-synergy-vlan-remove/README.md).

### `ansible-synergy-get`

Inventaire en lecture seule d’une lame : identité, état, port map, adresses MAC
Ethernet et WWN/WWPN SAN issues du profil.

Documentation : [`ansible-synergy-get/README.md`](ansible-synergy-get/README.md).

### `ansible-quantum-dxi-conf`

Configuration des comptes locaux, Active Directory, NTP et timezone d’une
appliance Quantum DXi au moyen de son contrat REST spécifique au firmware,
plus redirection syslog, alertes SMTP et SNMP (v3 recommandé selon le
firmware) en options.

Documentation : [`ansible-quantum-dxi-conf/README.md`](ansible-quantum-dxi-conf/README.md).

### `ansible-hpe-storeonce-conf`

Configuration équivalente pour une appliance HPE StoreOnce, avec validation
obligatoire des endpoints correspondant à sa version logicielle, plus
redirection syslog, alertes SMTP et SNMP (v3 recommandé, v1/v2c selon le
firmware) en options.

Documentation : [`ansible-hpe-storeonce-conf/README.md`](ansible-hpe-storeonce-conf/README.md).

### `windows-hyperv-conf` / `windows-scvmm-conf`

Configuration des services d’un hôte Windows Server Hyper-V natif, ou du
serveur de management SCVMM lui-même (jonction Active Directory optionnelle,
compte local d’automatisation, NTP, timezone, SNMP en option), directement
via WinRM/PowerShell plutôt qu’une API REST. Aucun redémarrage n’est
déclenché automatiquement par la jonction AD. Le SNMP embarqué de Windows
Server (`community.windows.win_snmp`) ne supporte que v1/v2c - aucune option
SNMPv3 n’existe pour ce composant ; il n’y a par ailleurs aucun mécanisme
SMTP ou syslog natif au niveau de l’OS (voir les README respectifs).

Documentation : [`windows-hyperv-conf/README.md`](windows-hyperv-conf/README.md)
et [`windows-scvmm-conf/README.md`](windows-scvmm-conf/README.md).

### `windows-scvmm-addvlan` / `windows-scvmm-removevlan`

Ajout ou suppression ordonnée d’un VLAN dans le modèle réseau SCVMM (réseau
logique/site réseau → VM Network → carte réseau de VM), via le module
PowerShell `virtualmachinemanager` déjà utilisé par `ansible-createvm`/
`ansible-resizecompute`/`ansible-resizedisk` pour leurs propres opérations
SCVMM. Réutilise l’inventaire `scvmm_management` de ces projets.

Documentation : [`windows-scvmm-addvlan/README.md`](windows-scvmm-addvlan/README.md)
et [`windows-scvmm-removevlan/README.md`](windows-scvmm-removevlan/README.md).

### `vmware-esxi-conf`

Configuration d’un hôte ESXi autonome (sans vCenter) : NTP, syslog distant,
jonction Active Directory optionnelle, compte local d’automatisation et SNMP
en option (v1/v2c uniquement - le module `community.vmware.vmware_host_snmp`
n’implémente pas SNMPv3), via les modules `community.vmware` connectés
directement à l’API de gestion de l’hôte.

Documentation : [`vmware-esxi-conf/README.md`](vmware-esxi-conf/README.md).

### `vmware-vcenter-conf`

Configuration de l’appliance vCenter Server (VCSA) : NTP, timezone, rotation
du mot de passe administrateur local et redirection syslog en option via
l’API VAMI (aucune collection ne la couvre), niveau de journalisation,
alertes SMTP et destinataires SNMP (v1/v2c uniquement, ces deux derniers en
option) du serveur vCenter via le module réel
`community.vmware.vmware_vcenter_settings`, et planification de la
sauvegarde native de l’appliance elle-même (en option) via le module réel
`vmware.vmware.vcsa_backup_schedule` - pas une sauvegarde des VM invitées,
voir `ansible-veeam-conf`/`ansible-netbackup-conf` pour cette partie.

Documentation : [`vmware-vcenter-conf/README.md`](vmware-vcenter-conf/README.md).

### `vmware-vcenter-addvlan` / `vmware-vcenter-removevlan`

Ajout ou suppression ordonnée d’un VLAN dans vCenter sous forme de portgroup
de Distributed vSwitch, avec rattachement/retrait optionnel de la carte
réseau d’une VM. Réutilise les mêmes variables de connexion vCenter
(`vcenter_hostname`/`username`/`password`, `vmware_validate_certs`) que
`ansible-createvm`/`ansible-resizecompute`/etc.

Documentation : [`vmware-vcenter-addvlan/README.md`](vmware-vcenter-addvlan/README.md)
et [`vmware-vcenter-removevlan/README.md`](vmware-vcenter-removevlan/README.md).

### `ansible-veeam-conf`

Configuration déclarative du serveur Windows hébergeant **Veeam Backup &
Replication** - jonction AD optionnelle, compte local, NTP, timezone via
WinRM (même schéma que `windows-hyperv-conf`) - et des réglages de
notification globaux (email, SNMP) de VBR lui-même via son API REST
réelle (authentification OAuth 2.0 - `POST /api/oauth2/token`, pas d’auth
basique). Ne couvre ni les jobs de sauvegarde, ni les repositories, ni les
restaurations, ni le RBAC applicatif de VBR - voir le README pour le
périmètre exact et son lien avec l’écart 4.15/4.16 de
`CYCLE-DE-VIE-GAPS.md` et [`VEEAM-NETBACKUP-ROADMAP.md`](VEEAM-NETBACKUP-ROADMAP.md).

Documentation : [`ansible-veeam-conf/README.md`](ansible-veeam-conf/README.md).

### `ansible-netbackup-conf`

Équivalent pour un serveur primaire **Veritas NetBackup** sur Linux
standard (les NetBackup Appliances sont hors périmètre) : compte local,
NTP et timezone via SSH, plus réglages de notification SMTP et SNMP via
son API REST réelle (authentification par jeton JWT -
`POST /netbackup/login`, pas d’auth basique). Même périmètre
volontairement restreint que `ansible-veeam-conf`.

Documentation : [`ansible-netbackup-conf/README.md`](ansible-netbackup-conf/README.md).

### `ansible-azure-arc-agent-deploy`

Enregistrement d’un serveur Windows ou Linux dans **Azure Arc-enabled
Servers**, via SSH ou WinRM. Enveloppe fine du rôle officiel
`azure.azcollection.azure_arc` documenté par Microsoft pour cet usage
(installation de l’agent, idempotence et refus de re-enregistrement
croisé d’un tenant/cloud/resource group/location différent, tous hérités
du rôle officiel) plutôt qu’une réimplémentation d’`azcmagent`.
Authentification par service principal uniquement. Le mode `audit` a des
limites documentées dans le README : le rôle officiel exécute toujours
pour de vrai sa requête de jeton Azure AD et son `azcmagent show`
(lecture seule), seule la commande mutante `azcmagent connect` est
réellement simulée - voir
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](ENDPOINT-MANAGEMENT-ROADMAP.md).

Documentation : [`ansible-azure-arc-agent-deploy/README.md`](ansible-azure-arc-agent-deploy/README.md).

### `ansible-sccm-device-collection-add`

Ajout idempotent d’une machine dans une device collection **Microsoft
Configuration Manager (SCCM)**, via le vrai module PowerShell
`ConfigurationManager` exécuté sur un hôte Windows qui l’a déjà
installé. Résolution exacte du device et de la collection, ajout d’une
direct membership rule uniquement (jamais query/include/exclude), mise à
jour facultative de la collection. Le mode `audit` s’appuie sur le
support natif `-WhatIf` des cmdlets plutôt que sur le check mode Ansible,
puisqu’un unique script PowerShell personnalisé gère toute la logique
dans une même session/PSDrive - voir
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](ENDPOINT-MANAGEMENT-ROADMAP.md).

Documentation : [`ansible-sccm-device-collection-add/README.md`](ansible-sccm-device-collection-add/README.md).

## Matrice fonctionnelle

| Projet | VMware | Hyper-V natif | SCVMM | Accès invité | Mutation destructive |
|---|---:|---:|---:|---:|---:|
| `ansible-createvm` | Oui | Non | Oui | Personnalisation | Création |
| `ansible-deletevm` | Oui | Oui | Oui | Arrêt gracieux possible | Oui |
| `ansible-resizecompute` | Oui | Oui | Oui | Non | Reconfiguration |
| `ansible-resizedisk` | Oui | Oui | Oui | WinRM/SSH | Extension uniquement |
| `ansible-snapshot` | Oui | Oui | Oui pour mutation | Non | Selon l'action |
| `ansible-inplace-upgrade` | Oui | Oui | VM accessible via Hyper-V | WinRM/SSH | Upgrade OS |
| `ansible-purestorage-conf` | FlashArray | — | — | API/SSH optionnel | Configuration |
| `ansible-purestorage-volhost-create` | FlashArray | — | — | API | Provisionnement |
| `ansible-purestorage-volhost-remove` | FlashArray | — | — | API | Oui |
| `ansible-synergy-conf` | OneView/Synergy | — | — | API | Configuration |
| `ansible-synergy-vlan-add` | OneView/VC | — | — | API | Réseau |
| `ansible-synergy-vlan-remove` | OneView/VC | — | — | API | Oui |
| `ansible-synergy-get` | OneView/Synergy | — | — | API | Non |
| `ansible-quantum-dxi-conf` | Quantum DXi | — | — | API | Configuration |
| `ansible-hpe-storeonce-conf` | HPE StoreOnce | — | — | API | Configuration |
| `windows-hyperv-conf` | — | Oui | — | WinRM | Configuration |
| `windows-scvmm-conf` | — | — | Oui | WinRM | Configuration |
| `windows-scvmm-addvlan` | — | — | Oui | WinRM | Réseau |
| `windows-scvmm-removevlan` | — | — | Oui | WinRM | Oui |
| `vmware-esxi-conf` | ESXi (autonome) | — | — | API | Configuration |
| `vmware-vcenter-conf` | vCenter | — | — | API/VAMI | Configuration |
| `vmware-vcenter-addvlan` | vCenter | — | — | API | Réseau |
| `vmware-vcenter-removevlan` | vCenter | — | — | API | Oui |
| `ansible-veeam-conf` | — | — | — | API | Configuration |
| `ansible-netbackup-conf` | — | — | — | API | Configuration |
| `ansible-azure-arc-agent-deploy` | — | — | — | SSH/WinRM | Installation/enregistrement |
| `ansible-sccm-device-collection-add` | — | — | — | WinRM | Ajout à une collection |

Le support précis dépend des versions de vSphere, Windows/Hyper-V, SCVMM,
Ansible et des collections installées. Les fichiers `requirements.yml` de
chaque projet constituent la référence pour les collections.

## Architecture commune

Chaque projet est autonome et contient généralement :

```text
ansible-<operation>/
├── ansible.cfg
├── requirements.yml
├── .ansible-lint
├── .yamllint
├── inventory/
│   ├── hosts.yml.example
│   └── group_vars/all.yml
├── playbooks/
├── roles/
├── scripts/
└── README.md
```

Principes communs :

1. **Orchestration depuis `localhost`** : le playbook pilote les API VMware et
   délègue les commandes PowerShell aux hôtes Hyper-V/SCVMM.
2. **Pas d'inventaire statique par VM** : `vm_name` et les paramètres de la
   demande viennent des extra-vars AAP/ServiceNow.
3. **Détection de plateforme** : sauf pour la création, le rôle
   `preflight_platform` recherche la VM dans vCenter et sur les hôtes Hyper-V,
   puis refuse une cible absente ou ambiguë.
4. **Préflight bloquant** : les contraintes sont validées avant la mutation.
5. **Verrou par opération et par VM** : il réduit le risque de deux jobs
   concurrents du même projet. Les namespaces de verrou étant propres aux
   projets, le workflow d'entreprise doit aussi empêcher des opérations
   différentes et incompatibles sur la même VM.
6. **Rôles par plateforme** : les implémentations VMware, Hyper-V et SCVMM sont
   séparées afin de préserver la cohérence du plan de management.
7. **Résultat machine-readable** : `ansible.builtin.set_stats` expose un
   artefact que le workflow appelant peut récupérer.
8. **Libération dans `always`** : les locks des opérations mutantes sont
   libérés même lorsqu'une tâche échoue.

## Prérequis du nœud de contrôle

- une version maintenue d'`ansible-core` ;
- Python 3 et les SDK demandés par les collections VMware ;
- accès réseau HTTPS au vCenter ;
- accès WinRM aux hôtes Hyper-V et au serveur SCVMM éventuel ;
- accès WinRM/SSH aux invités pour `resizedisk` et `inplace-upgrade` ;
- accès aux dépôts Galaxy internes ou publics pour installer les collections ;
- `ansible-lint`, `yamllint`, PSScriptAnalyzer et ShellCheck recommandés en CI.

Installation d'un projet :

```bash
cd ansible-snapshot                    # exemple
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
```

Les projets sont autonomes : exécuter l'installation depuis le répertoire de
l'opération permet à `ansible.cfg` de résoudre son inventaire et ses rôles.

## Inventaire et credentials

### Inventaire Hyper-V

Copier le modèle du projet sans modifier le fichier versionné :

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
```

Le groupe `hyperv_hypervisor` contient tous les hôtes à interroger. Dans un
cluster, renseigner chaque nœud susceptible de posséder la VM. Si le projet
utilise SCVMM, déclarer aussi le serveur dans le groupe prévu par son exemple
d'inventaire et configurer `scvmm_server`.

### Configuration VMware

Les valeurs d'environnement sont dans `inventory/group_vars/all.yml` :

- `vcenter_hostname` ;
- `vcenter_datacenter` ;
- `vcenter_username` et `vcenter_password` issus de variables Vault ;
- `vmware_validate_certs`.

En production, conserver la validation TLS active et déployer la chaîne de
certificats interne sur les execution environments AAP.

### Secrets

Ne jamais passer de secret dans un dépôt, un survey non chiffré ou une ligne de
commande conservée dans l'historique. Utiliser, selon la plateforme :

- credentials Machine/VMware personnalisés dans AAP ;
- Ansible Vault ;
- un gestionnaire de secrets intégré à AAP ;
- `no_log: true` pour toute tâche qui manipule directement des secrets.

Variables fréquemment utilisées :

- `vault_vcenter_username`, `vault_vcenter_password` ;
- `vault_hyperv_username`, `vault_hyperv_password` ;
- `vault_scvmm_username`, `vault_scvmm_password` ;
- credentials invités Windows/Linux pour les projets qui s'y connectent.

## Intégration AAP et ServiceNow

### Modèle de job AAP

Créer un Job Template par playbook exposé. Recommandations :

1. associer le projet Git et l'inventaire de l'environnement ;
2. attacher les credentials vCenter, Hyper-V/SCVMM et invité nécessaires ;
3. utiliser un Execution Environment contenant les collections du
   `requirements.yml` ;
4. activer uniquement les extra-vars prévues via un Survey ;
5. appliquer des droits distincts aux opérations de lecture, mutation et
   suppression ;
6. définir un timeout supérieur aux opérations longues (upgrade OS, fusion de
   snapshot, arrêt gracieux) ;
7. conserver les événements de job et les artefacts selon la politique d'audit.

### Données ServiceNow

Le workflow peut construire les extra-vars depuis le CI et le RITM/Change :

```yaml
vm_name: WINSRV01
hypervisor_type: vmware
change_number: CHG0012345
```

Il doit ensuite :

1. vérifier les approbations et la fenêtre de changement ;
2. lancer le Job Template AAP correspondant ;
3. attendre son état terminal ;
4. lire l'artefact publié par `set_stats` ;
5. journaliser le résultat dans la demande et déclencher la validation ;
6. ne clôturer le changement qu'après les contrôles fonctionnels.

Les extra-vars destructives (`confirm_delete`, désactivation d'un snapshot de
sécurité, autorisation d'une VM clusterisée, etc.) doivent être protégées par
une approbation et ne pas être librement éditables par le demandeur.

## Exploitation par projet

Les commandes suivantes sont des squelettes. Consulter le README du projet
avant usage : il décrit toutes les variables et les limites.

### Créer une VM

```bash
cd ansible-createvm
ansible-playbook playbooks/create_vm.yml \
  -e hypervisor_type=vmware \
  -e vm_name=APP01 \
  -e template_name=RHEL9-GOLD \
  -e guest_os=linux -e vcpu_count=4 -e memory_gb=8 \
  -e vmware_datastore=DATASTORE01 -e network_name=SERVER-LAN \
  -e vmware_cluster=CLUSTER01
```

`hypervisor_type` est obligatoire car aucune VM existante ne peut être
recherchée pour déduire sa plateforme.

### Arrêter, annuler ou supprimer une VM

```bash
cd ansible-deletevm
ansible-playbook playbooks/decommission_stop.yml -e vm_name=APP01
ansible-playbook playbooks/decommission_cancel.yml -e vm_name=APP01
ansible-playbook playbooks/delete_vm.yml -e vm_name=APP01 -e confirm_delete=true
```

La suppression est irréversible. Une restauration nécessite une sauvegarde
externe valide ; un snapshot attaché à la VM n'est pas une sauvegarde.

### Modifier CPU ou RAM

```bash
cd ansible-resizecompute
ansible-playbook playbooks/resize_cpu.yml -e vm_name=APP01 -e vcpu_count=8
ansible-playbook playbooks/resize_ram.yml -e vm_name=APP01 -e memory_gb=32
```

Si un arrêt est requis, fournir la fenêtre de redémarrage demandée dans le
README et s'assurer que l'arrêt applicatif est autorisé.

### Étendre un disque

```bash
cd ansible-resizedisk
ansible-playbook playbooks/resize_disk.yml \
  -e vm_name=APP01 \
  -e disk_new_size_gb=200 \
  -e guest_os=linux \
  -e linux_target=/data
```

Le playbook étend uniquement. Il ne réduit ni le disque virtuel, ni la
partition, ni le système de fichiers.

### Gérer les snapshots/checkpoints

```bash
cd ansible-snapshot
ansible-playbook playbooks/snapshot_list.yml -e vm_name=APP01
ansible-playbook playbooks/snapshot_create.yml \
  -e vm_name=APP01 -e snapshot_name=pre-change
ansible-playbook playbooks/snapshot_remove.yml \
  -e vm_name=APP01 -e snapshot_name=pre-change
ansible-playbook playbooks/snapshot_revert.yml \
  -e vm_name=APP01 -e snapshot_name=pre-change
```

Utiliser l'identifiant plutôt que le nom lorsqu'un nom est ambigu. Un revert
écarte l'état courant ; conserver le checkpoint de sécurité par défaut.

### Mettre à niveau Windows ou Red Hat

```bash
cd ansible-inplace-upgrade
ansible-playbook playbooks/inplace_upgrade.yml \
  -e vm_name=WINSRV01 \
  -e guest_os=windows \
  -e target_major_version=2022 \
  -e windows_media_path='D:\\'
```

Pour Red Hat, Leapp et les dépôts du système source/cible doivent être prêts.
Tout inhibiteur doit être traité explicitement ; le playbook ne le contourne
pas. Le snapshot/checkpoint est conservé jusqu'à validation applicative.

## Sécurité et garde-fous

### Validation des entrées

Les noms injectés dans PowerShell sont limités à un jeu de caractères sûr.
Conserver ces assertions lors de toute évolution. Préférer les modules Ansible
avec paramètres typés aux commandes shell. Lorsqu'un shell est indispensable :

- ne jamais interpoler une valeur non validée ;
- activer `$ErrorActionPreference = 'Stop'` ou `set -o pipefail` ;
- déclarer correctement `changed_when` et `failed_when` ;
- masquer les secrets avec `no_log`.

### Préflight et idempotence

Une opération doit échouer **avant** la mutation si :

- la VM est absente ou présente sur plusieurs plateformes ;
- la capacité ou la configuration demandée est hors politique ;
- le stockage, le cluster ou la VM est dans un état incompatible ;
- le chemin de rollback attendu n'est pas disponible ;
- une confirmation destructive manque.

Certaines opérations sont naturellement non idempotentes (création d'un
snapshot nommé avec timestamp, upgrade d'OS, suppression). Leur préflight et
leur résumé doivent permettre de distinguer clairement un succès, un refus et
un état partiellement modifié.

### Snapshots et sauvegardes

Un snapshot/checkpoint :

- reste dépendant du stockage et de la VM source ;
- peut dégrader les performances s'il est conservé trop longtemps ;
- ne remplace jamais une sauvegarde isolée et testée ;
- doit être supprimé ou consolidé après la période de validation selon une
  procédure séparée et auditée.

### Concurrence

Les locks évitent surtout deux exécutions simultanées du **même projet**. AAP
ou ServiceNow doit aussi sérialiser les changements incompatibles entre
projets, par exemple : resize disque pendant un revert, suppression pendant un
upgrade, ou power-cycle compute pendant une sauvegarde.

## Tests et analyse statique

Depuis chaque répertoire modifié :

```bash
# Syntaxe et bonnes pratiques Ansible
ansible-lint .

# Style YAML
yamllint .

# Vérification du playbook sans exécution
ansible-playbook --syntax-check playbooks/<playbook>.yml

# Affichage de l'inventaire résolu
ansible-inventory --graph
```

Les scripts embarqués dans les tâches YAML peuvent être extraits vers
`.extracted/` avec `scripts/extract_embedded_scripts.py`, puis analysés :

```bash
python3 scripts/extract_embedded_scripts.py powershell
pwsh -NoProfile -Command \
  "Invoke-ScriptAnalyzer -Path .extracted/powershell -Recurse -Settings ./scripts/PSScriptAnalyzerSettings.psd1"
```

Pour les projets qui extraient aussi du shell Linux, utiliser le mode indiqué
par leur README/script puis exécuter ShellCheck. Ne pas versionner
`.extracted/`, les inventaires réels, les mots de passe Vault ni les fichiers
`*.retry`.

Les tests de bout en bout doivent être réalisés sur des VM jetables couvrant :

- VMware et Hyper-V/SCVMM ;
- Windows et Linux lorsque le projet touche l'invité ;
- succès nominal, entrée invalide et préflight bloquant ;
- perte de connectivité et timeout ;
- redémarrage/power-cycle ;
- relance après échec et libération du lock ;
- lecture de l'artefact `set_stats` depuis AAP.

## Dépannage

### VM introuvable ou ambiguë

- confirmer que `vm_name` est exactement celui de vCenter/Hyper-V ;
- vérifier que tous les nœuds Hyper-V sont dans `hyperv_hypervisor` ;
- tester les credentials et la connectivité ;
- passer `hypervisor_type=vmware` ou `hypervisor_type=hyperv` seulement si la
  CMDB fournit une plateforme fiable.

### Échec WinRM

- vérifier ports, DNS, certificat, transport et délégation Kerberos ;
- confirmer que l'Execution Environment AAP atteint l'hôte ;
- distinguer credentials hyperviseur et credentials invité ;
- après un reboot long, ajuster le timeout documenté par le projet.

### Échec SSH/Python

- confirmer la clé, le compte, `become` et le mot de passe sudo ;
- définir `linux_python_interpreter` sur un Python 3 compatible ;
- vérifier que les paquets requis pour le système de fichiers ou Leapp sont
  disponibles dans les dépôts configurés.

### Échec VMware

- contrôler les droits du compte de service sur la VM, le datastore et les
  snapshots ;
- valider le datacenter et le certificat ;
- vérifier VMware Tools pour les opérations quiescées ou invitées.

### Lock résiduel

Ne supprimer un lock qu'après avoir vérifié dans AAP, ServiceNow et sur la
plateforme qu'aucun job n'est encore actif. Documenter cette intervention dans
le ticket de changement. Une suppression prématurée peut autoriser deux
mutations concurrentes.

## Contribution

Pour ajouter ou modifier une automatisation :

1. conserver la séparation préflight/action/validation ;
2. documenter toutes les extra-vars, valeurs par défaut et opérations
   irréversibles dans le README du projet ;
3. ajouter ou mettre à jour `requirements.yml` avec des bornes de versions ;
4. ne jamais committer d'inventaire réel ou de secret ;
5. publier un résumé stable via `set_stats` pour les consommateurs AAP ;
6. exécuter les linters, syntax-checks et scénarios de préflight ;
7. mettre à jour ce catalogue lorsqu'un projet ou un playbook est ajouté.
