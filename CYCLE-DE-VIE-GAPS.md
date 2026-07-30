# Analyse d'écart — cycle de vie matériel / OS / hyperviseurs

Ce document complète [`ANSIBLE.md`](ANSIBLE.md). Il ne décrit pas ce que le
dépôt fait (c'est le rôle du catalogue), mais **ce qu'il ne fait pas encore**
sur les trois axes du cycle de vie d'une infrastructure : le matériel, les
hyperviseurs et les systèmes d'exploitation. Il propose aussi les **options à
prévoir** dans les automatisations déjà en place.

L'analyse porte sur l'état du dépôt à la date de rédaction : 15 projets
Ansible, 2 scripts PowerShell de reporting Pure Storage, 6 workflows CI.

> **Mise à jour** : 8 projets ont été ajoutés depuis la rédaction initiale
> (23 projets au total) : `vmware-esxi-conf`, `vmware-vcenter-conf`,
> `vmware-vcenter-addvlan`/`-removevlan`, `windows-hyperv-conf`,
> `windows-scvmm-conf`, `windows-scvmm-addvlan`/`-removevlan`. Ils referment
> **partiellement** l'écart 3.1 (config Day-1 d'hôte ESXi), l'écart 3.5
> (config des appliances de management vCenter/SCVMM) et l'écart 1.2
> (opération réseau sur la VM, via l'attachement optionnel de vNIC des
> projets `-addvlan`/`-removevlan`). Un passage syslog/SMTP/SNMP a aussi
> ajouté de l'alerting optionnel à `purestorage-conf`, `synergy-conf`,
> `hpe-storeonce-conf`, `quantum-dxi-conf`, `vmware-esxi-conf`,
> `vmware-vcenter-conf`, `windows-hyperv-conf` et `windows-scvmm-conf`
> (SNMPv3 là où le module/l'appliance le permet ; v1/v2c uniquement pour
> ESXi, vCenter et l'agent SNMP Windows - aucune de ces plateformes n'a de
> SNMPv3 disponible ; aucun mécanisme SMTP/syslog OS natif n'existe côté
> Windows). Le détail des sections concernées a été annoté ci-dessous;
> le reste de l'analyse (mobilité, clusters, firmware, patch OS, etc.)
> reste valide tel quel.
>
> **Deuxième mise à jour** : `vmware-vcenter-conf` couvre désormais la
> planification de sauvegarde native de l'appliance (`vcsa_backup_schedule`
> - fermeture du dernier point de l'écart 3.5). Deux nouveaux projets ont
> aussi été ajoutés (25 au total) : `ansible-veeam-conf` et
> `ansible-netbackup-conf`, qui referment **partiellement** l'écart 4.15
> (intégration au logiciel de sauvegarde) au niveau notification/alerting
> du serveur de sauvegarde uniquement - la création de jobs/policies, la
> restauration et le préflight « sauvegarde valide » (écart 4.16) restent
> absents et sont, de loin, la partie la plus utile de cet écart.

- [Méthode et légende](#méthode-et-légende)
- [Vue d'ensemble de la couverture](#vue-densemble-de-la-couverture)
- [Axe 1 — Cycle de vie de la VM](#axe-1--cycle-de-vie-de-la-vm)
- [Axe 2 — Cycle de vie de l'OS invité](#axe-2--cycle-de-vie-de-los-invité)
- [Axe 3 — Cycle de vie de l'hyperviseur](#axe-3--cycle-de-vie-de-lhyperviseur)
- [Axe 4 — Cycle de vie du matériel](#axe-4--cycle-de-vie-du-matériel)
- [Axe 5 — Écarts transverses](#axe-5--écarts-transverses)
- [Options à prévoir dans les projets existants](#options-à-prévoir-dans-les-projets-existants)
- [Backlog priorisé](#backlog-priorisé)
- [Points d'attention à trancher](#points-dattention-à-trancher)

## Méthode et légende

Chaque phase du cycle de vie est classée :

| Symbole | Signification |
|---|---|
| ✅ | Couvert par un projet du dépôt |
| 🟡 | Partiellement couvert : le projet existe mais une plateforme, un mode ou une étape manque |
| ❌ | Absent du dépôt |
| ⚪ | Volontairement hors périmètre (à confirmer) |

Les écarts qualifiés de **structurants** changent la nature du service rendu
(une phase entière du cycle de vie n'est pas automatisable). Les écarts
**incrémentaux** sont des options à ajouter dans un projet existant.

## Vue d'ensemble de la couverture

| Phase | VM | OS invité | Hyperviseur (hôte) | Matériel |
|---|:--:|:--:|:--:|:--:|
| Provisionnement / build | ✅ `createvm` | 🟡 personnalisation seule | ❌ | 🟡 `synergy-*` (VLAN, lecture) |
| Configuration Day-1 | 🟡 | 🟡 | 🟡 `esxi-conf`, `vcenter-conf`, `hyperv-conf`, `scvmm-conf` (identité, temps, alerting) | ✅ `synergy-conf`, `purestorage-conf`, `dxi-conf`, `storeonce-conf` |
| Exploitation Day-2 | ✅ `resizecompute`, `resizedisk`, `snapshot` | 🟡 | ❌ | 🟡 `purestorage-volhost-*`, `synergy-vlan-*` |
| Mise à jour / patch | 🟡 `inplace-upgrade` (majeur) | ❌ patch courant | ❌ | ❌ firmware |
| Conformité / audit | ❌ | ❌ | ❌ | 🟡 `synergy-get`, scripts Pure |
| Décommissionnement | ✅ `deletevm` | ⚪ | ❌ | 🟡 `purestorage-volhost-remove`, `synergy-vlan-remove` |

Lecture rapide : le dépôt est **très mature sur le Day-2 de la VM** et sur la
**configuration initiale des appliances**. La configuration Day-1 de
l'hyperviseur (identité, temps, alerting) est désormais **partiellement**
couverte (`esxi-conf`/`vcenter-conf`/`hyperv-conf`/`scvmm-conf`), mais le
dépôt reste **absent sur l'exploitation Day-2 de l'hôte (mobilité, cluster,
mode maintenance), le firmware et le patch courant** - voir l'axe 3 pour le
détail de ce qui est couvert vs manquant.

---

## Axe 1 — Cycle de vie de la VM

### Ce qui est déjà solide

`createvm`, `deletevm`, `resizecompute`, `resizedisk`, `snapshot` couvrent
create / resize / snapshot / decommission avec un modèle homogène :
préflight bloquant, verrou, rôles séparés par plateforme, artefact
`set_stats`. La qualité des préflights (jusqu'à 574 lignes dans
`ansible-resizedisk/roles/preflight_disk_constraints/tasks/main.yml`) est
au-dessus de la moyenne du marché.

### Écarts structurants

| # | Écart | Détail | Impact |
|---|---|---|---|
| 1.1 | **Aucune opération de mobilité** | Pas de vMotion / Storage vMotion / Live Migration / Quick Migration. Impossible d'évacuer une VM par automatisation. | Bloque toute automatisation de maintenance d'hôte (voir axe 3) |
| 1.2 | 🟡 **Opération réseau sur la VM** — partiellement couvert | `vmware-vcenter-addvlan`/`-removevlan` et `windows-scvmm-addvlan`/`-removevlan` attachent/détachent désormais la carte réseau d'une VM à un nouveau portgroup/VM Network (`vmware_guest_network`, `Set-SCVirtualNetworkAdapter`), en plus de créer/retirer le VLAN réseau lui-même. `synergy-vlan-*` (OneView) continue en revanche à n'agir que sur le fabric, pas sur la VM. | Le cas d'usage « changer la VM de VLAN » est couvert pour VMware/SCVMM ; reste manuel pour tout ce qui passe par OneView/Virtual Connect |
| 1.3 | **Aucune gestion des disques secondaires** | `resizedisk` étend un disque existant ; rien pour **ajouter** ou **retirer** un disque virtuel, ni pour un RDM / pass-through. | Cas d'usage très fréquent non couvert |
| 1.4 | **Pas de playbook power state autonome** | `start` / `stop` / `restart` / `reset` n'existent que comme effet de bord de `deletevm` et `resizecompute`. | Pas d'action simple exposable au support N1 |
| 1.5 | **Pas de clonage / conversion / export** | Pas de clone de VM existante, pas de template capture, pas d'export OVF, pas de V2V. | Le cycle « VM → template doré » reste manuel |

### Écarts incrémentaux

- **`createvm` — pas de chemin Hyper-V natif** : SCVMM est une dépendance
  dure (documenté et assumé dans `ansible-createvm/README.md`). À confirmer
  comme choix définitif ou à couvrir via `New-VM` + un mécanisme de
  personnalisation (unattend.xml injecté, cloud-init via ISO).
- **`createvm` — `disk_gb` non supporté sur SCVMM** : écart déjà documenté.
- **`createvm` — une seule carte réseau, un seul disque** : pas de VM
  multi-NIC ni multi-disque à la création.
- **`createvm` — pas d'IP statique hors VMware**, pas de cloud-init sur le
  chemin SCVMM (clé SSH seulement).
- **`createvm` — pas de métadonnées de placement** : dossier vCenter, tags /
  catégories, annotation, custom attributes, règles DRS d'affinité /
  anti-affinité, réservations et limites CPU/RAM, `latencySensitivity`.
- **`createvm` — pas d'options de sécurité de la VM** : vTPM, Secure Boot,
  EFI vs BIOS, chiffrement de VM, vbs. Aujourd'hui hérité du template
  uniquement.
- **`deletevm` — pas de nettoyage périphérique** : l'enregistrement DNS,
  l'objet Active Directory, le job de sauvegarde, la supervision, la licence
  et l'adresse IPAM ne sont pas retirés. Le nettoyage du stockage baie existe
  (`purestorage-volhost-remove`) mais n'est pas chaîné.
- **`snapshot` — pas de politique de rétention** : rien pour lister/purger
  les snapshots plus vieux que N jours sur l'ensemble du parc, alors que
  `ANSIBLE.md` identifie explicitement ce risque.
- **`snapshot` — pas de consolidation** (`vmware_guest_snapshot` avec
  consolidate / `Merge-VMSnapshot`), pas de détection de disques orphelins.

---

## Axe 2 — Cycle de vie de l'OS invité

### Écarts structurants

| # | Écart | Détail |
|---|---|---|
| 2.1 | **Aucun patch management** | `inplace-upgrade` traite le saut de version **majeure** (2019→2022, RHEL 8→9). Le patch mensuel courant — Windows Update / WSUS, `dnf update`, redémarrage contrôlé, fenêtre de maintenance, reporting de conformité — n'est nulle part. C'est l'opération OS la plus fréquente de tout parc. |
| 2.2 | **Aucun durcissement / baseline** | Pas de configuration post-création : CIS/ANSSI, politiques locales, pare-feu, services désactivés, bannière, audit. |
| 2.3 | **Aucun déploiement d'agent** | Pas de jonction de domaine autonome, pas d'agent de sauvegarde, antivirus/EDR, supervision, collecteur de logs, VMware Tools / Integration Services. |
| 2.4 | **Aucune gestion de certificats** | Pas d'enrôlement, de renouvellement ni de déploiement de certificat machine. |
| 2.5 | **Aucun contrôle de conformité / dérive** | Pas de playbook lecture seule qui compare l'état d'un invité à un référentiel et publie un écart. |

### Écarts incrémentaux

- **`inplace-upgrade` — couverture OS étroite** : Windows Server et RHEL
  uniquement. Ni SUSE (`zypper dup`), ni Ubuntu (`do-release-upgrade`), ni
  Debian, ni Rocky/Alma (Leapp communautaire), ni Oracle Linux.
- **`inplace-upgrade` — pas de rollback automatisé** : le snapshot est créé
  et **volontairement conservé**, mais la restauration reste manuelle
  (`ansible-snapshot` existe mais n'est pas chaîné en cas d'échec).
- **`inplace-upgrade` — pas de purge différée du snapshot** : documenté comme
  « étape séparée du workflow ServiceNow », donc non automatisée.
- **`inplace-upgrade` — pas de pré-check applicatif** : arrêt/redémarrage
  ordonné des services, vérification post-upgrade fonctionnelle.
- **`resizedisk` — pas de réduction, pas de nouveau volume/point de montage**
  (extension seule, choix assumé), pas de gestion multipath côté invité.
- **Pas de gestion des utilisateurs/comptes locaux invités**, alors que c'est
  couvert pour toutes les appliances (`local_accounts`, `local_admin`,
  `configure_local_user`). Asymétrie notable.

---

## Axe 3 — Cycle de vie de l'hyperviseur

**C'était l'axe le plus vide du dépôt** ; il reste le moins mature. La
configuration Day-1 *identité/temps/alerting* de l'hôte ESXi natif et des
appliances de management (vCenter, SCVMM) est désormais couverte par
`vmware-esxi-conf`/`vmware-vcenter-conf`/`windows-hyperv-conf`/
`windows-scvmm-conf`. Tout le reste de l'axe (réseau/stockage d'hôte,
cluster, mode maintenance, mise à jour d'hyperviseur, build, décommission,
inventaire de conformité) reste absent.

### Écarts structurants

| # | Écart | Détail |
|---|---|---|
| 3.1 | 🟡 **Configuration d'hôte ESXi — partiellement couvert** | `vmware-esxi-conf` couvre désormais NTP, syslog distant, jonction AD (optionnelle), utilisateur local et SNMP (v1/v2c). Restent absents : DNS, services SSH/shell, mode de verrouillage (lockdown), règles de pare-feu, politique d'alarme, `advanced settings`, profil d'énergie. |
| 3.2 | **Pas de configuration réseau/stockage d'hôte** | vSwitch / dvSwitch, port groups, vmkernel, teaming, MTU/jumbo frames, iSCSI/NVMe-oF initiator, rescan HBA, datastore mount/unmount, multipath (PSP/SATP) — alors que `purestorage-volhost-create` provisionne justement le LUN en amont. **La chaîne s'arrête à la baie.** |
| 3.3 | **Pas de cycle de vie de cluster** | Ajout/retrait d'un hôte d'un cluster, mode maintenance (entrée/sortie, évacuation), EVC, HA/DRS, cluster Hyper-V (drain de nœud, CSV, quorum). |
| 3.4 | **Pas de mise à jour d'hyperviseur** | Upgrade ESXi (baselines vLCM, images de cluster, remédiation), patch des nœuds Hyper-V (Cluster-Aware Updating), rolling upgrade de cluster. |
| 3.5 | 🟡 **Configuration des appliances de management — partiellement couvert** | `vmware-vcenter-conf` (NTP, timezone, rotation du mot de passe admin local via VAMI, syslog, journalisation/SMTP/SNMP v1-v2c via `vmware_vcenter_settings`, et désormais la planification de sauvegarde native de l'appliance via `vmware.vmware.vcsa_backup_schedule`) et `windows-scvmm-conf` (jonction AD, compte local, NTP, timezone, SNMP v1/v2c OS) couvrent l'identité/temps/alerting/sauvegarde de base. Restent absents : intégration AD/SSO de vCenter, rôles et permissions, certificats. |
| 3.6 | **Pas de build d'hyperviseur** | Installation ESXi (kickstart/Auto Deploy/host profile) ou d'un nœud Hyper-V à partir d'une lame nue. C'est le chaînon manquant entre `synergy-*` (matériel) et le reste du dépôt. |
| 3.7 | **Pas de décommissionnement d'hôte** | Évacuation, retrait du cluster, désenregistrement vCenter/SCVMM, démasquage des LUN, retrait du zoning. |
| 3.8 | **Pas d'inventaire / conformité d'hyperviseur** | Aucun équivalent de `synergy-get` pour ESXi : version/build, patch level, uptime, HBA/WWN, datastores, VM par hôte, capacité et sur-souscription. |

### Conséquence de chaîne

Sans 1.1 (mobilité) ni 3.3 (mode maintenance), **aucune opération de
maintenance planifiée d'hôte n'est automatisable de bout en bout**, ce qui
neutralise l'intérêt de 3.4 et 4.2 (firmware) même s'ils étaient développés.
Ces trois éléments forment un lot indissociable.

---

## Axe 4 — Cycle de vie du matériel

### Compute — HPE Synergy / OneView

Couvert : NTP/timezone/AD/compte local de l'appliance (`synergy-conf`),
ajout/retrait de VLAN sur Ethernet Network + Network Set + Server Profile
(`synergy-vlan-add` / `-remove`), inventaire lecture seule d'une lame
(`synergy-get`).

Écarts :

| # | Écart | Détail |
|---|---|---|
| 4.1 | **Pas de cycle de vie du Server Profile** | Création depuis un Server Profile Template, affectation à une baie, migration de profil vers une autre lame (le cas d'usage phare de Synergy en cas de panne matérielle), déaffectation, suppression. |
| 4.2 | **Pas de gestion de firmware** | Pas de baseline SPP, pas de comparaison de conformité, pas de mise à jour (profil ou enceinte), pas de « firmware drift report ». |
| 4.3 | **Pas de configuration d'enceinte / fabric** | Enclosure Group, Logical Interconnect Group, uplink sets, SAN Manager, Logical Enclosure, mise à jour d'interconnect. `synergy-vlan-*` touche le Network Set mais pas la définition du fabric. |
| 4.4 | **Pas de contrôle d'alimentation ni de santé matérielle** | Power on/off/reset d'une lame, LED d'identification, lecture des alertes/health status, seuils, remontée vers la supervision. |
| 4.5 | **Pas d'accès iLO / Redfish direct** | Aucun rôle `redfish_*` : comptes iLO, licence, boot order, console, `Get-HPEiLO*`. Utile pour le rack (DL/ProLiant) hors périmètre OneView. |
| 4.6 | **Rien pour le rack et les autres constructeurs** | Dell iDRAC/OME, Cisco UCS, Lenovo XClarity : non couverts. À confirmer comme hors périmètre du parc. |
| 4.7 | **Pas de mise à jour de l'appliance OneView elle-même** | Upgrade, sauvegarde/restauration de configuration, certificats. |

### Stockage — Pure Storage FlashArray

Couvert : AD/NTP/syslog/timezone/rotation `pureuser` (`purestorage-conf`),
volumes + hosts + hostgroups + connexions (`purestorage-volhost-create`),
suppression ordonnée avec double confirmation (`purestorage-volhost-remove`),
plus deux scripts PowerShell de reporting (performance, volumes physiques).

Écarts :

| # | Écart | Détail |
|---|---|---|
| 4.8 | **Pas de protection des données** | Protection Groups, politiques de snapshot et de rétention, réplication asynchrone, ActiveCluster / pods, offload SafeMode. C'est l'écart le plus important du volet stockage. |
| 4.9 | **Pas de redimensionnement ni de suppression fine de volume** | Le rôle `volumes` fait `create or grow` ; pas de shrink, pas de renommage, pas de restauration depuis un volume détruit (fenêtre d'éradication), pas de QoS (bande passante / IOPS limits). |
| 4.10 | **Pas de zoning SAN** | Le playbook crée les hosts avec leurs WWN mais **le zoning Brocade/Cisco MDS reste manuel**. Le provisionnement stockage n'est donc pas de bout en bout. |
| 4.11 | **Pas de suivi de capacité comme code** | Les scripts PowerShell produisent des CSV hors chaîne Ansible/AAP ; pas de seuil, pas d'alerte, pas d'artefact `set_stats`. |
| 4.12 | 🟡 **Cycle de vie de la baie — partiellement couvert** | `purestorage-conf` couvre désormais le relais SMTP/destinataires d'alerte (`purefa_smtp`/`purefa_alert`) et le SNMP manager+agent (SNMPv3 ou v2c, `purefa_snmp`/`purefa_snmp_agent`) en option. Restent absents : mise à jour Purity, certificats, support/Pure1, mise en service et décommissionnement d'une baie. |
| 4.13 | **Mono-fournisseur, mono-baie** | Une seule `pure_fa_url` par exécution. Pas d'orchestration multi-baies, pas de FlashBlade, ni d'autre constructeur (NetApp, Alletra, PowerStore). |

### Sauvegarde — Quantum DXi / HPE StoreOnce

Couvert : comptes locaux, AD, NTP, timezone — et uniquement cela. Les chemins
REST restent **délibérément non devinés** dans le code, mais ils sont
maintenant organisés par branche logicielle et sélectionnés depuis une
variable de release, au lieu d'une liste plate à remplir par appliance.

Écarts :

| # | Écart | Détail |
|---|---|---|
| 4.14 | **Pas de configuration fonctionnelle** | Aucun partage NAS/CIFS/NFS, aucun Catalyst Store, aucune VTL, aucune politique de rétention, aucune réplication ni air gap. Les appliances sont configurées « identité et temps » uniquement — elles ne sont pas rendues exploitables. |
| 4.15 | 🟡 **Intégration au logiciel de sauvegarde — partiellement couvert** | `ansible-veeam-conf` et `ansible-netbackup-conf` configurent désormais les réglages de notification (SMTP/SNMP) des serveurs Veeam Backup & Replication et NetBackup, sur le même modèle que les autres projets `*-conf` (identité/alerting d'un équipement). **Restent absents, et c'est le plus gros du sujet** : création/gestion de job ou de policy de sauvegarde, storage lifecycle policies, repositories, restauration, et vérification qu'une sauvegarde valide existe (voir 4.16, qui n'est pas non plus couvert par ces deux projets). Commvault reste totalement absent. |
| 4.16 | **Pas de chaînage sauvegarde ↔ cycle de vie VM** | `deletevm` et `inplace-upgrade` ne vérifient pas qu'une sauvegarde valide existe, alors que `ANSIBLE.md` insiste sur le fait qu'un snapshot n'est pas une sauvegarde. Le préflight le plus utile du dépôt est celui qui manque. |
| 4.17 | 🟡 **Contrat API — mécanisme multi-version en place, chemins à renseigner** | La release de l'appliance est désormais une donnée d'entrée (`dxi_release` / `storeonce_release`), résolue par le rôle `api_contract` contre une table de contrats par branche (`*_api_contracts`) : endpoints, méthodes et capacités. Un parc multi-générations tient donc dans un seul inventaire, les capacités déclarées sont contrôlées au préflight (demander SNMPv3 sur une branche qui ne l'expose pas échoue explicitement au lieu d'être silencieusement rétrogradé), et les surcharges par appliance restent possibles. **Reste à la charge de l'exploitant** : les chemins REST eux-mêmes, qui doivent provenir du guide API de chaque release visée — ils ne sont volontairement pas devinés dans le code. Le préflight bloque en nommant la branche et le réglage manquants. |

### Réseau et services d'infrastructure

| # | Écart | Détail |
|---|---|---|
| 4.18 | **Pas de commutateur physique** | Rien hors du périmètre Virtual Connect (Cisco NX-OS, Arista, Aruba). |
| 4.19 | **Pas d'IPAM / DNS / DHCP** | Ni Infoblox, ni phpIPAM, ni DNS Microsoft. `createvm` reçoit une IP en extra-var et ne la réserve nulle part ; `deletevm` ne la libère pas. |
| 4.20 | **Pas de load balancer ni de pare-feu** | F5/NetScaler, règles de firewall : absents du cycle de vie applicatif. |

---

## Axe 5 — Écarts transverses

### Réutilisation du code

Cinq projets embarquent une copie quasi identique de `preflight_platform` et
un rôle de verrou (`create_vm_lock`, `delete_vm_lock`, `compute_lock`,
`resizedisk_lock`, `snapshot_lock`, `upgrade_lock` — ~150 lignes chacun).

> **Option à prévoir** : une collection interne
> (`entreprise.infra_lifecycle`) portant `preflight_platform`,
> `platform_lock`, `run_guest_command`, `publish_summary` et les filtres de
> validation, consommée par tous les projets via `requirements.yml`. Cela
> divise la surface de maintenance par cinq et rend cohérente toute
> évolution du verrou ou de la détection de plateforme.

### Verrouillage et concurrence

- Le verrou VMware de `createvm` est **un fichier sur le nœud de contrôle**
  (`ansible-createvm/roles/create_vm_lock/tasks/main.yml`) : dans AAP, où
  chaque job s'exécute dans un execution environment isolé, il **ne protège
  rien** — c'est explicitement documenté dans l'en-tête du rôle.
- Les verrous sont **par projet** : rien n'empêche un `resizedisk` pendant un
  `snapshot_revert`. `ANSIBLE.md` renvoie cette responsabilité au workflow
  d'entreprise.

> **Option à prévoir** : un verrou partagé, externe et atomique — table
> ServiceNow, Redis, ou une annotation vCenter unique par VM utilisée par
> tous les projets — avec un namespace commun `vm:<name>` au lieu d'un
> namespace par projet.

### Sécurité

- `vmware_validate_certs`/`esxi_conf_validate_certs`/`vcenter_vami_validate_certs`
  restent à `false` par défaut dans les **10 projets** touchant vCenter/ESXi
  (les 6 d'origine, plus `vmware-esxi-conf`, `vmware-vcenter-conf`,
  `vmware-vcenter-addvlan`/`-removevlan`), alors que les projets appliance
  récents (`dxi`, `storeonce`) et les nouveaux projets Windows
  (`hyperv-conf`, `scvmm-conf`) sont à `true`. Aligner sur `true` par défaut
  et documenter le déploiement de la chaîne interne dans l'EE.
- Pas de politique de rotation des secrets Vault, pas de `CODEOWNERS`, pas de
  scan de secrets en CI, pas de matrice RBAC/approbations versionnée.

### Tests et CI

- ~~6 workflows pour 25 projets~~ **fait** : les 20 projets qui n'avaient
  aucun workflow dédié (`inplace-upgrade`, `purestorage-conf`,
  `purestorage-volhost-create`, `purestorage-volhost-remove`,
  `synergy-conf`, `synergy-get`, `synergy-vlan-add`, `synergy-vlan-remove`,
  `quantum-dxi-conf`, `hpe-storeonce-conf`, `vmware-esxi-conf`,
  `vmware-vcenter-conf`, `vmware-vcenter-addvlan`, `vmware-vcenter-removevlan`,
  `windows-hyperv-conf`, `windows-scvmm-conf`, `windows-scvmm-addvlan`,
  `windows-scvmm-removevlan`, `ansible-veeam-conf`, `ansible-netbackup-conf`)
  ont désormais chacun leur workflow `yamllint`/`ansible-lint`/
  `ansible-playbook --syntax-check`, sur le même modèle que les 5
  workflows d'origine - 26 workflows au total (25 projets +
  `powershell-quality.yml`, transverse). `ansible-inplace-upgrade` a aussi
  été ajouté au scan PSScriptAnalyzer de `powershell-quality.yml`, qui ne
  le couvrait pas alors que son propre script d'extraction existait déjà.
  Deux lignes dépassant les 200 caractères de la limite `yamllint` du
  projet (dans `preflight_platform`/`preflight_upgrade_constraints`) ont
  été repliées en blocs YAML `>-` pliés - vérifié que la valeur Jinja
  rendue reste strictement identique avant/après.
- Pas de Molecule, pas de test d'idempotence, pas de test de préflight en
  `--check`, pas de simulateur (vcsim) : les scénarios listés dans
  `ANSIBLE.md` (« VM jetables ») restent entièrement manuels.
- Pas de gestion de version des collections dans le temps (Dependabot /
  Renovate sur `requirements.yml`), pas de tags de release, pas de
  `CHANGELOG.md`.
- Pas de définition d'Execution Environment (`execution-environment.yml`) :
  chaque environnement AAP doit reconstruire l'image à la main à partir des
  `requirements.yml`.

### Observabilité et intégration

- `set_stats` est bien utilisé, mais il n'y a **aucune écriture retour vers
  la CMDB** : ni mise à jour du CI après un resize, ni retrait après une
  suppression, ni enregistrement de l'IP obtenue à la création.
- Aucune métrique ni trace : durée d'opération, taux d'échec par préflight,
  volume de refus — utile pour piloter le service.
- Aucun mode « rapport » global : pas de playbook lecture seule qui produit
  l'état consolidé d'un environnement (VM, hôtes, baies, lames).

---

## Options à prévoir dans les projets existants

Écarts incrémentaux, réalisables sans nouveau projet.

| Projet | Option à prévoir | Effort |
|---|---|:--:|
| `createvm` | Multi-NIC, disques additionnels, dossier/tags/annotation vCenter | M |
| `createvm` | vTPM / Secure Boot / EFI, réservations CPU-RAM, règles DRS | M |
| `createvm` | `disk_gb` sur SCVMM, IP statique et cloud-init sur SCVMM | M |
| `createvm` | Enregistrement DNS/IPAM et écriture CMDB en fin de run | S |
| `deletevm` | Nettoyage DNS / AD / IPAM / job de sauvegarde / supervision | M |
| `deletevm` | Préflight « une sauvegarde valide existe » avant suppression | S |
| `resizecompute` | Ajout/retrait de vNIC, changement de port group | M |
| `resizedisk` | Ajout d'un nouveau disque et d'un nouveau point de montage | M |
| `snapshot` | Playbook de purge par rétention (parc entier) + consolidation | S |
| `inplace-upgrade` | Rollback automatisé sur échec (chaînage `snapshot_revert`) | M |
| `inplace-upgrade` | SUSE, Ubuntu, Rocky/Alma ; purge différée du snapshot | M |
| `purestorage-conf` | Certificats, seuils de capacité (SNMP/alerting fait) | S |
| `purestorage-volhost-create` | QoS, protection groups, shrink/rename de volume | M |
| `synergy-conf` | Sauvegarde de configuration de l'appliance avant changement | S |
| `synergy-get` | Étendre à l'enceinte et au fabric, publier la conformité firmware | S |
| `dxi-conf` / `storeonce-conf` | Profils d'endpoints validés par version de firmware | M |
| `esxi-conf` | DNS, mode de verrouillage, pare-feu, `advanced settings` | M |
| `vcenter-conf` | AD/SSO, rôles et permissions, certificats (sauvegarde de l'appliance faite) | M |
| `scvmm-conf` | Rôles et permissions SCVMM, certificats | M |
| `veeam-conf` / `netbackup-conf` | Jobs/policies de sauvegarde, repositories, restauration | L |
| Tous | CI (yamllint + ansible-lint + syntax-check) sur les projets non couverts | S |
| Tous | `vmware_validate_certs: true` par défaut | S |
| Tous | Collection interne de rôles communs (préflight, verrou, résumé) | L |

---

## Backlog priorisé

Priorisation par **risque évité × fréquence d'usage**, pas par difficulté.

### P0 — À traiter en premier

1. ~~CI sur les 20 projets non couverts~~ **fait** (S). Les 20 projets
   matériel, hyperviseur et logiciel de sauvegarde ont désormais un
   garde-fou automatisé (yamllint/ansible-lint/syntax-check).
2. **Préflight « sauvegarde valide » avant `deletevm` et `inplace-upgrade`**
   (S→M, écart 4.16). Le plus grand risque résiduel du dépôt.
3. **Verrou partagé inter-projets et valide sous AAP** (M, axe 5). Le verrou
   `createvm` VMware ne protège rien dans la cible d'exécution réelle.
4. **`vmware_validate_certs: true` par défaut** (S).

### P1 — Fort retour sur investissement

5. **Patch management OS** (L, écart 2.1). L'opération la plus fréquente du
   parc, entièrement absente.
6. **Lot « maintenance d'hôte » : mode maintenance + mobilité + drain de
   cluster** (L, écarts 1.1 / 3.3). Prérequis de tout le reste de l'axe 3.
7. **Purge des snapshots par rétention** (S, écart 1.5 du volet snapshot).
   Risque de performance et de remplissage de datastore déjà identifié dans
   `ANSIBLE.md`.
8. **Collection interne de rôles communs** (L, axe 5). À faire avant que le
   nombre de projets n'augmente encore.

### P2 — Complétude de la chaîne

9. **Compléter la configuration d'hôte ESXi/vCenter/SCVMM** (DNS, lockdown
   mode, pare-feu, rôles/permissions, certificats — M, écarts 3.1/3.5,
   identité/temps/alerting déjà couverts) et **inventaire/conformité
   d'hôte** (M, écart 3.8, toujours absent).
10. **Protection Groups et réplication Pure** (M, écart 4.8).
11. **Cycle de vie du Server Profile OneView** (M, écart 4.1), y compris la
    migration de profil en cas de panne de lame.
12. **Zoning SAN** (M, écart 4.10), pour un provisionnement stockage de bout
    en bout.
13. **Options `createvm`** : multi-NIC, disques additionnels, tags, vTPM (M).

### P3 — À arbitrer

14. Firmware / SPP (écart 4.2), upgrade ESXi et vLCM (3.4), build
    d'hyperviseur (3.6).
15. Configuration fonctionnelle des appliances de sauvegarde (4.14) et
    intégration au logiciel de sauvegarde (4.15).
16. IPAM/DNS (4.19), commutateurs physiques (4.18), autres constructeurs
    (4.6, 4.13).

---

## Points d'attention à trancher

Ces questions conditionnent le périmètre et méritent une décision explicite
avant tout développement.

1. **Le dépôt doit-il couvrir l'hôte hyperviseur ?** La réponse est
   désormais partiellement « oui » : l'identité/temps/alerting Day-1 de
   l'hôte ESXi natif et des appliances de management (vCenter, SCVMM) est
   couverte. Reste à trancher si le dépôt doit aussi couvrir l'exploitation
   Day-2 (mobilité, cluster, mode maintenance, mise à jour, build,
   décommission) ou si ce périmètre est délibérément laissé à une autre
   équipe/un autre outil — à documenter explicitement dans `ANSIBLE.md`
   dans un cas comme dans l'autre. Si oui, c'est toujours le plus gros
   chantier du dépôt.
2. **Patch OS : Ansible ou outil dédié ?** Si un WSUS/Satellite/Ivanti
   existe, le rôle d'Ansible se limite à l'orchestration de la fenêtre et du
   redémarrage — ce qui reste à écrire, et reste beaucoup plus simple.
3. **Les projets DXi, StoreOnce, Veeam et NetBackup sont-ils destinés à
   être exécutés ?** En l'état, ils bloquent au préflight tant que les
   endpoints ne sont pas renseignés (et, pour Veeam/NetBackup, tant que
   l'en-tête de version/média type n'est pas confirmé contre la version
   cible). Soit on livre des profils validés par version, soit on assume
   qu'il s'agit de canevas.
4. **Multi-vCenter / multi-baie** : le modèle actuel suppose un vCenter et
   une baie par exécution. Si le parc est multi-site, cela impose un
   inventaire par environnement et non des `group_vars/all.yml` globaux.
5. **Écriture retour CMDB** : responsabilité d'Ansible ou du workflow
   ServiceNow ? Le dépôt fait aujourd'hui le second choix implicitement, sans
   le dire.
6. **Périmètre constructeur** : Dell / Cisco / NetApp sont-ils absents du
   parc, ou simplement pas encore automatisés ?
