# Roadmap d'automatisation SQL Server

Ce document décrit une première brique autonome d'installation de Microsoft SQL
Server sur Windows Server. Le périmètre initial couvre les instances standalone.
Les Failover Cluster Instances, Always On Availability Groups et migrations de
bases seront traités dans des projets distincts afin de ne pas masquer leur
complexité derrière un simple mode d'installation.

## Principes

- installation silencieuse avec `setup.exe` et fichier de configuration validé ;
- médias provenant uniquement d'un dépôt interne approuvé ;
- version, édition, CU et composants allowlistés ;
- aucun mot de passe ou PID dans Git, `group_vars`, les logs ou les artefacts ;
- comptes de service fournis via Credential AAP ou gMSA ;
- installation distincte de la création des bases et de leur restauration ;
- configuration Day-1 limitée aux paramètres nécessaires à une instance saine ;
- aucune ouverture générale du pare-feu ;
- redémarrage système interdit par défaut ;
- artefact `set_stats` stable pour AAP/ServiceNow.

## Catalogue cible

### `ansible-sql-server-install`

Installation, audit, réparation ou mise à niveau contrôlée d'une instance SQL
Server standalone sur Windows Server :

- détection de l'OS, de l'architecture, des prérequis et des instances existantes ;
- validation de la compatibilité version SQL Server × Windows Server ;
- montage ou copie temporaire du média d'installation ;
- validation de checksum et de signature ;
- génération d'un `ConfigurationFile.ini` temporaire sans secret persistant ;
- modes `install`, `audit`, `repair` et `add_features` séparés ;
- refus de convertir silencieusement une édition ou un nom d'instance existant ;
- instance par défaut ou nommée ;
- allowlist des features : Database Engine, Replication, Full-Text, Analysis
  Services, Integration Services et composants partagés réellement nécessaires ;
- édition et PID fournis via Credential, ou édition Developer/Evaluation
  explicitement autorisée hors production ;
- comptes SQL Server Engine, SQL Server Agent et services additionnels ;
- support des comptes virtuels, comptes de domaine et gMSA ;
- groupes/comptes sysadmin initiaux déclarés ;
- mode d'authentification Windows ou mixte avec secret `sa` protégé ;
- collation serveur déclarative ;
- répertoires binaires, données, logs, sauvegardes et TempDB ;
- nombre, taille initiale et croissance des fichiers TempDB ;
- activation contrôlée de TCP/IP, port statique et SQL Browser ;
- règles de pare-feu limitées aux réseaux et ports déclarés ;
- configuration de la mémoire maximale et minimale ;
- degré de parallélisme et seuil de coût uniquement lorsqu'ils sont explicitement
  fournis par un profil de référence ;
- activation et démarrage du SQL Server Agent ;
- TLS et certificat serveur dans un mode post-install explicite ;
- installation intégrée d'un CU approuvé ou slipstream lorsque le média et la
  version le permettent ;
- refus de télécharger automatiquement le dernier CU depuis Internet ;
- contrôle des codes retour du Setup et collecte des journaux d'installation ;
- vérification des services, du port, de `SELECT @@VERSION`, de l'édition et des
  features installées ;
- suppression des médias, fichiers INI et secrets temporaires dans un bloc
  `always`.

Artefact AAP : `sql_server_install_summary`.

## Hors périmètre initial

Les sujets suivants nécessitent des projets autonomes futurs :

- `ansible-sql-server-fci-install` pour une Failover Cluster Instance ;
- `ansible-sql-server-alwayson-conf` pour les Availability Groups ;
- `ansible-sql-server-cu-update` pour le patch récurrent et le rolling update ;
- création/restauration/migration de bases ;
- logins applicatifs, permissions, jobs SQL Agent et plans de maintenance ;
- sauvegarde native SQL Server et intégration Veeam/NetBackup applicative.

## Variables proposées

```yaml
sql_server_operation: install  # install | audit | repair | add_features
sql_server_version: 2022
sql_server_edition: standard
sql_server_instance_name: MSSQLSERVER
sql_server_features:
  - SQLENGINE

sql_server_media_path: \\repo.example.net\software\sqlserver\2022
sql_server_media_checksum: null
sql_server_update_enabled: true
sql_server_update_source: \\repo.example.net\software\sqlserver\2022\cu-approved

sql_server_engine_service_account: null
sql_server_agent_service_account: null
sql_server_sysadmin_accounts: []
sql_server_authentication_mode: windows  # windows | mixed

sql_server_collation: Latin1_General_100_CI_AS_SC
sql_server_data_dir: D:\\MSSQL\\DATA
sql_server_log_dir: E:\\MSSQL\\LOG
sql_server_backup_dir: F:\\MSSQL\\BACKUP
sql_server_tempdb_dir: T:\\MSSQL\\TEMPDB
sql_server_tempdb_file_count: auto

sql_server_tcp_enabled: true
sql_server_tcp_port: 1433
sql_server_browser_enabled: false
sql_server_firewall_sources: []

sql_server_max_memory_mb: auto
sql_server_min_memory_mb: 0
allow_reboot: false
confirm_sql_server_repair: false
```

Les mots de passe de services, le mot de passe `sa`, le PID et les clés privées
sont fournis via Credential AAP, Ansible Vault ou un gestionnaire de secrets.

## Garde-fous

1. validation version SQL Server × Windows Server ;
2. médias approuvés, checksum et signature ;
3. aucun secret dans le fichier INI persisté, les logs ou `set_stats` ;
4. détection non ambiguë de l'instance par nom, InstanceID et services ;
5. refus d'un downgrade ou changement d'édition implicite ;
6. refus de modifier une instance existante en mode `install` ;
7. features allowlistées ;
8. répertoires et volumes validés avant installation ;
9. comptes de service validés sans journaliser leurs secrets ;
10. port et pare-feu limités au besoin déclaré ;
11. redémarrage système explicite seulement ;
12. rollback limité au nettoyage de l'installation incomplète, sans suppression
    automatique d'une instance préexistante ;
13. publication des chemins des logs Setup dans l'artefact ;
14. nettoyage des médias et fichiers temporaires dans un bloc `always` ;
15. matrice SQL Server × Windows Server × édition × CU publiée et testée.

## Intégration AAP / ServiceNow

Le projet expose des Job Templates distincts pour :

- audit/préflight ;
- installation d'une nouvelle instance ;
- ajout de features ;
- réparation avec approbation.

La demande ServiceNow fournit le serveur, la version, l'édition, le nom
d'instance, le profil de stockage, les comptes de service et les groupes
sysadmin. Les secrets restent des Credentials AAP.

## Ordre de réalisation recommandé

1. audit des prérequis et inventaire des instances ;
2. installation d'une instance standalone Database Engine ;
3. profils de répertoires, TempDB, mémoire, réseau et pare-feu ;
4. comptes de service de domaine/gMSA ;
5. CU approuvé et validation post-install ;
6. modes `repair` et `add_features` ;
7. future séparation FCI, Always On et patch récurrent.

## Validation attendue

- tests unitaires de génération du fichier de configuration ;
- tests garantissant l'absence de secrets dans les artefacts ;
- installation idempotente d'une instance par défaut et nommée ;
- tests Standard/Enterprise/Developer selon les licences disponibles ;
- tests des comptes virtuels, domaine et gMSA ;
- tests des chemins de données séparés et de TempDB ;
- tests de CU approuvé, code retour Setup et redémarrage requis ;
- machine Windows Server jetable par version supportée ;
- matrice publiée SQL Server × Windows Server × CU.
