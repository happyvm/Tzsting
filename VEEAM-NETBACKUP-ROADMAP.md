# Roadmap d'automatisation Veeam / NetBackup

Ce document complète [`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md) pour le
périmètre sauvegarde. Il décrit des briques Ansible autonomes permettant de
récupérer uniquement le code correspondant au logiciel, au workload et à la
cible de stockage utilisés.

Les projets Veeam et NetBackup restent séparés. Ils partagent les mêmes
principes de sécurité et le même contrat de sortie AAP/ServiceNow, sans masquer
les différences fonctionnelles entre les produits.

Le périmètre NetBackup couvre uniquement un **primary server et des media
servers installés sur des systèmes d'exploitation standards**. Les NetBackup
Appliances sont hors périmètre.

## Principes de découpage

- une brique est utilisable indépendamment du reste du dépôt ;
- le déploiement d'un agent ou client ne crée jamais implicitement une protection ;
- création, ajout, retrait et suppression d'une protection sont des opérations
  distinctes ;
- retirer un serveur d'un job ou d'une policy ne désinstalle jamais implicitement
  l'agent/client et ne supprime pas les sauvegardes existantes ;
- Veeam conserve les notions de job, protection group, agent et repository ;
- NetBackup conserve les notions de policy, client, media server, storage server,
  disk pool et storage unit ;
- VMware, Hyper-V et machine physique sont explicites dans les variables ;
- OST, Catalyst, gateway server, LSU, disk pool et storage unit restent visibles ;
- chaque appel API, cmdlet, plug-in ou commande est validé par version ;
- l'API REST est privilégiée, PowerShell ou CLI servant uniquement de repli
  officiellement supporté.

## Catalogue cible

### Configuration des plateformes

#### `ansible-veeam-conf`

Configuration déclarative de Veeam Backup & Replication et de son hôte Windows
lorsque nécessaire : comptes locaux, AD/RBAC, NTP, timezone, DNS, certificats,
TLS, SMTP, syslog, audit et tests de connexion.

**Statut** : implémenté - compte local, jonction AD (optionnelle), NTP et
timezone de l'hôte Windows via WinRM ; authentification OAuth 2.0 réelle et
notifications email/SNMP de VBR via son API REST. Restent à faire : DNS,
certificats/TLS, RBAC applicatif VBR (distinct de la jonction AD de l'hôte),
audit de conformité et test de connexion dédié. Voir
[`ansible-veeam-conf/README.md`](ansible-veeam-conf/README.md).

Artefact AAP : `veeam_conf_summary`.

#### `ansible-netbackup-conf`

Configuration déclarative d'un primary server NetBackup sur OS standard :
comptes locaux, AD/LDAP, NTP, timezone, DNS, certificats, autorité NetBackup,
API, SMTP, syslog, media servers et audit de conformité.

Le playbook refuse toute cible identifiée comme NetBackup Appliance.

**Statut** : implémenté - compte local, NTP et timezone du primary server
Linux via SSH ; authentification JWT réelle et notifications SMTP/SNMP via
l'API REST NetBackup. Restent à faire : AD/LDAP applicatif, DNS,
certificats, autorité NetBackup, media servers et audit de conformité. Voir
[`ansible-netbackup-conf/README.md`](ansible-netbackup-conf/README.md).

Artefact AAP : `netbackup_conf_summary`.

### Déploiement des clients et agents

#### `ansible-netbackup-client-deploy`

Déploiement ou mise à niveau du client NetBackup sur Windows ou Linux, physique
ou virtuel :

- détection de l'OS, de l'architecture et de la version installée ;
- médias provenant d'un dépôt interne approuvé ;
- installation silencieuse et fichier de réponse ;
- configuration du primary server, du nom client et des serveurs autorisés ;
- enrôlement du certificat hôte et gestion du token ;
- validation des flux sans désactivation globale du pare-feu ;
- contrôle des services, `bpclntcmd`, BPCD et identité du client ;
- modes `install`, `upgrade` et `audit` ;
- désinstallation séparée et explicitement destructive.

La création de la policy reste séparée.

Artefact AAP : `netbackup_client_deploy_summary`.

#### `ansible-veeam-agent-deploy`

Déploiement d'un Veeam Agent managé sur une machine physique Windows ou Linux :

- détection OS, architecture, Secure Boot et compatibilité kernel ;
- mode protection group ou préinstallation par Deployment Kit ;
- transfert sécurisé et temporaire des packages, XML et certificats ;
- installation de Veeam Installer/Deployer Service, Agent et Transport Service ;
- rattachement à un protection group ou rescan du groupe existant ;
- renouvellement du certificat temporaire ;
- contrôle de la communication avec VBR et de l'état managé ;
- redémarrage interdit par défaut ;
- modes `install`, `upgrade` et `audit`.

La création du job reste séparée.

Artefact AAP : `veeam_agent_deploy_summary`.

### Intégration des cibles de stockage

#### `ansible-veeam-repository-dxi`

Intégration d'un Quantum DXi comme repository Veeam dédié : cible logique DXi,
compte Veeam, enregistrement dans VBR, gateway/mount server, limites de tâches,
débit, Fast Clone, rescan et test d'écriture.

Artefact AAP : `veeam_repository_dxi_summary`.

#### `ansible-netbackup-storage-dxi`

Intégration d'un Quantum DXi à NetBackup via OST : storage server, LSU, compte
OST, plug-in Quantum sur les media servers, disk pool, storage unit, concurrence,
optimized duplication et tests d'écriture.

Artefact AAP : `netbackup_storage_dxi_summary`.

#### `ansible-veeam-repository-storeonce`

Intégration d'un HPE StoreOnce comme repository Veeam Catalyst : Catalyst Store,
Catalyst Client Veeam, Ethernet ou Fibre Channel, repository VBR, gateway server,
Data Mover, concurrence, ingestion, immutabilité selon compatibilité, rescan et
test d'écriture.

Artefact AAP : `veeam_repository_storeonce_summary`.

#### `ansible-netbackup-storage-storeonce`

Intégration d'un HPE StoreOnce à NetBackup avec le Catalyst Plug-in OST :
Catalyst Store, Catalyst Client NetBackup, plug-in sur chaque media server,
`plugin.conf`, storage server, disk pool, storage unit, Optimized Duplication,
A.I.R., Accelerator et immutabilité selon compatibilité.

Artefact AAP : `netbackup_storage_storeonce_summary`.

### Protection des VM

#### `ansible-veeam-job-create`

Création déclarative d'un job VMware ou Hyper-V : sélection de VM, repository,
proxy/gateway, calendrier, fenêtre, rétention, GFS, traitement applicatif,
chiffrement, compression, déduplication et activation.

Artefact AAP : `veeam_job_create_summary`.

#### `ansible-veeam-job-remove`

Suppression contrôlée d'un job Veeam. La configuration est retirée par défaut,
mais les chaînes de sauvegarde sont conservées. Toute purge nécessite une
opération distincte et une double confirmation.

Artefact AAP : `veeam_job_remove_summary`.

#### `ansible-netbackup-policy-create`

Création déclarative d'une policy VMware ou Hyper-V : sélection statique ou
Intelligent Policy, storage unit, media server, schedules, rétention, full et
incrémentaux, Accelerator/CBT, quiescence/VSS et limites de concurrence.

Artefact AAP : `netbackup_policy_create_summary`.

#### `ansible-netbackup-policy-remove`

Suppression contrôlée d'une policy sans expiration des images par défaut.
L'expiration des images reste une opération destructive séparée.

Artefact AAP : `netbackup_policy_remove_summary`.

### Protection des serveurs physiques

#### `ansible-veeam-physical-job-create`

Création déclarative d'un **Veeam Agent backup job** pour serveurs physiques
Windows ou Linux :

- nom unique, description et état activé/désactivé ;
- sélection de machines managées ou d'un protection group ;
- vérification de l'Agent et de la communication VBR ;
- sauvegarde machine entière, volumes ou fichiers selon support ;
- repository DXi, StoreOnce ou autre repository Veeam enregistré ;
- calendrier, retries, rétention, GFS et full périodique ;
- traitement applicatif/VSS, chiffrement, compression et débit ;
- création idempotente et refus de convertir silencieusement un job incompatible.

Le projet ne déploie pas l'Agent.

Artefact AAP : `veeam_physical_job_create_summary`.

#### `ansible-veeam-physical-job-add-server`

Ajout idempotent d'un serveur physique dans un Veeam Agent backup job existant :

- résolution exacte du job et de la machine ;
- contrôle du protection group et de la famille d'OS ;
- refus si l'Agent n'est pas managé, compatible ou joignable ;
- ajout direct de la machine ou ajout du protection group selon le mode demandé ;
- rescan facultatif et contrôle du scope final ;
- aucune modification du repository, du calendrier ou de la rétention ;
- démarrage du job uniquement dans une étape séparée.

Artefact AAP : `veeam_physical_job_add_server_summary`.

#### `ansible-veeam-physical-job-remove-server`

Retrait contrôlé d'un serveur physique d'un Veeam Agent backup job existant :

- résolution exacte du job, de la machine et de son mode d'inclusion ;
- refus si une session du job concernant la machine est active ;
- retrait direct lorsque la machine est explicitement membre du job ;
- pour un job ciblant un protection group, exclusion de la machine ou retrait de
  la machine du groupe selon une variable explicite et les capacités du groupe ;
- refus de supprimer un protection group entier pour retirer une seule machine ;
- refus de retirer le dernier membre sauf `allow_empty_protection=true` ;
- vérification que la machine n'appartient plus au scope effectif après rescan ;
- conservation de l'Agent, du protection group et des restore points par défaut ;
- aucune désinstallation ni suppression de données implicite ;
- confirmation explicite `confirm_remove_server=true`.

Artefact AAP : `veeam_physical_job_remove_server_summary`.

#### `ansible-netbackup-physical-policy-create`

Création déclarative d'une policy NetBackup pour serveurs physiques :

- type `MS-Windows` pour Windows ou `Standard` pour Linux/Unix ;
- clients NetBackup déjà installés et enrôlés ;
- validation DNS directe/inverse, nom canonique et communication ;
- backup selections adaptées à l'OS ;
- storage unit DXi, StoreOnce ou autre cible enregistrée ;
- schedules full et incrémentaux, fenêtres et rétention ;
- Accelerator, client-side deduplication et BMR selon compatibilité ;
- création idempotente sans conversion implicite du type de policy.

Le projet ne déploie pas le client.

Artefact AAP : `netbackup_physical_policy_create_summary`.

#### `ansible-netbackup-physical-policy-add-client`

Ajout idempotent d'un serveur physique dans une policy existante :

- résolution exacte de la policy ;
- contrôle du type de policy et de l'OS ;
- validation du nom canonique et détection des doublons casse/alias ;
- vérification du certificat, de `bpclntcmd`, de BPCD et de la confiance ;
- ajout sans modifier schedules, backup selections, storage unit ou rétention ;
- vérification finale de la liste des clients.

Artefact AAP : `netbackup_physical_policy_add_client_summary`.

#### `ansible-netbackup-physical-policy-remove-client`

Retrait contrôlé d'un client physique d'une policy NetBackup existante :

- résolution exacte de la policy et du nom client canonique ;
- détection des entrées en doublon par casse, nom court ou FQDN ;
- refus si un job actif utilise cette policy pour le client concerné ;
- retrait du client uniquement, sans modifier schedules, backup selections,
  storage unit, rétention ou autres clients ;
- refus de laisser une policy active sans client sauf
  `allow_empty_protection=true` ;
- vérification finale de l'absence du client dans la policy ;
- conservation du logiciel NetBackup Client et de son certificat ;
- conservation des images et catalogues de sauvegarde existants ;
- aucune expiration d'image ou désinstallation implicite ;
- confirmation explicite `confirm_remove_server=true`.

Artefact AAP : `netbackup_physical_policy_remove_client_summary`.

### Opérations de sauvegarde à la demande

#### `ansible-veeam-backup-vm`

Démarrage d'un job existant ou sauvegarde rapide d'une VM unique lorsque la
plateforme et la version le permettent.

Artefact AAP : `veeam_backup_vm_summary`.

#### `ansible-netbackup-backup-vm`

Lancement manuel d'une policy VM, suivi du job et publication du status code,
de l'image produite et des octets traités.

Artefact AAP : `netbackup_backup_vm_summary`.

Une future variante `*-backup-physical` pourra déclencher une protection
physique existante sans créer de job ou policy temporaire.

### Restauration

#### `ansible-veeam-restore-vm`

Restauration VMware ou Hyper-V, originale ou alternative, avec sélection du
restore point, destination, datastore/CSV, réseau, Instant Recovery selon
support et confirmation avant écrasement.

Artefact AAP : `veeam_restore_vm_summary`.

#### `ansible-netbackup-restore-vm`

Restauration VMware ou Hyper-V en conservant les différences de capacités entre
plateformes et versions.

Artefact AAP : `netbackup_restore_vm_summary`.

#### `ansible-veeam-restore-file`

Restauration granulaire Windows ou Linux, emplacement original, alternatif ou
staging, avec fermeture garantie de la session FLR.

Artefact AAP : `veeam_restore_file_summary`.

#### `ansible-netbackup-restore-file`

Restauration granulaire depuis une image VM ou physique, vers la destination
originale, alternative ou un recovery host.

Artefact AAP : `netbackup_restore_file_summary`.

## Matrice cible

| Projet | Veeam | NetBackup | VMware | Hyper-V | Physique | Mutation |
|---|:--:|:--:|:--:|:--:|:--:|---|
| `*-conf` | Oui | Oui | N/A | N/A | Serveur de sauvegarde | Configuration |
| `netbackup-client-deploy` | — | Oui | Invité possible | Invité possible | Oui | Installation |
| `veeam-agent-deploy` | Oui | — | Invité possible | Invité possible | Oui | Installation |
| `*-repository-dxi` / `*-storage-dxi` | Oui | Oui | N/A | N/A | Cible DXi | Configuration |
| `*-repository-storeonce` / `*-storage-storeonce` | Oui | Oui | N/A | N/A | Cible StoreOnce | Configuration |
| `veeam-job-create` / `netbackup-policy-create` | Oui | Oui | Oui | Oui | — | Création |
| `*-physical-*-create` | Oui | Oui | — | — | Windows/Linux | Création |
| `*-physical-*-add-*` | Oui | Oui | — | — | Windows/Linux | Ajout |
| `*-physical-*-remove-*` | Oui | Oui | — | — | Windows/Linux | Retrait du scope |
| `*-job-remove` / `*-policy-remove` | Oui | Oui | Oui | Oui | Selon projet | Suppression config |
| `*-backup-vm` | Oui | Oui | Oui | Selon capacités | — | Exécution |
| `*-restore-vm` | Oui | Oui | Oui | Modes variables | — | Destructif possible |
| `*-restore-file` | Oui | Oui | Oui | Oui | Oui | Écriture fichiers |

## Variables communes proposées

```yaml
backup_provider: veeam  # veeam | netbackup
protected_workload_type: physical  # vm | physical
physical_os_family: windows  # windows | linux
backup_server: backup.example.net
backup_validate_certs: true
backup_api_version: auto

target_provider: dxi  # dxi | storeonce
target_transport: ethernet  # ethernet | fibre_channel
target_name: backup-target-01
media_servers: []
gateway_server: null

physical_server_name: srv-physical-01.example.net
protection_name: daily-physical-production
protection_group_name: physical-production
client_state: present  # present | latest | audit
allow_reboot: false
allow_empty_protection: false

wait_for_completion: true
operation_timeout_seconds: 14400

confirm_remove: false
confirm_remove_server: false
confirm_overwrite: false
confirm_delete_backup_data: false
confirm_uninstall_agent: false
preserve_backup_data: true
preserve_agent_or_client: true
```

Les secrets, tokens, certificats privés et mots de passe OST/Catalyst ne doivent
jamais être placés dans `group_vars`. Ils sont fournis par Credential AAP,
Ansible Vault ou un gestionnaire de secrets externe.

## Garde-fous communs

1. validation de version et découverte des capacités ;
2. TLS validé par défaut ;
3. résolution non ambiguë des serveurs, clients, agents, jobs et policies ;
4. validation de checksum et provenance des packages et plug-ins ;
5. verrou partagé sur la ressource modifiée ;
6. idempotence des ajouts et retraits ;
7. validation DNS directe/inverse et détection des alias/casses NetBackup ;
8. refus d'ajouter une famille d'OS incompatible ;
9. aucune modification implicite du calendrier, de la rétention ou de la cible ;
10. retrait du scope distinct de la désinstallation et de la purge des données ;
11. refus de laisser une protection active vide sans autorisation explicite ;
12. journalisation sans secret et artefact `set_stats` stable ;
13. nettoyage et libération des verrous dans un bloc `always` ;
14. modes `check`, `audit` ou `plan` lorsque possible ;
15. matrice logiciel × OS × firmware × plug-in.

## Ordre de réalisation recommandé

### Lot 1 — Configuration et découverte

1. `ansible-veeam-conf` - **fait** (hôte Windows + notifications VBR), reste
   AD/RBAC applicatif, DNS, certificats/TLS, audit ;
2. `ansible-netbackup-conf` - **fait** (hôte Linux + notifications
   NetBackup), reste AD/LDAP applicatif, DNS, certificats, autorité
   NetBackup, media servers, audit ;
3. rôles de découverte et authentification - authentification OAuth2/JWT
   réelle **faite** dans les deux projets (`roles/auth`) ; la découverte de
   version/capacités reste à faire.

### Lot 2 — Déploiement des clients et agents

4. `ansible-netbackup-client-deploy` ;
5. `ansible-veeam-agent-deploy` ;
6. tests d'enrôlement Windows et Linux.

### Lot 3 — Intégration des cibles

7. `ansible-veeam-repository-dxi` ;
8. `ansible-netbackup-storage-dxi` ;
9. `ansible-veeam-repository-storeonce` ;
10. `ansible-netbackup-storage-storeonce`.

### Lot 4 — Protection déclarative des physiques

11. `ansible-veeam-physical-job-create` ;
12. `ansible-netbackup-physical-policy-create` ;
13. `ansible-veeam-physical-job-add-server` ;
14. `ansible-netbackup-physical-policy-add-client` ;
15. `ansible-veeam-physical-job-remove-server` ;
16. `ansible-netbackup-physical-policy-remove-client` ;
17. tests d'idempotence, de compatibilité et de conservation des sauvegardes.

### Lot 5 — Protection déclarative des VM

18. `ansible-veeam-job-create` et `ansible-veeam-job-remove` ;
19. `ansible-netbackup-policy-create` et `ansible-netbackup-policy-remove` ;
20. intégration facultative à `createvm` et `deletevm`.

### Lot 6 — Exécution à la demande

21. `ansible-veeam-backup-vm` ;
22. `ansible-netbackup-backup-vm` ;
23. future variante physique ;
24. préflight partagé « dernière sauvegarde valide ».

### Lot 7 — Restauration

25. `ansible-veeam-restore-vm` ;
26. `ansible-netbackup-restore-vm` ;
27. `ansible-veeam-restore-file` ;
28. `ansible-netbackup-restore-file`.

## Intégration AAP / ServiceNow

Chaque brique expose un Job Template distinct pour séparer les droits :

- configuration ;
- déploiement ou upgrade d'un client/agent ;
- intégration d'une cible ;
- création d'une protection physique ;
- ajout d'un serveur à une protection ;
- retrait d'un serveur d'une protection ;
- création/suppression d'une protection VM ;
- sauvegarde à la demande ;
- restauration complète ou fichier.

Le retrait d'un serveur utilise un workflow avec approbation, numéro de
changement et publication explicite de ce qui est conservé : agent/client,
certificat, protection group et images/restore points.

## Validation attendue

- tests unitaires des payloads REST, cmdlets, fichiers de réponse et commandes ;
- mocks des API et changements de version ;
- tests d'idempotence de création, ajout et retrait ;
- tests des doublons FQDN/nom court/casse ;
- tests de job ou policy en cours d'exécution ;
- tests de retrait du dernier membre ;
- tests Veeam des scopes directs et des protection groups ;
- vérification que l'agent/client reste installé ;
- vérification que les sauvegardes existantes restent restaurables ;
- tests OST/Catalyst multi-media-server ;
- machines physiques de test Windows et Linux ;
- matrice publiée Veeam/NetBackup, DXi/StoreOnce, OS, plug-ins et plateformes.