# Roadmap d'automatisation — réconciliation ServiceNow et détection d'orphelins

Ce document complète [`SERVICENOW-CMDB-ROADMAP.md`](SERVICENOW-CMDB-ROADMAP.md).
La première roadmap synchronise l'identité réseau des VM. Celle-ci couvre les
contrôles de cohérence entre les CI ServiceNow et les systèmes techniques, ainsi
que la détection des objets qui subsistent après le retrait d'un serveur.

Le périmètre est volontairement orienté **audit, correction CMDB contrôlée et
reporting par mail**. Aucun objet AD, WSUS, SCCM, EDR, Centreon ou Pure Storage
n'est supprimé automatiquement.

## Principes communs

- ServiceNow fournit le périmètre des CI à contrôler et leur `sys_id` ;
- les statuts « actif » et « retiré » sont définis par des requêtes configurables,
  sans coder en dur une valeur de `install_status` ou de lifecycle locale ;
- une période de grâce après le retrait évite de signaler un décommissionnement
  encore en cours ;
- la corrélation utilise d'abord les identifiants stables, puis le FQDN et enfin
  le nom court uniquement lorsqu'il est unique ;
- aucune correspondance floue ou partielle ne déclenche une mutation ;
- les résultats distinguent `matched`, `not_found`, `ambiguous`, `unreachable`,
  `still_present`, `stale` et `error` ;
- toutes les connexions sont en lecture seule, sauf la correction explicite des
  attributs VM/physique dans ServiceNow ;
- les mises à jour CMDB passent par l'Identification and Reconciliation Engine
  (IRE) et respectent les règles d'autorité par attribut ;
- aucun secret dans Git, les logs, les rapports, les pièces jointes ou `set_stats` ;
- chaque contrôle publie un artefact JSON stable et peut générer CSV, HTML et mail ;
- les rapports contenant l'inventaire du parc sont envoyés uniquement à des
  destinataires allowlistés via un relais SMTP interne en TLS ;
- aucun job ne transforme automatiquement un constat en suppression technique.

## Modèle commun de sélection et de corrélation

### Sélection des CI

Deux scopes sont prévus :

- `active_server_ci_query` pour les contrôles de classification VM/physique ;
- `retired_server_ci_query` pour les contrôles de résidus de décommissionnement.

La requête ServiceNow doit être validée avant exécution et peut s'appuyer sur les
champs locaux de lifecycle, classe, environnement, société, support group ou date
de retrait. Une variable `retirement_grace_days` exclut les CI retirés trop
récemment.

### Identifiants de corrélation

Ordre commun proposé :

1. `sys_id` ServiceNow et identifiant natif déjà stocké pour l'intégration ;
2. numéro de série, BIOS UUID, Instance UUID, VM GUID ou autre identifiant stable ;
3. FQDN normalisé ;
4. nom court accompagné du domaine et uniquement s'il est unique ;
5. adresse IP uniquement comme indice secondaire, jamais comme clé unique globale.

Chaque connecteur publie la méthode de correspondance utilisée et un score de
confiance explicable. Les doublons ou collisions produisent `ambiguous` et ne
sont jamais résolus arbitrairement.

---

## Classification physique ou virtuelle

### `ansible-servicenow-ci-platform-reconcile`

Le projet se connecte directement aux CI serveurs actifs via SSH ou WinRM afin de
déterminer si le système exécuté est physique ou virtuel, puis de corriger les
cases ServiceNow configurées pour « serveur physique » et « serveur virtuel ».

Il ne change pas la classe du CI et ne crée pas automatiquement de VM Instance.
Les noms des deux champs sont fournis par variables, car ces cases peuvent être
des attributs personnalisés du modèle CMDB local.

### Collecte Windows via WinRM

- connexion WinRM HTTPS privilégiée ;
- lecture de `Win32_ComputerSystem` : constructeur, modèle et
  `HypervisorPresent` ;
- lecture de `Win32_ComputerSystemProduct` : vendor, produit et UUID SMBIOS ;
- lecture du BIOS et du type de châssis lorsque nécessaire ;
- détection des signatures VMware, Hyper-V, KVM, Nutanix, Xen, VirtualBox et des
  principaux clouds selon une table versionnée ;
- détection du rôle Hyper-V afin de ne pas classer un hôte Hyper-V physique comme
  VM uniquement parce que `HypervisorPresent=true` ;
- comparaison facultative avec les identifiants vCenter/SCVMM déjà présents dans
  la CMDB ;
- aucune collecte ou synchronisation de la version de l'OS.

### Collecte Linux via SSH

- exécution prioritaire de `systemd-detect-virt --vm` lorsque disponible ;
- lecture en repli de `/sys/class/dmi/id/sys_vendor`, `product_name`,
  `product_uuid`, `board_vendor` et du type de châssis ;
- détection des environnements VMware, Hyper-V, KVM/QEMU, Xen, Nutanix et cloud ;
- prise en compte des conteneurs : un conteneur n'est pas reclassé comme serveur
  virtuel sans règle CMDB explicite ;
- détection des résultats contradictoires ou insuffisants ;
- aucune collecte ou synchronisation de la version de l'OS.

### Décision et mutation ServiceNow

Le moteur publie :

- `detected_platform_type: physical | virtual | container | ambiguous | unknown` ;
- les preuves utilisées et leur niveau de confiance ;
- la valeur actuelle des deux cases ServiceNow ;
- la valeur proposée et le diff IRE.

Une mise à jour n'est autorisée que si :

- le CI est résolu sans ambiguïté ;
- la connexion SSH/WinRM et les commandes de détection ont réussi ;
- le résultat est `physical` ou `virtual` avec confiance supérieure au seuil ;
- les deux champs CMDB configurés existent et sont autorisés pour la source IRE ;
- `servicenow_apply_platform_classification=true`.

Les deux cases sont mutuellement exclusives. Un résultat ambigu, un hôte
injoignable ou une preuve contradictoire produit uniquement un rapport.

Artefact AAP : `servicenow_ci_platform_reconcile_summary`.

---

## Audit Pure Storage depuis la CMDB

### `ansible-servicenow-purestorage-host-audit`

Le projet compare les CI serveurs ServiceNow aux objets hosts et host groups de
chaque FlashArray déclarée, puis remonte les incohérences sans modifier la baie.

Contrôles proposés :

- résolution des objets Pure par nom, WWPN, IQN, NQN et identifiants CMDB lorsque
  disponibles ;
- inventaire des initiateurs FC, iSCSI et NVMe ;
- distinction entre connexion directe host-volume et connexion héritée d'un
  host group ;
- détection d'un host Pure sans aucune connexion effective ;
- distinction `without_connection_without_volume` et
  `without_direct_connection_but_connected_via_hostgroup` ;
- détection d'un host sans initiateur, correspondant à un objet vide ;
- détection d'un host ou host group correspondant à un CI retiré ou absent de la
  CMDB ;
- remontée prioritaire des CI retirés ayant encore des volumes connectés ;
- liste des volumes, LUN, host groups et protocoles associés ;
- détection des noms en doublon entre baies ;
- aucune déconnexion, suppression de host, retrait de host group ou destruction
  de volume.

Catégories de rapport :

- host actif et connecté ;
- host actif mais sans connexion ;
- host présent sans volume ;
- host retiré mais encore connecté à un ou plusieurs volumes ;
- host retiré et vide, candidat potentiel au nettoyage manuel ;
- host Pure sans CI correspondant ;
- correspondance ambiguë.

Artefact AAP : `servicenow_purestorage_host_audit_summary`.

---

## Audits des CI retirés encore présents dans les outils

Tous les projets suivants prennent en entrée le même snapshot de CI retirés. Ils
produisent un rapport et n'effectuent aucune suppression.

### `ansible-servicenow-ad-retired-ci-audit`

Recherche les objets ordinateur Active Directory correspondant aux CI retirés :

- résolution par objectGUID/source native key lorsqu'il est connu, puis FQDN et
  nom SAM exact ;
- recherche dans les domaines et forêts explicitement déclarés ;
- remontée de l'état `Enabled` sans filtrer les comptes désactivés ;
- DN/OU, domaine, date de création/modification, `pwdLastSet`,
  `lastLogonTimestamp` et SPN à titre d'audit ;
- distinction objet présent et activé, présent mais désactivé, ambigu ou absent ;
- détection des objets présents dans plusieurs domaines ;
- aucune désactivation, suppression ou déplacement d'OU.

Artefact AAP : `servicenow_ad_retired_ci_audit_summary`.

### `ansible-servicenow-wsus-retired-ci-audit`

Recherche les CI retirés dans les computer targets WSUS :

- interrogation de chaque serveur WSUS déclaré via l'API UpdateServices ;
- résolution par target ID lorsqu'il est connu, FQDN et nom exact ;
- groupes WSUS, dernière synchronisation, dernier status report, adresse observée
  et version de l'agent Windows Update en audit ;
- détection de plusieurs objets WSUS pour la même machine ;
- distinction présent récemment, présent mais stale, ambigu ou absent ;
- aucune suppression du computer target ni modification de groupe/approval.

Artefact AAP : `servicenow_wsus_retired_ci_audit_summary`.

### `ansible-servicenow-sccm-retired-ci-audit`

Recherche les CI retirés dans Microsoft Configuration Manager :

- interrogation du SMS Provider avec le module PowerShell ConfigurationManager ;
- résolution par ResourceID, SMS Unique Identifier, SMBIOS GUID, FQDN ou nom exact ;
- remontée de l'état client, actif/inactif, dernière activité, heartbeat, découverte
  et collections principales ;
- détection des enregistrements obsolètes, doublons ou conflits de nom ;
- distinction ressource présente avec client actif, présente mais inactive,
  obsolète, ambiguë ou absente ;
- aucune suppression de device, collection membership ou client SCCM.

Artefact AAP : `servicenow_sccm_retired_ci_audit_summary`.

### `ansible-servicenow-trellix-retired-ci-audit`

Recherche les CI retirés dans Trellix ePolicy Orchestrator :

- backend initial `trellix_epo`, avec découverte de version et des capacités API ;
- utilisation des Web APIs et requêtes supportées par la version ePO ;
- résolution par Agent GUID, nom DNS/NetBIOS, adresse MAC et identifiants connus ;
- remontée du statut managé, dernière communication, groupe ePO, tags, adresse IP,
  version de l'agent et produits de sécurité présents ;
- distinction agent communiquant encore, agent stale, objet non managé, ambigu ou
  absent ;
- endpoints et noms de requêtes définis dans un profil validé par version lorsque
  l'API ePO diffère ;
- aucune suppression de système, tag, groupe ou agent.

Artefact AAP : `servicenow_trellix_retired_ci_audit_summary`.

### `ansible-servicenow-trend-retired-ci-audit`

Recherche les CI retirés dans les plateformes Trend Micro déclarées :

- backends séparés `trend_vision_one` et `trend_apex_central` ;
- découverte de version et de disponibilité des APIs avant interrogation ;
- résolution par endpoint/agent GUID, nom, FQDN, MAC et identifiants disponibles ;
- remontée du produit gestionnaire, état de l'agent/sensor, dernière communication,
  groupe, adresse IP et version du composant ;
- gestion de la pagination, des limites de taux et des endpoints régionaux pour
  Trend Vision One ;
- profil d'API versionné pour Apex Central lorsque nécessaire ;
- distinction endpoint encore actif, stale, ambigu ou absent ;
- aucune isolation, désinstallation ou suppression d'endpoint.

Artefact AAP : `servicenow_trend_retired_ci_audit_summary`.

### `ansible-servicenow-centreon-retired-ci-audit`

Recherche les CI retirés dans la configuration et les données runtime Centreon :

- interrogation de l'API de configuration supportée, REST ou CLAPI selon version ;
- résolution par host ID, nom exact, alias, FQDN ou adresse comme indice secondaire ;
- remontée du poller, adresse, état activé/désactivé, templates et host groups ;
- inventaire des services liés, downtimes, acknowledgements et dépendances ;
- récupération facultative du dernier contrôle et du dernier état runtime ;
- distinction hôte encore supervisé activement, configuré mais désactivé,
  non déployé, ambigu ou absent ;
- aucune suppression d'hôte/service et aucune application de configuration.

Artefact AAP : `servicenow_centreon_retired_ci_audit_summary`.

---

## Rapport consolidé et envoi par mail

### `ansible-servicenow-retired-ci-audit-report`

Ce projet agrège les artefacts des audits AD, WSUS, SCCM, Trellix, Trend,
Centreon et Pure Storage pour produire une vue par CI et une vue par outil.

Formats :

- résumé HTML dans le corps du mail ;
- CSV détaillé par source ;
- JSON complet pour archivage AAP/ServiceNow ;
- fichier consolidé avec une ligne par couple CI × système technique.

Le rapport met en avant :

- CI retirés encore actifs dans au moins un outil ;
- CI retirés présents mais désactivés/stale ;
- CI retirés encore connectés à du stockage ;
- objets techniques sans CI correspondant ;
- correspondances ambiguës et doublons ;
- erreurs de connexion ou APIs non disponibles ;
- ancienneté du retrait et dernière activité observée.

Politique mail :

- destinataires et domaines allowlistés ;
- relais SMTP interne avec STARTTLS/TLS et Credential AAP ;
- sujet comprenant environnement, date et nombre d'écarts critiques ;
- aucun token, mot de passe, communauté ou payload API brut ;
- taille maximale de pièces jointes et compression facultative ;
- possibilité d'envoyer un mail par source ou un seul rapport consolidé ;
- option `mail_only_on_findings=true` ;
- conservation du rapport comme artefact même lorsque le mail échoue.

Artefact AAP : `servicenow_retired_ci_audit_report_summary`.

## Variables proposées

```yaml
servicenow_instance: https://example.service-now.com
servicenow_validate_certs: true
servicenow_ire_source_name: Ansible CMDB Reconciliation
servicenow_operation: audit  # collect | audit | plan | reconcile

active_server_ci_query: null
retired_server_ci_query: null
retirement_grace_days: 7
ci_batch_size: 100
fail_on_ambiguous_ci: true

servicenow_physical_server_field: u_physical_server
servicenow_virtual_server_field: u_virtual_server
servicenow_apply_platform_classification: false
platform_detection_min_confidence: 90
allow_container_classification: false

winrm_transport: credssp
winrm_use_https: true
ssh_host_key_checking: true
connection_timeout_seconds: 30

pure_arrays: []
pure_report_hosts_without_connections: true
pure_report_retired_hosts_with_volumes: true
pure_include_hostgroup_connections: true

ad_domains: []
ad_include_enabled: true
ad_include_disabled: true

wsus_servers: []
wsus_stale_days: 30

sccm_site_code: null
sccm_provider: null
sccm_inactive_days: 30

trellix_backend: trellix_epo
trellix_epo_url: null
trellix_stale_days: 30

trend_backend: trend_vision_one  # trend_vision_one | trend_apex_central
trend_api_url: null
trend_region: eu
trend_stale_days: 30

centreon_url: null
centreon_api_mode: auto
centreon_validate_certs: true

report_formats:
  - html
  - csv
  - json
mail_enabled: true
mail_only_on_findings: true
mail_relay: smtp.example.net
mail_port: 587
mail_starttls: true
mail_from: aap-reports@example.net
mail_recipients: []
mail_allowed_domains: []
mail_subject_prefix: "[CMDB reconciliation]"
mail_attach_detailed_reports: true
```

## Garde-fous

1. requêtes ServiceNow de scope explicitement fournies et journalisées ;
2. période de grâce après retrait ;
3. snapshot des CI figé au début du run ;
4. aucune correspondance floue ;
5. aucune mutation hors des deux attributs VM/physique explicitement déclarés ;
6. mutation VM/physique via IRE et seulement avec confiance élevée ;
7. aucun changement technique dans les outils audités ;
8. comptes/API en lecture seule pour Pure, AD, WSUS, SCCM, Trellix, Trend et Centreon ;
9. timeouts, pagination et limites de lots ;
10. un échec d'un connecteur n'empêche pas les autres rapports de terminer ;
11. distinction `not_found` et `not_checked` ;
12. conservation de la valeur brute et de la méthode de corrélation dans l'artefact ;
13. rapports sans secrets et destinataires allowlistés ;
14. aucun effacement automatique basé sur le seul résultat d'un audit ;
15. artefacts horodatés, checksumés et conservés selon la politique AAP ;
16. nettoyage des fichiers temporaires dans un bloc `always`.

## Intégration AAP / ServiceNow

Job Templates distincts :

- classification VM/physique en audit ;
- réconciliation VM/physique avec approbation ;
- audit Pure Storage ;
- audit AD des CI retirés ;
- audit WSUS des CI retirés ;
- audit SCCM des CI retirés ;
- audit Trellix des CI retirés ;
- audit Trend des CI retirés ;
- audit Centreon des CI retirés ;
- agrégation et envoi du rapport.

Workflow périodique recommandé :

1. extraction figée des CI retirés hors période de grâce ;
2. lancement parallèle des connecteurs en lecture seule ;
3. collecte de tous les artefacts même en cas d'échec partiel ;
4. agrégation par CI ;
5. envoi du rapport HTML/CSV ;
6. archivage du JSON et retour du statut dans AAP/ServiceNow.

## Ordre de réalisation recommandé

1. modèle commun de CI, corrélation et reporting ;
2. `ansible-servicenow-ci-platform-reconcile` en mode audit ;
3. AD, WSUS, SCCM et Centreon ;
4. Pure Storage avec connexions directes et host groups ;
5. Trellix ePO ;
6. Trend Vision One puis Apex Central selon le parc ;
7. agrégateur HTML/CSV/mail ;
8. activation contrôlée de la correction VM/physique via IRE ;
9. exécution par lots, reprise et planification AAP.

## Validation attendue

- tests de détection physique/VM sur serveurs physiques, VMware, Hyper-V, KVM et
  hôte Hyper-V physique ;
- tests de résultats `ambiguous` et `unreachable` sans mutation ;
- tests IRE avec champs personnalisés et règles de réconciliation ;
- tests de corrélation FQDN, UUID/GUID, doublons et domaines multiples ;
- tests Pure avec connexion directe, host group, host vide et volume encore connecté ;
- tests AD activé/désactivé ;
- tests WSUS/SCCM actif, stale, doublon et absent ;
- mocks et environnements de test Trellix/Trend par backend ;
- tests Centreon configuration/runtime ;
- tests d'échec partiel et génération du rapport consolidé ;
- tests SMTP TLS, allowlist de destinataires et pièces jointes volumineuses ;
- preuve qu'aucun audit n'exécute d'action de suppression.