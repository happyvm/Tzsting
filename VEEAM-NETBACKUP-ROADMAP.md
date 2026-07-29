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
- le déploiement d'un agent/client ne crée jamais implicitement une protection ;
- l'ajout d'un serveur à une protection existante est séparé de la création de
  cette protection ;
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

Configuration déclarative du serveur Veeam Backup & Replication et de son hôte
Windows lorsque nécessaire : comptes locaux, AD/RBAC, NTP, timezone, DNS,
certificats, TLS, SMTP, syslog, audit et tests de connexion.

Artefact AAP : `veeam_conf_summary`.

#### `ansible-netbackup-conf`

Configuration déclarative d'un primary server NetBackup installé sur un OS
standard : comptes locaux, AD/LDAP, NTP, timezone, DNS, certificats, autorité
NetBackup, API, SMTP, syslog, media servers et audit de conformité.

Le playbook ne contient aucun rôle, variable ou chemin propre aux NetBackup
Appliances et refuse une cible identifiée comme appliance.

Artefact AAP : `netbackup_conf_summary`.

### Déploiement des clients et agents

#### `ansible-netbackup-client-deploy`

Déploiement et mise à niveau contrôlée du client NetBackup sur Windows ou Linux,
physique ou virtuel :

- détection de l'OS, de l'architecture et de la version installée ;
- médias provenant uniquement d'un dépôt interne approuvé ;
- installation silencieuse et fichier de réponse ;
- configuration du primary server, du nom client et des serveurs autorisés ;
- enrôlement du certificat hôte et gestion du token ;
- validation des flux sans désactivation globale du pare-feu ;
- contrôle des services, `bpclntcmd`, BPCD et identité du client ;
- modes `install`, `upgrade` et `audit` ;
- désinstallation dans une opération séparée et destructive.

La création d'une policy reste séparée.

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
- système cible explicite `windows` ou `linux` ;
- sélection d'une ou plusieurs machines déjà managées, ou d'un protection group ;
- contrôle que l'Agent est installé, compatible et joignable depuis VBR ;
- mode de sauvegarde supporté par l'OS et la version : machine entière, volumes
  ou fichiers ;
- repository DXi, StoreOnce ou autre repository Veeam déjà enregistré ;
- calendrier, fenêtre d'exécution, retries et fréquence ;
- rétention, GFS et full périodique selon les capacités du job ;
- traitement applicatif/VSS et credentials invités lorsque nécessaires ;
- chiffrement, compression, limites de débit et cache local selon support ;
- rescan préalable facultatif du protection group ;
- création idempotente et refus de modifier silencieusement un job incompatible ;
- artefact AAP : `veeam_physical_job_create_summary`.

Le projet ne déploie pas l'Agent. Il bloque avec un diagnostic exploitable si la
machine n'est pas encore gérée par `ansible-veeam-agent-deploy`.

#### `ansible-veeam-physical-job-add-server`

Ajout idempotent d'un serveur physique à un Veeam Agent backup job existant :

- résolution non ambiguë du job par identifiant ou nom exact ;
- résolution de la machine par identifiant VBR, FQDN ou nom canonique ;
- vérification que la machine appartient à un protection group ou au groupe des
  machines ajoutées manuellement ;
- contrôle que l'OS de la machine correspond au type du job ;
- refus si l'Agent n'est pas managé, obsolète, non joignable ou déjà affecté ;
- ajout direct de la machine ou ajout du protection group selon le mode demandé ;
- rescan facultatif et vérification que le serveur apparaît dans le scope final ;
- aucune modification du repository, du calendrier ou de la rétention ;
- démarrage facultatif du job dans une étape distincte ;
- artefact AAP : `veeam_physical_job_add_server_summary`.

#### `ansible-netbackup-physical-policy-create`

Création déclarative d'une policy NetBackup pour serveurs physiques :

- type `MS-Windows` pour Windows ou `Standard` pour Linux/Unix, sauf workload
  spécifique explicitement demandé ;
- nom unique, activation et attributs de policy ;
- un ou plusieurs clients NetBackup déjà installés et enrôlés ;
- validation DNS directe/inverse, nom canonique et communication avec le client ;
- backup selections adaptées à l'OS, sans valeur arbitraire non validée ;
- storage unit DXi, StoreOnce ou autre cible NetBackup déjà enregistrée ;
- schedules full, differential/cumulative incremental, fenêtres et rétention ;
- Accelerator, client-side deduplication et options BMR selon compatibilité ;
- limites de concurrence et media servers autorisés ;
- création idempotente et refus de convertir le type d'une policy existante ;
- artefact AAP : `netbackup_physical_policy_create_summary`.

Le projet ne déploie pas le client. Il dépend de
`ansible-netbackup-client-deploy` ou d'un client déjà conforme.

#### `ansible-netbackup-physical-policy-add-client`

Ajout idempotent d'un serveur physique dans une policy NetBackup existante :

- résolution non ambiguë de la policy ;
- contrôle du type de policy et de sa compatibilité avec l'OS du client ;
- validation du nom client canonique et prévention des doublons de casse ou alias ;
- vérification du certificat, de `bpclntcmd`, de BPCD et de la relation de confiance ;
- ajout du client sans modifier les schedules, backup selections, storage unit ou
  rétention ;
- refus si la policy utilise un workload ou un mode de sélection incompatible ;
- vérification finale par lecture de la liste des clients de la policy ;
- lancement facultatif d'un schedule dans une opération séparée ;
- artefact AAP : `netbackup_physical_policy_add_client_summary`.

### Opérations de sauvegarde à la demande

#### `ansible-veeam-backup-vm`

Démarrage d'un job existant ou sauvegarde rapide d'une VM unique lorsque la
plateforme et la version le permettent.

Artefact AAP : `veeam_backup_vm_summary`.

#### `ansible-netbackup-backup-vm`

Lancement manuel d'une policy VM, suivi du job et publication du status code,
de l'image produite et des octets traités.

Artefact AAP : `netbackup_backup_vm_summary`.

Une future variante `*-backup-physical` pourra déclencher un job/policy physique
existant sans créer de protection temporaire.

### Restauration complète de VM

#### `ansible-veeam-restore-vm`

Restauration VMware ou Hyper-V, originale ou alternative, avec sélection du
restore point, destination, datastore/CSV, réseau, Instant Recovery selon
support et confirmation avant écrasement.

Artefact AAP : `veeam_restore_vm_summary`.

#### `ansible-netbackup-restore-vm`

Restauration VMware ou Hyper-V en conservant les différences de capacités entre
plateformes et versions.

Artefact AAP : `netbackup_restore_vm_summary`.

### Restauration de fichiers

#### `ansible-veeam-restore-file`

Restauration granulaire Windows ou Linux, emplacement original, alternatif ou
staging, avec fermeture garantie de la session FLR.

Artefact AAP : `veeam_restore_file_summary`.

#### `ansible-netbackup-restore-file`

Restauration granulaire depuis une image VM ou physique, vers la destination
originale, alternative ou un recovery host.

Artefact AAP : `netbackup_restore_file_summary`.

## Matrice cible

| Projet | Veeam | NetBackup | VMware | Hyper-V | Physique | Destructif |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| `*-conf` | Oui | Oui | N/A | N/A | Serveur de sauvegarde | Configuration |
| `netbackup-client-deploy` | — | Oui | Invité possible | Invité possible | Oui | Installation |
| `veeam-agent-deploy` | Oui | — | Invité possible | Invité possible | Oui | Installation |
| `*-repository-dxi` / `*-storage-dxi` | Oui | Oui | N/A | N/A | Cible DXi | Configuration |
| `*-repository-storeonce` / `*-storage-storeonce` | Oui | Oui | N/A | N/A | Cible StoreOnce | Configuration |
| `veeam-job-create` / `netbackup-policy-create` | Oui | Oui | Oui | Oui | — | Création |
| `veeam-physical-job-create` | Oui | — | — | — | Windows/Linux | Création |
| `netbackup-physical-policy-create` | — | Oui | — | — | Windows/Linux | Création |
| `veeam-physical-job-add-server` | Oui | — | — | — | Windows/Linux | Modification |
| `netbackup-physical-policy-add-client` | — | Oui | — | — | Windows/Linux | Modification |
| `*-job-remove` / `*-policy-remove` | Oui | Oui | Oui | Oui | Selon projet | Oui, configuration |
| `*-backup-vm` | Oui | Oui | Oui | Selon capacités | — | Non |
| `*-restore-vm` | Oui | Oui | Oui | Modes variables | — | Oui |
| `*-restore-file` | Oui | Oui | Oui | Oui | Oui | Oui |

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

1. validation de version et découverte des capacités ;
2. TLS validé par défaut ;
3. résolution non ambiguë des serveurs, clients, agents, jobs et policies ;
4. validation de checksum et provenance des packages et plug-ins ;
5. verrou partagé sur la ressource modifiée ;
6. idempotence : un serveur déjà présent ne doit pas être ajouté une seconde fois ;
7. validation DNS directe/inverse et détection des alias/casses NetBackup ;
8. refus d'ajouter un serveur Windows dans une protection Linux, et inversement ;
9. aucune modification implicite du calendrier, de la rétention ou de la cible ;
10. journalisation sans secret et artefact `set_stats` stable ;
11. nettoyage dans un bloc `always` ;
12. modes `check`, `audit` ou `plan` lorsque possible ;
13. matrice logiciel × OS × firmware × plug-in.

## Ordre de réalisation recommandé

### Lot 1 — Configuration et découverte

1. `ansible-veeam-conf` ;
2. `ansible-netbackup-conf` ;
3. rôles de découverte et authentification.

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
15. tests d'idempotence et de compatibilité Windows/Linux.

### Lot 5 — Protection déclarative des VM

16. `ansible-veeam-job-create` et `ansible-veeam-job-remove` ;
17. `ansible-netbackup-policy-create` et `ansible-netbackup-policy-remove` ;
18. intégration facultative à `createvm` et `deletevm`.

### Lot 6 — Exécution à la demande

19. `ansible-veeam-backup-vm` ;
20. `ansible-netbackup-backup-vm` ;
21. future variante de sauvegarde à la demande d'un physique ;
22. préflight partagé « dernière sauvegarde valide ».

### Lot 7 — Restauration

23. `ansible-veeam-restore-vm` ;
24. `ansible-netbackup-restore-vm` ;
25. `ansible-veeam-restore-file` ;
26. `ansible-netbackup-restore-file`.

## Intégration AAP / ServiceNow

Chaque brique expose un Job Template distinct pour séparer les droits :

- configuration ;
- déploiement ou upgrade d'un client/agent ;
- intégration d'une cible ;
- création d'une protection physique ;
- ajout d'un serveur à une protection existante ;
- création/suppression d'une protection VM ;
- sauvegarde à la demande ;
- restauration complète ou fichier.

Le workflow ServiceNow récupère le provider, le serveur, l'OS, la cible et la
protection depuis la CMDB. Il ne doit pas déduire le nom canonique d'un client
NetBackup ou modifier un job Veeam uniquement à partir d'un nom libre saisi par
l'utilisateur.

## Validation attendue

- tests unitaires des payloads REST, cmdlets, fichiers de réponse et commandes ;
- mocks des API et changements de version ;
- tests d'idempotence de création et d'ajout de serveur ;
- tests des doublons FQDN/nom court/casse ;
- tests d'ajout Windows/Linux dans un job ou une policy incompatible ;
- tests d'installation et de mise à niveau des clients ;
- tests OST/Catalyst multi-media-server ;
- machines physiques de test Windows et Linux ;
- test périodique de sauvegarde puis restauration ;
- matrice publiée Veeam/NetBackup, DXi/StoreOnce, OS, plug-ins et plateformes.
