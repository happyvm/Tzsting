# Roadmap d'automatisation Veeam / NetBackup

Ce document complète [`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md) pour le
périmètre sauvegarde. Il décrit les briques autonomes à ajouter au dépôt pour
permettre à un exploitant de ne récupérer que le code correspondant à son
logiciel de sauvegarde, à ses agents et à ses cibles de stockage.

Les projets Veeam et NetBackup restent séparés. Ils partagent les mêmes
principes de sécurité et le même contrat de sortie AAP/ServiceNow, mais ne
masquent pas les différences fonctionnelles entre les deux produits.

Le périmètre NetBackup couvre uniquement un **primary server et des media
servers installés sur des systèmes d'exploitation standards**. Les NetBackup
Appliances sont explicitement hors périmètre.

## Principes de découpage

- une brique est utilisable indépendamment du reste du dépôt ;
- Veeam conserve les notions de **job**, **protection group**, **agent** et
  **repository** ;
- NetBackup conserve les notions de **policy**, **client**, **media server**,
  **storage server**, **disk pool** et **storage unit** ;
- VMware, Hyper-V et machine physique sont des plateformes explicites dans les
  variables et les préflights ;
- les intégrations DXi et StoreOnce ne prétendent pas être identiques : OST,
  Catalyst, gateway server, LSU, disk pool et storage unit restent visibles ;
- aucune suppression de données de sauvegarde n'est implicite ;
- chaque appel API, cmdlet, plug-in ou commande doit être validé par version de
  produit, de système d'exploitation et de firmware ;
- l'API REST est privilégiée, avec PowerShell ou CLI uniquement lorsque l'API
  officielle ne couvre pas l'opération ou le niveau de détail nécessaire.

## Catalogue cible

### Configuration des plateformes

#### `ansible-veeam-conf`

Configuration déclarative du serveur Veeam Backup & Replication et, lorsque
nécessaire, de son hôte Windows :

- comptes locaux d'automatisation et rotation contrôlée des secrets ;
- jonction Active Directory et groupes d'administration/RBAC ;
- NTP, timezone et DNS du serveur Windows ;
- certificats et validation TLS de l'API ;
- paramètres SMTP et destinataires de notification ;
- serveurs syslog, protocole, port et TLS ;
- paramètres généraux d'audit et de journalisation ;
- test des connexions configurées sans exposer les secrets ;
- artefact AAP : `veeam_conf_summary`.

La configuration Windows générique doit rester clairement séparée des
paramètres propres à Veeam afin d'éviter de modifier implicitement l'OS lors
d'une simple évolution du logiciel de sauvegarde.

#### `ansible-netbackup-conf`

Configuration déclarative d'un primary server NetBackup installé sur un OS
standard :

- comptes locaux, groupes et RBAC ;
- Active Directory/LDAP lorsque la plateforme le permet ;
- NTP, timezone et DNS du système d'exploitation ;
- certificats, validation TLS, autorité NetBackup et accès API ;
- SMTP et destinataires d'alerte ;
- syslog et niveau de journalisation ;
- configuration des media servers déclarés ;
- audit de conformité de la configuration ;
- artefact AAP : `netbackup_conf_summary`.

Le playbook ne contient aucun rôle, variable ou chemin propre aux NetBackup
Appliances. Il doit refuser une cible identifiée comme appliance.

### Déploiement des clients et agents

#### `ansible-netbackup-client-deploy`

Déploiement et mise à niveau contrôlée du client NetBackup sur des serveurs
Windows ou Linux, physiques ou virtuels :

- détection de l'OS, de l'architecture et de la version déjà installée ;
- récupération des médias depuis un dépôt interne approuvé, jamais depuis une
  URL arbitraire fournie à l'exécution ;
- installation silencieuse Windows avec fichier de réponse ou scripts officiels ;
- installation Linux avec installateur natif ou script NetBackup selon la
  distribution et la version ;
- configuration du primary server, du nom client et des serveurs autorisés ;
- enrôlement du certificat hôte et gestion du token lorsque nécessaire ;
- ouverture ou validation des flux nécessaires sans désactiver le pare-feu ;
- démarrage et contrôle des services NetBackup ;
- tests `bpclntcmd`, connectivité BPCD et validation de l'identité du client ;
- mode `install`, `upgrade` et `audit`, avec désinstallation séparée et
  explicitement destructive ;
- artefact AAP : `netbackup_client_deploy_summary`.

La création d'une policy n'est pas implicite. Elle reste la responsabilité de
`ansible-netbackup-policy-create` afin que le déploiement du logiciel et la
mise en protection puissent utiliser des workflows et des droits distincts.

#### `ansible-veeam-agent-deploy`

Déploiement d'un Veeam Agent managé sur les machines physiques Windows ou Linux :

- détection de l'OS, de l'architecture, du Secure Boot et de la compatibilité du
  module kernel Linux ;
- mode centralisé par protection group Veeam ou préinstallation par Veeam
  Deployment Kit ;
- transfert sécurisé des packages, du XML de configuration et des certificats
  temporaires ;
- installation de Veeam Installer Service sous Windows ou Veeam Deployer
  Service sous Linux ;
- rattachement à un protection group pour agents préinstallés ou déclenchement
  d'un rescan du groupe existant ;
- remplacement et contrôle du certificat temporaire par l'identité propre à la
  machine ;
- installation/mise à niveau de Veeam Agent et Veeam Transport Service ;
- contrôle des services, de la communication avec VBR et de l'état managé ;
- redémarrage interdit par défaut et autorisé uniquement par variable explicite ;
- mode `install`, `upgrade` et `audit` ;
- artefact AAP : `veeam_agent_deploy_summary`.

Les fichiers du Deployment Kit contiennent du matériel d'amorçage sensible.
Ils doivent être stockés dans un dépôt protégé, transférés de façon temporaire
et supprimés du nœud cible dans un bloc `always`.

### Intégration des cibles de stockage

#### `ansible-veeam-repository-dxi`

Intégration d'un Quantum DXi comme repository Veeam dédié :

- découverte du modèle, du firmware et des capacités d'intégration Veeam ;
- création ou validation de la cible logique requise côté DXi selon le contrat
  API de la version ;
- création ou rotation du compte d'accès dédié à Veeam ;
- enregistrement du DXi comme deduplicating storage appliance dans VBR ;
- sélection du gateway/mount server et validation de ses flux ;
- configuration du chemin, de la capacité, des limites de tâches et du débit ;
- validation de Fast Clone et des paramètres imposés par la version ;
- rescan du repository et test d'écriture non destructif ;
- artefact AAP : `veeam_repository_dxi_summary`.

Cette brique ne transforme pas le DXi en repository Linux générique. Elle
utilise le mode d'intégration DXi supporté par Veeam et publie les limitations
détectées par version.

#### `ansible-netbackup-storage-dxi`

Intégration d'un Quantum DXi à NetBackup via OpenStorage (OST) :

- création ou validation du storage server OST et de ses LSU côté DXi ;
- création du compte OST et contrôle des droits ;
- installation ou mise à niveau du plug-in OST Quantum sur chaque media server
  Windows ou Linux concerné ;
- arrêt et redémarrage ordonné des services NetBackup lors d'une évolution du
  plug-in ;
- enregistrement du storage server dans NetBackup ;
- création du disk pool et de la storage unit ;
- configuration de la concurrence, des media servers autorisés et des seuils ;
- option séparée pour optimized duplication/réplication OST ;
- tests de connectivité, inventaire des LSU et test d'écriture ;
- artefact AAP : `netbackup_storage_dxi_summary`.

Les binaires du plug-in sont validés par checksum et par matrice de
compatibilité. L'installation sur un media server ne doit jamais être déduite
du seul fait qu'il apparaît dans l'inventaire NetBackup.

#### `ansible-veeam-repository-storeonce`

Intégration d'un HPE StoreOnce comme repository Veeam Catalyst :

- découverte de la version StoreOnce et des capacités Catalyst disponibles ;
- création ou validation du Catalyst Store ;
- création du Catalyst Client Veeam, contrôle d'accès et rotation du secret ;
- choix explicite du transport Catalyst sur Ethernet ou Fibre Channel ;
- création du repository HPE StoreOnce dans VBR ;
- sélection du gateway server et validation du Veeam Data Mover ;
- configuration de la concurrence, de la limite d'ingestion et de la capacité ;
- immutabilité activable uniquement lorsque la combinaison StoreOnce/Veeam la
  supporte ;
- rescan et test d'écriture non destructif ;
- artefact AAP : `veeam_repository_storeonce_summary`.

#### `ansible-netbackup-storage-storeonce`

Intégration d'un HPE StoreOnce à NetBackup avec le Catalyst Plug-in OST :

- création ou validation du Catalyst Store et du Catalyst Client NetBackup ;
- contrôle d'accès au store et choix Ethernet ou Catalyst over Fibre Channel ;
- installation ou mise à niveau silencieuse du plug-in HPE StoreOnce Catalyst
  OST sur chaque media server Windows ou Linux ;
- arrêt/redémarrage ordonné des services NetBackup autour de l'évolution du
  plug-in ;
- gestion contrôlée de `plugin.conf`, globale ou ciblée par StoreOnce/store ;
- enregistrement du storage server, création du disk pool et de la storage unit ;
- options séparées pour Optimized Duplication, A.I.R., Accelerator et
  immutabilité lorsqu'elles sont supportées ;
- contrôle de cohérence de version du plug-in sur tous les media servers d'un
  même domaine ;
- test de connectivité, inventaire du store et test d'écriture ;
- artefact AAP : `netbackup_storage_storeonce_summary`.

### Cycle de vie des jobs et policies

#### `ansible-veeam-job-create`

Création déclarative d'un job de sauvegarde VMware ou Hyper-V :

- nom unique et description ;
- plateforme `vmware` ou `hyperv` ;
- sélection statique de VM ou sélection dynamique lorsque le produit le permet ;
- repository, proxy, gateway et paramètres de transport ;
- calendrier, fenêtre d'exécution et fréquence ;
- mode full/incrémental, synthétique et politique de rétention ;
- GFS lorsque demandé ;
- application-aware processing/VSS et traitement des applications ;
- chiffrement, compression, déduplication et limites de débit ;
- activation ou création désactivée ;
- artefact AAP : `veeam_job_create_summary`.

#### `ansible-veeam-job-remove`

Suppression contrôlée d'un job Veeam :

- résolution non ambiguë par identifiant ou nom exact ;
- refus si le job est en cours d'exécution ;
- retrait de la configuration uniquement par défaut ;
- conservation des chaînes de sauvegarde par défaut ;
- purge éventuelle des données derrière une variable distincte et une double
  confirmation explicite ;
- artefact AAP : `veeam_job_remove_summary`.

#### `ansible-netbackup-policy-create`

Création déclarative d'une policy NetBackup VMware ou Hyper-V :

- nom unique, type de policy et activation ;
- sélection statique de VM ou Intelligent Policy/query rule ;
- storage unit, media server et pool ;
- schedules, fenêtres, fréquence et rétention ;
- full, differential incremental et cumulative incremental ;
- Accelerator/CBT ou options spécifiques à la plateforme lorsque supportées ;
- quiescence/VSS et option de récupération granulaire des fichiers ;
- limites de concurrence et de ressources ;
- artefact AAP : `netbackup_policy_create_summary`.

#### `ansible-netbackup-policy-remove`

Suppression contrôlée d'une policy NetBackup :

- résolution non ambiguë par identifiant ou nom exact ;
- désactivation préalable optionnelle ;
- refus si des jobs actifs utilisent la policy ;
- suppression de la policy sans expiration des images par défaut ;
- expiration éventuelle des images dans une opération séparée, destructive et
  soumise à double confirmation ;
- artefact AAP : `netbackup_policy_remove_summary`.

### Opérations de sauvegarde

#### `ansible-veeam-backup-vm`

Déclenchement d'une sauvegarde à la demande :

- démarrage d'un job existant ;
- sauvegarde rapide d'une VM unique lorsque l'API et la plateforme le permettent ;
- choix incrémental/full actif/synthetic full selon les capacités disponibles ;
- attente facultative de la fin de session ;
- publication du résultat, du restore point créé et des statistiques de transfert ;
- artefact AAP : `veeam_backup_vm_summary`.

Le playbook ne doit pas simuler une sauvegarde unitaire Hyper-V par création
silencieuse d'un job temporaire. Si la version utilisée ne fournit pas cette
capacité, il doit l'indiquer explicitement ou démarrer le job existant contenant
la VM.

#### `ansible-netbackup-backup-vm`

Déclenchement d'une sauvegarde NetBackup :

- lancement manuel d'une policy existante ;
- sélection explicite d'une VM lorsque la version et l'interface le permettent ;
- choix du schedule de type full ou incrémental ;
- suivi du job jusqu'à son état terminal ;
- remontée du job ID, du status code, de l'image produite et des octets traités ;
- artefact AAP : `netbackup_backup_vm_summary`.

La création automatique d'une policy temporaire est interdite par défaut et
ne peut être proposée que comme mode séparé, explicitement activé et nettoyé.

### Restauration complète de VM

#### `ansible-veeam-restore-vm`

Restauration d'une VM VMware ou Hyper-V :

- recherche de la VM et de ses restore points ;
- sélection explicite du restore point ou stratégie `latest_successful` ;
- restauration à l'emplacement d'origine ou vers un emplacement alternatif ;
- renommage, datastore/CSV, hôte/cluster et mapping réseau ;
- restauration complète ou instant recovery lorsque supportée ;
- choix de mise sous tension après restauration ;
- refus d'écraser une VM existante sans confirmation forte ;
- verrou partagé sur la VM source et le nom de destination ;
- artefact AAP : `veeam_restore_vm_summary`.

#### `ansible-netbackup-restore-vm`

Restauration d'une VM VMware ou Hyper-V :

- recherche des images disponibles et validation de leur intégrité ;
- restauration originale ou alternative ;
- sélection du datastore/CSV, de l'hôte/cluster et des réseaux ;
- restauration complète et modes accélérés uniquement lorsqu'ils sont
  officiellement supportés pour la plateforme et la version ;
- conservation des différences VMware/Hyper-V au lieu de présenter une fausse
  parité fonctionnelle ;
- refus d'écrasement sans confirmation forte ;
- artefact AAP : `netbackup_restore_vm_summary`.

L'Instant Recovery NetBackup doit être déclaré dans une matrice de capacités
par version : sa disponibilité n'est pas identique entre VMware et Hyper-V.

### Restauration de fichiers

#### `ansible-veeam-restore-file`

Restauration granulaire Windows ou Linux depuis une sauvegarde de VM :

- montage/démarrage de la session FLR ;
- navigation ou recherche de chemins ;
- restauration vers l'emplacement original, alternatif ou un répertoire de
  staging ;
- comportement d'écrasement explicite ;
- préservation des ACL, propriétaires et timestamps lorsque supportée ;
- fermeture garantie de la session FLR dans un bloc `always` ;
- artefact AAP : `veeam_restore_file_summary`.

#### `ansible-netbackup-restore-file`

Restauration granulaire Windows ou Linux depuis une image VMware ou Hyper-V :

- vérification que la policy autorisait la récupération de fichiers ;
- sélection de l'image et des chemins ;
- destination originale, alternative ou recovery host ;
- contrôle de compatibilité entre l'OS source et l'hôte de restauration ;
- prise en compte de la présence éventuelle du client NetBackup dans la VM ;
- comportement d'écrasement explicite et journalisation de chaque fichier ;
- artefact AAP : `netbackup_restore_file_summary`.

## Matrice cible

| Projet | Veeam | NetBackup | VMware | Hyper-V | Physique | Destructif |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| `*-conf` | Oui | Oui | N/A | N/A | Serveur de sauvegarde | Configuration |
| `netbackup-client-deploy` | — | Oui | Invité possible | Invité possible | Oui | Installation |
| `veeam-agent-deploy` | Oui | — | Hors cible principale | Hors cible principale | Oui | Installation |
| `veeam-repository-dxi` | Oui | — | N/A | N/A | Cible DXi | Configuration |
| `netbackup-storage-dxi` | — | Oui | N/A | N/A | Cible DXi | Configuration |
| `veeam-repository-storeonce` | Oui | — | N/A | N/A | Cible StoreOnce | Configuration |
| `netbackup-storage-storeonce` | — | Oui | N/A | N/A | Cible StoreOnce | Configuration |
| `*-job-create` / `*-policy-create` | Oui | Oui | Oui | Oui | Agents via projet dédié | Création |
| `*-job-remove` / `*-policy-remove` | Oui | Oui | Oui | Oui | Agents via projet dédié | Oui, configuration |
| `*-backup-vm` | Oui | Oui | Oui | Selon capacités/version | — | Non |
| `*-restore-vm` | Oui | Oui | Oui | Oui, modes variables | — | Oui |
| `*-restore-file` | Oui | Oui | Oui | Oui, prérequis variables | Via agent à prévoir | Oui |

## Variables communes proposées

```yaml
backup_provider: veeam  # veeam | netbackup
protected_workload_type: vm  # vm | physical
virtualization_platform: vmware  # vmware | hyperv
backup_server: backup.example.net
backup_validate_certs: true
backup_api_version: auto

target_provider: dxi  # dxi | storeonce
target_transport: ethernet  # ethernet | fibre_channel
target_name: backup-target-01
media_servers: []
gateway_server: null

client_state: present  # present | latest | audit
allow_reboot: false

vm_name: srv-example
restore_point_strategy: latest_successful
wait_for_completion: true
operation_timeout_seconds: 14400

confirm_remove: false
confirm_overwrite: false
confirm_delete_backup_data: false
confirm_uninstall_agent: false
```

Les secrets, tokens, certificats privés et mots de passe OST/Catalyst ne doivent
jamais être placés dans `group_vars`. Ils sont fournis par AAP Credential,
Ansible Vault ou un gestionnaire de secrets externe.

## Garde-fous communs

Tous les projets doivent intégrer :

1. validation de la version et découverte des capacités réellement disponibles ;
2. validation TLS activée par défaut ;
3. recherche non ambiguë des serveurs, clients, agents, jobs/policies, VM,
   repositories, storage units et restore points ;
4. validation de checksum et de provenance pour chaque package ou plug-in ;
5. verrou partagé empêchant sauvegarde, suppression, installation et
   restauration concurrentes sur une même ressource ;
6. refus des opérations destructives sans confirmation explicite ;
7. vérification de la capacité de destination avant restauration ;
8. contrôle des jobs, sessions et services déjà actifs ;
9. journalisation sans secret et publication d'un artefact `set_stats` stable ;
10. libération des verrous, nettoyage des médias temporaires et fermeture des
    sessions dans un bloc `always` ;
11. mode `check`, `audit` ou `plan` lorsque l'opération peut être simulée sans
    danger ;
12. matrice de compatibilité version logiciel × OS × firmware × plug-in.

## Ordre de réalisation recommandé

### Lot 1 — Configuration et découverte

1. `ansible-veeam-conf` ;
2. `ansible-netbackup-conf` ;
3. rôles de découverte de version/capacités et authentification réutilisables.

### Lot 2 — Déploiement des clients et agents

4. `ansible-netbackup-client-deploy` ;
5. `ansible-veeam-agent-deploy` ;
6. tests d'enrôlement, de certificat et de communication sur Windows et Linux.

### Lot 3 — Intégration des cibles

7. `ansible-veeam-repository-dxi` ;
8. `ansible-netbackup-storage-dxi` ;
9. `ansible-veeam-repository-storeonce` ;
10. `ansible-netbackup-storage-storeonce` ;
11. tests d'écriture, de rescan et de cohérence multi-media-server.

### Lot 4 — Protection déclarative

12. `ansible-veeam-job-create` et `ansible-veeam-job-remove` ;
13. `ansible-netbackup-policy-create` et `ansible-netbackup-policy-remove` ;
14. intégration à `createvm` et `deletevm` pour ajouter ou retirer la protection
    sans rendre ces projets dépendants du logiciel de sauvegarde.

### Lot 5 — Exécution à la demande

15. `ansible-veeam-backup-vm` ;
16. `ansible-netbackup-backup-vm` ;
17. préflight partagé « dernière sauvegarde valide » pour `deletevm`,
    `inplace-upgrade` et les futures opérations destructives.

### Lot 6 — Restauration

18. `ansible-veeam-restore-vm` ;
19. `ansible-netbackup-restore-vm` ;
20. `ansible-veeam-restore-file` ;
21. `ansible-netbackup-restore-file`.

La restauration doit être testée avant d'être exposée largement dans
ServiceNow. Un job de sauvegarde qui réussit sans restauration régulièrement
testée ne constitue pas une preuve suffisante de récupérabilité.

## Intégration AAP / ServiceNow

Chaque brique doit exposer un Job Template distinct pour séparer les droits :

- configuration de la plateforme ;
- déploiement ou mise à niveau d'un client/agent ;
- intégration d'une cible DXi ou StoreOnce ;
- création de protection ;
- suppression de protection ;
- sauvegarde à la demande ;
- restauration complète ;
- restauration de fichiers.

Les restaurations, désinstallations et suppressions doivent utiliser des
workflows avec approbation, numéro de changement, fenêtre autorisée et journal
de résultat. Le workflow ServiceNow sélectionne le provider et la cible depuis
la CMDB ou le catalogue, puis appelle uniquement le projet correspondant.

## Validation attendue

- tests unitaires des payloads REST, fichiers de réponse et commandes générées ;
- mocks des API pour les erreurs, conflits, timeouts et changements de version ;
- tests d'idempotence sur les projets `*-conf`, `*-deploy`, `*-repository-*`,
  `*-storage-*` et `*-create` ;
- tests de non-régression des recherches ambiguës ;
- tests d'installation et de mise à niveau des clients Windows/Linux ;
- tests de cohérence du plug-in OST/Catalyst sur plusieurs media servers ;
- environnement jetable VMware et Hyper-V pour les tests de restauration ;
- machines physiques ou bare-metal de test pour Veeam Agent et NetBackup Client ;
- test périodique de restauration automatisée avec suppression de la VM de test ;
- matrice publiée des versions Veeam/NetBackup, DXi/StoreOnce, OS, plug-ins et
  plateformes réellement validées.
