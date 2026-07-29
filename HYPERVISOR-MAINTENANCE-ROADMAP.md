# Roadmap d'automatisation — maintenance et mise à jour des hyperviseurs

Ce document complète [`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md) et les
projets existants `vmware-vcenter-conf`, `vmware-esxi-conf`,
`windows-scvmm-conf` et `windows-hyperv-conf`.

Le périmètre couvre :

- entrée et sortie de maintenance d'un hôte ESXi via vCenter ;
- entrée et sortie de maintenance d'un nœud Hyper-V via SCVMM ;
- patch/minor update de la vCenter Server Appliance ;
- mise à jour des hôtes ESXi via vSphere Lifecycle Manager ;
- mise à jour des nœuds Hyper-V via SCVMM et son serveur WSUS intégré.

Les projets sont autonomes, mais peuvent être chaînés dans des workflows AAP.

## Principes

- aucune maintenance d'hôte directement contre ESXi lorsque vCenter le gère ;
- aucune maintenance Hyper-V en contournant SCVMM lorsque le nœud y est géré ;
- séparation stricte entre `enter`, `update` et `exit` ;
- évacuation des workloads avant tout reboot, sauf technologie de live patch
  explicitement validée ;
- verrou partagé par hôte et par cluster ;
- un seul nœud remédié à la fois par défaut ;
- Centreon downtime, sauvegarde et ticket de changement sont orchestrés par un
  workflow, sans dépendance directe entre projets ;
- découverte des versions et matrices de compatibilité avant toute mutation ;
- firmware, drivers et add-ons restent visibles dans les plans vLCM ;
- aucune mise à jour téléchargée depuis Internet sans source approuvée ;
- rollback documenté avant exécution, sans prétendre qu'un downgrade hyperviseur
  est toujours possible ;
- artefact `set_stats` stable pour AAP/ServiceNow.

## Maintenance VMware via vCenter

### `ansible-vmware-host-maintenance-enter`

Entrée contrôlée d'un hôte ESXi en maintenance via vCenter :

- résolution exacte du datacenter, cluster et host ;
- validation de la connexion vCenter, des certificats et des privilèges ;
- inventaire des VM actives, arrêtées, templates, appliances et tâches en cours ;
- contrôle de DRS, HA, admission control et capacité résiduelle du cluster ;
- détection des VM non migrables : passthrough, périphériques locaux, ISO local,
  affinités bloquantes, FT, vGPU ou contraintes de licence ;
- validation de vMotion, réseaux VMkernel, stockage partagé et compatibilité CPU ;
- contrôle des jobs de sauvegarde, réplication ou restauration actifs ;
- choix explicite du traitement des VM arrêtées ;
- choix explicite du mode d'évacuation vSAN lorsque le cluster utilise vSAN ;
- évacuation par DRS/vMotion ou échec bloquant ;
- aucun arrêt de VM par défaut ;
- entrée en maintenance avec timeout borné ;
- vérification qu'aucune VM active ni opération de provisioning ne reste sur l'hôte ;
- publication des migrations réalisées et des workloads non déplacés.

Artefact AAP : `vmware_host_maintenance_enter_summary`.

### `ansible-vmware-host-maintenance-exit`

Sortie contrôlée de maintenance :

- vérification de la connectivité vCenter/hostd/vpxa ;
- contrôle du hardware health, des capteurs critiques et de l'état des HBA/NIC ;
- validation NTP, DNS, syslog et services de management ;
- contrôle des datastores, chemins multipath, réseaux VMkernel et vDS ;
- validation vSAN/HA/DRS lorsque utilisés ;
- refus de sortir de maintenance si l'hôte reste dans un état dégradé bloquant ;
- sortie de maintenance ;
- réactivation contrôlée de DRS/DPM ou des paramètres suspendus ;
- rebalance facultatif, sans rapatriement forcé de toutes les VM ;
- vérification qu'une VM de test peut être placée ou migrée sur l'hôte selon le
  mode de validation choisi.

Artefact AAP : `vmware_host_maintenance_exit_summary`.

## Maintenance Hyper-V via SCVMM

### `ansible-hyperv-host-maintenance-enter`

Entrée contrôlée d'un nœud Hyper-V en maintenance via SCVMM :

- résolution exacte du fabric, host group, cluster et nœud ;
- validation de l'agent VMM, WinRM, du cluster et des droits ;
- contrôle du quorum, CSV, réseaux, live migration et capacité des autres nœuds ;
- inventaire des VM, services, library jobs et tâches VMM en cours ;
- détection des VM non migrables, stockage local, passthrough, affinités ou
  contraintes applicatives ;
- choix explicite du comportement SCVMM : live migration, save state ou arrêt ;
- live migration obligatoire par défaut pour les workloads disponibles ;
- refus du `save state` ou de l'arrêt sans variable explicite ;
- drain du nœud et vérification des rôles cluster restants ;
- entrée en maintenance SCVMM ;
- vérification que le nœud ne reçoit plus de nouveau placement ;
- publication des VM déplacées et des exceptions.

Artefact AAP : `hyperv_host_maintenance_enter_summary`.

### `ansible-hyperv-host-maintenance-exit`

Sortie contrôlée de maintenance via SCVMM :

- validation du service Hyper-V, du cluster, de l'agent VMM et de WinRM ;
- contrôle des CSV, chemins de stockage, virtual switches et live migration ;
- vérification du niveau de patch, du reboot pending et des événements critiques ;
- remise en ligne du nœud dans le cluster et sortie de maintenance VMM ;
- contrôle que le placement est de nouveau autorisé ;
- failback/rebalance facultatif, jamais implicite ;
- vérification d'une live migration de test selon le profil de validation.

Artefact AAP : `hyperv_host_maintenance_exit_summary`.

## Mise à jour de la vCenter Server Appliance

### `ansible-vcenter-appliance-update`

Patch ou minor update contrôlé de la VCSA. Une montée majeure nécessitant le
déploiement d'une nouvelle appliance reste hors périmètre et devra devenir
`ansible-vcenter-appliance-upgrade`.

Périmètre :

- découverte de la version/build, du mode de déploiement et de la topologie SSO ;
- recherche des updates disponibles via l'API appliance/VAMI ou un repository
  interne approuvé ;
- cible de version allowlistée ;
- contrôle de compatibilité avec ESXi, NSX, sauvegarde, réplication, plugins et
  solutions enregistrées ;
- vérification de santé des services, espace disque, certificats et réplication
  vCenter lorsque applicable ;
- sauvegarde native file-based récente et vérifiée obligatoire par défaut ;
- snapshot VM uniquement comme protection complémentaire et temporaire ;
- stage/download séparé de l'installation ;
- acceptation EULA et lancement de l'update avec suivi de progression ;
- attente du reboot et du retour des APIs ;
- validation SSO, inventaire, services, alarmes, vLCM et connectivité des hosts ;
- suppression différée du snapshot après validation ;
- publication du build avant/après et des éventuels services dégradés.

Modes : `check`, `stage`, `install`, `audit`.

Artefact AAP : `vcenter_appliance_update_summary`.

## Mise à jour des hôtes ESXi

### `ansible-vmware-esxi-update`

Mise à jour d'un hôte ou rolling update d'un cluster via vSphere Lifecycle
Manager :

- découverte du mode vLCM image ou baseline encore supporté par la version ;
- mode image vLCM privilégié ;
- définition ou sélection de l'image désirée : ESXi base image, vendor add-on,
  composants, drivers et firmware lorsque l'intégration matérielle le permet ;
- contrôle de conformité et precheck de remédiation ;
- validation HCL, add-ons, VIB tiers, boot device, Secure Boot et capacité de rollback ;
- refus des downgrades implicites de composants ;
- validation de la version vCenter requise avant la version ESXi cible ;
- sélection d'un seul hôte ou d'un cluster avec `max_parallel_hosts: 1` par défaut ;
- appel de `ansible-vmware-host-maintenance-enter` lorsque la remédiation exige
  la maintenance ;
- prise en charge facultative du live patch uniquement si la combinaison
  vCenter/ESXi/image/patch répond aux prérequis découverts ;
- remediation vLCM, suivi du task ID et des logs Update Manager ;
- reboot si nécessaire ;
- validation du build, de la conformité à l'image, des drivers, datastores,
  réseaux, HA/DRS et hardware health ;
- appel de `ansible-vmware-host-maintenance-exit` après succès ;
- arrêt du rolling update au premier échec par défaut ;
- aucune poursuite sur le nœud suivant si le cluster est sous le seuil de capacité.

Artefact AAP : `vmware_esxi_update_summary`.

## Mise à jour des nœuds Hyper-V via SCVMM et WSUS

### `ansible-hyperv-node-update`

Mise à jour d'un nœud ou rolling update d'un cluster Hyper-V via l'intégration
Update Server/WSUS de SCVMM :

- découverte du serveur WSUS enregistré dans le fabric VMM ;
- validation de la synchronisation WSUS et de la baseline d'updates VMM ;
- scan de conformité du nœud ou du cluster ;
- publication des KB applicables, supersedées, refusées et nécessitant un reboot ;
- sélection d'une baseline allowlistée ;
- refus d'installer une update non approuvée dans la baseline ;
- contrôle du cluster, quorum, CSV, live migration et capacité résiduelle ;
- blocage des clusters Storage Spaces Direct/S2D dans ce workflow VMM générique ;
- entrée en maintenance via `ansible-hyperv-host-maintenance-enter` ;
- remediation SCVMM/WSUS du nœud ;
- suivi des jobs VMM et Windows Update ;
- reboot contrôlé lorsque requis ;
- rescan de conformité jusqu'à état terminal ;
- contrôle des services Hyper-V, Failover Clustering, agent VMM, stockage et réseau ;
- sortie via `ansible-hyperv-host-maintenance-exit` ;
- rolling update séquentiel du cluster avec arrêt au premier échec ;
- production d'un rapport par nœud et d'un résumé cluster.

Artefact AAP : `hyperv_node_update_summary`.

## Variables proposées

```yaml
hypervisor_platform: vmware  # vmware | hyperv
maintenance_operation: enter  # enter | exit
host_name: esx01.example.net
cluster_name: Cluster-Production
maintenance_timeout_seconds: 7200
max_parallel_hosts: 1
allow_poweroff_workloads: false
allow_save_state_workloads: false
allow_empty_cluster_capacity_margin: false

vmware_evacuate_powered_off_vms: true
vmware_vsan_evacuation_mode: ensureAccessibility
vmware_allow_live_patch: false
vmware_vlcm_mode: auto  # auto | image | baseline
vmware_target_image: null
vmware_stop_on_first_failure: true

vcenter_update_operation: check  # check | stage | install | audit
vcenter_target_version: null
vcenter_update_repository: null
vcenter_native_backup_required: true
vcenter_pre_update_snapshot: true

scvmm_update_server: wsus.example.net
scvmm_update_baseline: HyperV-Production-Approved
hyperv_allow_cluster_remediation: true
hyperv_block_s2d_cluster: true
hyperv_stop_on_first_failure: true

change_number: null
confirm_enter_maintenance: false
confirm_start_update: false
confirm_exit_maintenance: false
```

## Garde-fous

1. TLS validé par défaut ;
2. version, build et capacités découverts avant mutation ;
3. verrou partagé `host:<fqdn>` et `cluster:<id>` ;
4. ticket et fenêtre de changement obligatoires en production ;
5. capacité résiduelle et santé cluster validées ;
6. aucune extinction ou save state implicite de workload ;
7. aucune remédiation parallèle par défaut ;
8. arrêt au premier échec et interdiction de continuer sur un cluster dégradé ;
9. sources d'updates, images et baselines allowlistées ;
10. refus des downgrades implicites ;
11. sauvegarde VCSA validée avant update ;
12. sortie de maintenance uniquement après contrôles post-update ;
13. timeout borné et tâches suivies jusqu'à état terminal ;
14. nettoyage des snapshots temporaires uniquement après validation ;
15. artefact sans secret avec état de chaque host ;
16. libération des verrous dans un bloc `always` ;
17. matrice vCenter × ESXi × matériel et SCVMM × Hyper-V × WSUS publiée.

## Intégration AAP / ServiceNow

Job Templates distincts :

- maintenance VMware enter/exit ;
- maintenance Hyper-V enter/exit ;
- check/stage/install update VCSA ;
- compliance/remediation ESXi ;
- compliance/remediation Hyper-V.

Workflow VMware recommandé :

1. approbation et downtime Centreon ;
2. contrôle de sauvegarde et santé cluster ;
3. maintenance enter ;
4. remédiation vLCM ;
5. contrôles post-update ;
6. maintenance exit ;
7. suppression downtime et mise à jour CMDB.

Workflow Hyper-V recommandé :

1. approbation et downtime Centreon ;
2. scan baseline SCVMM/WSUS ;
3. maintenance enter et drain ;
4. remediation et reboot ;
5. rescan conformité ;
6. maintenance exit ;
7. nœud suivant puis mise à jour CMDB.

## Ordre de réalisation recommandé

1. maintenance VMware enter/exit ;
2. maintenance Hyper-V enter/exit ;
3. `ansible-vcenter-appliance-update` en modes check/stage ;
4. installation contrôlée des patches VCSA ;
5. `ansible-vmware-esxi-update` sur un hôte jetable puis cluster ;
6. `ansible-hyperv-node-update` avec SCVMM/WSUS ;
7. workflows rolling avec Centreon et ServiceNow.

## Validation attendue

- tests unitaires des prechecks, plans et états terminaux ;
- tests VMware avec DRS activé/désactivé et VM non migrable ;
- tests vSAN des différents modes d'évacuation ;
- tests VCSA check/stage/install et restauration de sauvegarde ;
- tests vLCM image, add-on constructeur et VIB incompatible ;
- tests Hyper-V cluster, CSV, live migration et reboot ;
- tests SCVMM/WSUS avec nœud conforme, non conforme et update en échec ;
- test bloquant S2D ;
- test d'arrêt au premier échec d'un rolling update ;
- matrices publiées VMware et Microsoft réellement validées.
