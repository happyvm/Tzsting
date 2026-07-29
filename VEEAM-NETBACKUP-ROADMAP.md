# Roadmap d'automatisation Veeam / NetBackup

Ce document complète [`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md) pour le
périmètre sauvegarde. Il décrit les briques autonomes à ajouter au dépôt pour
permettre à un exploitant de ne récupérer que le code correspondant à son
logiciel de sauvegarde et à ses besoins.

Les projets Veeam et NetBackup restent séparés. Ils partagent les mêmes
principes de sécurité et le même contrat de sortie AAP/ServiceNow, mais ne
masquent pas les différences fonctionnelles entre les deux produits.

## Principes de découpage

- une brique est utilisable indépendamment du reste du dépôt ;
- Veeam conserve la notion de **job** ;
- NetBackup conserve la notion de **policy**, même lorsque le service exposé
  dans ServiceNow est présenté comme une création ou suppression de job ;
- VMware et Hyper-V sont des plateformes explicites dans les variables et les
  préflights ;
- aucune suppression de données de sauvegarde n'est implicite ;
- chaque appel API, cmdlet ou commande doit être validé par version de produit ;
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

Configuration déclarative d'un primary server NetBackup ou d'une NetBackup
Appliance :

- mode explicite `software` ou `appliance` ;
- comptes locaux, groupes et RBAC ;
- Active Directory/LDAP selon les capacités du mode sélectionné ;
- NTP, timezone et DNS ;
- certificats, validation TLS et accès API ;
- SMTP et destinataires d'alerte ;
- syslog et niveau de journalisation ;
- audit de conformité de la configuration ;
- artefact AAP : `netbackup_conf_summary`.

Le playbook doit refuser les paramètres propres à l'appliance lorsqu'il cible
un primary server installé sur un OS standard, et inversement.

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

| Projet | Veeam | NetBackup | VMware | Hyper-V | Destructif |
|---|:--:|:--:|:--:|:--:|:--:|
| `*-conf` | Oui | Oui | N/A | N/A | Configuration |
| `*-job-create` / `*-policy-create` | Oui | Oui | Oui | Oui | Création |
| `*-job-remove` / `*-policy-remove` | Oui | Oui | Oui | Oui | Oui, configuration |
| `*-backup-vm` | Oui | Oui | Oui | Selon capacités/version | Non |
| `*-restore-vm` | Oui | Oui | Oui | Oui, modes variables | Oui |
| `*-restore-file` | Oui | Oui | Oui | Oui, prérequis variables | Oui |

## Variables communes proposées

```yaml
backup_provider: veeam  # veeam | netbackup
virtualization_platform: vmware  # vmware | hyperv
backup_server: backup.example.net
backup_validate_certs: true
backup_api_version: auto

vm_name: srv-example
restore_point_strategy: latest_successful
wait_for_completion: true
operation_timeout_seconds: 14400

confirm_remove: false
confirm_overwrite: false
confirm_delete_backup_data: false
```

Les secrets ne doivent jamais être placés dans `group_vars`. Ils sont fournis
par AAP Credential, Ansible Vault ou un gestionnaire de secrets externe.

## Garde-fous communs

Tous les projets doivent intégrer :

1. validation de la version et découverte des capacités réellement disponibles ;
2. validation TLS activée par défaut ;
3. recherche non ambiguë des serveurs, jobs/policies, VM et restore points ;
4. verrou partagé empêchant sauvegarde, suppression et restauration concurrentes
   sur la même VM ;
5. refus des opérations destructives sans confirmation explicite ;
6. vérification de la capacité de destination avant restauration ;
7. contrôle des jobs/sessions déjà actifs ;
8. journalisation sans secret et publication d'un artefact `set_stats` stable ;
9. libération des verrous et fermeture des sessions dans un bloc `always` ;
10. mode `check` ou `plan` lorsque l'opération peut être simulée sans danger.

## Ordre de réalisation recommandé

### Lot 1 — Configuration et découverte

1. `ansible-veeam-conf` ;
2. `ansible-netbackup-conf` ;
3. rôles de découverte de version/capacités et authentification réutilisables.

### Lot 2 — Protection déclarative

4. `ansible-veeam-job-create` et `ansible-veeam-job-remove` ;
5. `ansible-netbackup-policy-create` et `ansible-netbackup-policy-remove` ;
6. intégration à `createvm` et `deletevm` pour ajouter ou retirer la protection
   sans rendre ces projets dépendants du logiciel de sauvegarde.

### Lot 3 — Exécution à la demande

7. `ansible-veeam-backup-vm` ;
8. `ansible-netbackup-backup-vm` ;
9. préflight partagé « dernière sauvegarde valide » pour `deletevm`,
   `inplace-upgrade` et les futures opérations destructives.

### Lot 4 — Restauration

10. `ansible-veeam-restore-vm` ;
11. `ansible-netbackup-restore-vm` ;
12. `ansible-veeam-restore-file` ;
13. `ansible-netbackup-restore-file`.

La restauration doit être testée avant d'être exposée largement dans
ServiceNow. Un job de sauvegarde qui réussit sans restauration régulièrement
testée ne constitue pas une preuve suffisante de récupérabilité.

## Intégration AAP / ServiceNow

Chaque brique doit exposer un Job Template distinct pour séparer les droits :

- configuration de la plateforme ;
- création de protection ;
- suppression de protection ;
- sauvegarde à la demande ;
- restauration complète ;
- restauration de fichiers.

Les restaurations et les suppressions doivent utiliser des workflows avec
approbation, numéro de changement, fenêtre autorisée et journal de résultat.
Le workflow ServiceNow sélectionne le provider depuis la CMDB ou le catalogue,
puis appelle uniquement le projet Veeam ou NetBackup correspondant.

## Validation attendue

- tests unitaires des payloads REST et commandes générées ;
- mocks des API pour les erreurs, conflits, timeouts et changements de version ;
- tests d'idempotence sur les projets `*-conf` et `*-create` ;
- tests de non-régression des recherches ambiguës ;
- environnement jetable VMware et Hyper-V pour les tests de restauration ;
- test périodique de restauration automatisée avec suppression de la VM de test ;
- matrice publiée des versions Veeam/NetBackup et des plateformes réellement
  validées.
