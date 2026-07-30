# ansible-sql-server-install

Installation, audit ou réparation contrôlée d'une instance **Microsoft SQL
Server standalone** sur Windows Server, via le mécanisme d'installation
silencieuse natif de `setup.exe` (`/ConfigurationFile`), sur WinRM. Le
projet suit la méthodologie du dépôt : inventaire sans appliance
statique, préflight bloquant, secrets Vault/AAP, rôles séparés et
artefact `set_stats`.

Ce projet est la première brique de
[`SQL-SERVER-ROADMAP.md`](../SQL-SERVER-ROADMAP.md) (étapes 1-2 de son
« ordre de réalisation recommandé » : audit des prérequis et installation
d'une instance standalone Database Engine).

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : installation (`sql_server_operation: install`), audit en
lecture seule (`audit`) et réparation (`repair`, nécessite
`confirm_sql_server_repair: true`) d'une instance standalone ; comptes de
service (virtuels/gMSA/domaine), comptes sysadmin initiaux,
authentification Windows ou mixte, collation, répertoires de données/
logs/sauvegarde/TempDB, port TCP statique, pare-feu scopé aux sources
déclarées, mémoire min/max lorsque explicitement fournie, CU approuvé en
option (jamais téléchargé automatiquement).

**Non couvert, volontairement** (voir
[`SQL-SERVER-ROADMAP.md`](../SQL-SERVER-ROADMAP.md)) :

- Failover Cluster Instances et Always On Availability Groups (projets
  séparés à venir : `ansible-sql-server-fci-install`,
  `ansible-sql-server-alwayson-conf`) ;
- patch récurrent et rolling update de CU (`ansible-sql-server-cu-update`) ;
- création/restauration/migration de bases, logins applicatifs,
  permissions, jobs SQL Agent, plans de maintenance ;
- sauvegarde native SQL Server et intégration Veeam/NetBackup applicative
  (voir `ansible-veeam-conf`/`ansible-netbackup-conf` pour la
  configuration du serveur de sauvegarde lui-même) ;
- `mode: add_features` est accepté par le préflight/la génération du
  `ConfigurationFile.ini`, mais n'a pas encore de test dédié - traiter
  comme non validé tant qu'il n'a pas été exercé sur une instance jetable ;
- dimensionnement `auto` de TempDB/mémoire (le nombre de fichiers TempDB
  et la mémoire min/max acceptent uniquement des valeurs entières
  explicites dans cette première version, pas encore de calcul basé sur
  le nombre de cœurs).

## `setup.exe` plutôt qu'une collection : pourquoi, et ce qui est fiable

Aucune collection Ansible maintenue ne couvre l'installation SQL Server -
ce projet invoque directement `setup.exe` avec son fichier
`ConfigurationFile.ini` et des switches en ligne de commande, un mécanisme
Microsoft documenté et stable depuis de nombreuses versions (contrairement
à une API REST propriétaire qui change par version, ce contrat
`ConfigurationFile.ini` a une bien plus grande stabilité historique - noté
ici car ce dépôt distingue explicitement les deux niveaux de confiance,
voir `ansible-veeam-conf`/`ansible-netbackup-conf` pour l'autre cas de
figure).

- **Aucun secret n'est écrit dans `ConfigurationFile.ini`** : les mots de
  passe de comptes de service, le mot de passe `sa` et le PID sont ajoutés
  en tant que switches de ligne de commande séparés
  (`/SQLSVCPASSWORD`, `/AGTSVCPASSWORD`, `/SAPWD`, `/PID`), sur un
  `ansible.windows.win_command` en `argv` (pas de concaténation de
  chaîne, pas de risque d'injection) et en `no_log`. Le fichier `.ini`
  temporaire est supprimé après l'installation.
- **Code retour 3010** (succès, redémarrage requis - convention Windows
  Installer standard) est traité comme un succès mais **ne déclenche
  jamais de redémarrage** (`allow_reboot: false` toujours respecté) :
  publié dans `sql_server_install_summary.reboot_required` pour qu'une
  action de maintenance séparée s'en charge.
- **Port TCP statique** : `setup.exe` n'expose pas de switch pour figer un
  port TCP non standard - c'est positionné après l'installation via la clé
  de registre documentée
  `HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\<instance>\MSSQLSERVER\SuperSocketNetLib\Tcp\IPAll`
  (méthode Microsoft de longue date, KB823938 et suivantes), puis le
  service est redémarré uniquement si la valeur a changé.
- **Vérification post-installation** : état du service via
  `ansible.windows.win_service_info`, puis `SELECT @@VERSION` via
  `sqlcmd` (livré avec le moteur, pas de dépendance supplémentaire).

## Médias et CU

`sql_server_media_path`/`sql_server_media_checksum` (SHA256) sont
obligatoires hors mode `audit` : le rôle `stage_media` calcule le hash du
fichier sur le partage et refuse de continuer s'il ne correspond pas -
aucun téléchargement, aucune copie locale, aucun montage d'ISO. Un CU
(`sql_server_update_enabled: false` par défaut) suit la même règle
(checksum obligatoire) et n'est jamais récupéré automatiquement depuis
Internet.

## Comptes de service et sysadmin

`sql_server_engine_service_account`/`sql_server_agent_service_account`
acceptent un compte virtuel (`NT SERVICE\...`), un gMSA (se terminant par
`$`) ou un compte de domaine - le mot de passe n'est requis que dans ce
dernier cas (le préflight le vérifie). Au moins un compte sysadmin est
obligatoire (`sql_server_sysadmin_accounts`).

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
credentials WinRM, les mots de passe de comptes de service, le mot de
passe `sa` (mode mixte) et le PID. Toutes les tâches sensibles sont en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/install_sql_server.yml --vault-password-file .vault_pass
```

Tester d'abord sur une instance jetable. Le mode `repair` nécessite
`confirm_sql_server_repair: true`. Le résultat `sql_server_install_summary`
est récupérable par AAP et ServiceNow sans exposer les secrets.
