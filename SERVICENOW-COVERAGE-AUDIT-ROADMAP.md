# Roadmap d'automatisation — couverture des CI actifs et résidus de virtualisation

Ce document complète :

- [`SERVICENOW-RECONCILIATION-ROADMAP.md`](SERVICENOW-RECONCILIATION-ROADMAP.md) ;
- [`SERVICENOW-SATELLITE-AUDIT-ROADMAP.md`](SERVICENOW-SATELLITE-AUDIT-ROADMAP.md) ;
- [`VEEAM-NETBACKUP-ROADMAP.md`](VEEAM-NETBACKUP-ROADMAP.md).

Il couvre deux contrôles complémentaires :

1. détecter les CI retirés encore présents dans VMware ou Hyper-V ;
2. détecter les CI actifs qui ne sont pas couverts par les outils obligatoires,
   les sauvegardes ou le DNS attendu.

Tous les projets sont autonomes et en lecture seule. Ils produisent des artefacts
AAP exploitables par ServiceNow et par les rapports consolidés.

## Principes communs

- ServiceNow fournit un snapshot figé des CI actifs ou retirés et leur `sys_id` ;
- les requêtes de scope et la période de grâce sont configurables ;
- la corrélation privilégie UUID/GUID, identifiants natifs, numéro de série et FQDN ;
- le nom court et l'adresse IP ne sont jamais utilisés seuls en cas d'ambiguïté ;
- aucun objet n'est supprimé, arrêté, désactivé, déplacé ou ajouté à une policy ;
- un CI actif n'est contrôlé que contre les outils déclarés obligatoires pour son
  profil de gestion ;
- les résultats distinguent `present`, `expected_missing`, `not_expected`,
  `stale`, `ambiguous`, `not_checked` et `error` ;
- l'appartenance effective à une protection est recherchée, y compris lorsqu'elle
  est héritée d'un conteneur, d'un groupe, d'un tag ou d'une règle dynamique ;
- l'existence d'une policy/job et l'existence d'une sauvegarde restaurable sont
  deux contrôles distincts ;
- chaque projet publie JSON, CSV facultatif et statistiques agrégables ;
- aucun secret ou payload API brut dans les logs, mails ou `set_stats`.

## Matrice d'applicabilité des CI actifs

Une absence ne constitue un écart que si l'outil est attendu pour le CI. Cette
attente est déterminée à partir de règles explicites basées sur les attributs
ServiceNow :

- classe de CI ;
- environnement ;
- plateforme ou famille technique connue dans la CMDB ;
- groupe de support ;
- société ou domaine de gestion ;
- criticité et profil de sauvegarde ;
- champs locaux indiquant les outils obligatoires ;
- exceptions datées et approuvées.

Exemple de politique :

```yaml
coverage_profiles:
  windows_server:
    required_tools:
      - centreon
      - sccm
      - wsus
      - endpoint_security
      - backup
  linux_rhel:
    required_tools:
      - centreon
      - satellite
      - endpoint_security
      - backup
```

Le profil réellement utilisé est publié dans chaque ligne de résultat. Une règle
absente ou contradictoire produit `coverage_profile_ambiguous` et non un faux
positif.

---

# CI retirés encore présents dans la virtualisation

## `ansible-servicenow-vmware-retired-ci-audit`

Compare les CI retirés aux VM encore enregistrées dans les vCenter déclarés.

Contrôles :

- résolution par Instance UUID, BIOS UUID, MoRef stocké, FQDN puis nom exact ;
- détection de la même VM dans plusieurs vCenter ;
- présence de la VM, template, objet inaccessible ou orphelin ;
- power state et état de connexion ;
- datacenter, cluster, host, resource pool, dossier et tags ;
- date de dernière activité disponible, uptime et état VMware Tools en audit ;
- snapshots existants avec âge, taille et description ;
- disques, datastores et contrôleurs encore associés ;
- cartes réseau, port groups et adresses observées ;
- règles DRS, affinités ou dépendances empêchant un nettoyage simple ;
- tâches vCenter encore actives concernant la VM ;
- détection facultative des VM sans CI correspondant.

Catégories :

- `absent_from_vcenter` ;
- `present_powered_off` ;
- `present_powered_on` ;
- `present_with_snapshots` ;
- `present_with_storage` ;
- `template_remaining` ;
- `orphaned_or_inaccessible` ;
- `duplicate_across_vcenters` ;
- `ambiguous`.

Les cas `present_powered_on` et `present_with_snapshots` sont prioritaires dans le
rapport. Aucune extinction, consolidation, suppression de snapshot ou suppression
de VM n'est réalisée.

Artefact AAP : `servicenow_vmware_retired_ci_audit_summary`.

## `ansible-servicenow-hyperv-retired-ci-audit`

Compare les CI retirés aux VM encore gérées par SCVMM et aux clusters Hyper-V
déclarés.

Contrôles :

- résolution par VM ID/GUID, identifiant SCVMM, FQDN puis nom exact ;
- rafraîchissement contrôlé de l'objet VMM avant lecture ;
- présence et état de la VM ;
- fabric, host group, cloud, cluster et nœud de résidence ;
- statut SCVMM, owner et éventuelle VM hautement disponible ;
- checkpoints avec date et taille disponible ;
- VHD/VHDX, CSV, shares SMB et chemins de stockage associés ;
- cartes réseau, logical networks, VM networks et VLAN ;
- jobs SCVMM encore actifs ou en échec sur la VM ;
- objets VMM dupliqués ou VM visibles sur plusieurs sources ;
- détection facultative des VM sans CI correspondant.

Catégories :

- `absent_from_scvmm` ;
- `present_powered_off` ;
- `present_powered_on` ;
- `present_with_checkpoints` ;
- `present_with_storage` ;
- `orphaned_or_missing_host` ;
- `duplicate` ;
- `ambiguous`.

Aucun arrêt, live migration, suppression de checkpoint, retrait SCVMM ou effacement
de VHDX n'est exécuté.

Artefact AAP : `servicenow_hyperv_retired_ci_audit_summary`.

---

# Couverture de sauvegarde des CI actifs

## `ansible-servicenow-veeam-ci-audit`

Vérifie qu'un CI actif devant être protégé par Veeam possède à la fois une
couverture effective et une sauvegarde récente exploitable.

### Couverture effective

- résolution du CI par UUID VMware/Hyper-V, identifiant de machine, FQDN et nom ;
- inventaire des jobs, policies et groupes de protection applicables ;
- prise en compte des inclusions directes et indirectes par cluster, dossier,
  resource pool, tag, host, groupe de protection ou règle dynamique ;
- traitement des exclusions explicites et des exclusions héritées ;
- détection des CI couverts par plusieurs jobs incompatibles ;
- identification du repository, proxy et mode de traitement associés en audit ;
- comparaison au profil de protection attendu dans ServiceNow.

### Sauvegarde réellement disponible

- recherche du dernier restore point ou backup object correspondant ;
- date et résultat de la dernière session réussie ;
- âge du dernier point par rapport au RPO attendu ;
- dernier échec et nombre d'échecs consécutifs ;
- chaîne de sauvegarde incomplète ou point non exploitable lorsqu'identifiable ;
- distinction entre sauvegarde VM, agent physique et protection applicative ;
- détection d'un job présent mais n'ayant jamais créé de point de restauration ;
- détection d'un restore point historique alors que le CI n'est plus couvert.

États principaux :

- `covered_and_recent_backup` ;
- `coverage_missing` ;
- `explicitly_excluded` ;
- `job_present_no_backup` ;
- `backup_never_seen` ;
- `backup_stale` ;
- `last_backup_failed` ;
- `restore_point_present_without_current_coverage` ;
- `duplicate_coverage` ;
- `not_expected` ;
- `ambiguous`.

Artefact AAP : `servicenow_veeam_ci_audit_summary`.

## `ansible-servicenow-netbackup-ci-audit`

Vérifie la couverture et l'existence d'images de sauvegarde pour les CI actifs
attendus dans NetBackup.

### Couverture effective

- résolution par client name NetBackup, FQDN, aliases, VM UUID et identifiants CMDB ;
- inventaire des policies et schedules correspondant au client ;
- prise en compte des clients explicites, sélections intelligentes, groupes et
  règles automatiques supportés par la version ;
- détection des exclusions et clients désactivés ;
- comparaison du type de policy et du schedule au profil de protection attendu ;
- détection des protections dupliquées ou de policies contradictoires.

### Images de sauvegarde

- recherche de la dernière image réussie correspondant au CI ;
- type Full, Incremental, Differential ou applicatif lorsque disponible ;
- date de dernière réussite, dernière tentative et dernier code de statut ;
- âge de l'image par rapport au RPO ;
- expiration/rétention de la dernière image ;
- distinction policy présente sans image, image historique sans policy actuelle et
  client jamais sauvegardé ;
- remontée du master/media server et storage lifecycle utilisés en audit.

États principaux :

- `covered_and_recent_backup` ;
- `coverage_missing` ;
- `client_disabled_or_excluded` ;
- `policy_present_no_backup` ;
- `backup_never_seen` ;
- `backup_stale` ;
- `last_backup_failed` ;
- `image_present_without_current_policy` ;
- `duplicate_coverage` ;
- `not_expected` ;
- `ambiguous`.

Artefact AAP : `servicenow_netbackup_ci_audit_summary`.

---

# CI actifs absents des outils obligatoires

Tous les projets suivants utilisent le même snapshot de CI actifs et la même
matrice d'applicabilité. Ils ne créent aucun objet et n'installent aucun agent.

## `ansible-servicenow-centreon-active-ci-audit`

- vérifie qu'un hôte Centreon unique correspond au CI actif attendu ;
- distingue hôte absent, désactivé, non déployé ou supervisé activement ;
- vérifie poller, adresse, templates et services minimaux attendus ;
- remonte le dernier contrôle et les états `UNKNOWN` persistants lorsqu'ils sont
  disponibles ;
- détecte les doublons de nom, FQDN ou adresse ;
- ne crée aucun host et n'applique aucune configuration.

Artefact AAP : `servicenow_centreon_active_ci_audit_summary`.

## `ansible-servicenow-sccm-active-ci-audit`

- vérifie la présence du device dans SCCM lorsque le profil l'exige ;
- contrôle ResourceID, SMBIOS GUID, état client et activité récente ;
- distingue device absent, client absent, client inactif, objet obsolète ou doublon ;
- vérifie facultativement les collections obligatoires selon le profil du CI ;
- ne déclenche aucun client push et ne modifie aucune collection.

Artefact AAP : `servicenow_sccm_active_ci_audit_summary`.

## `ansible-servicenow-wsus-active-ci-audit`

- vérifie la présence du computer target dans le ou les WSUS attendus ;
- remonte la dernière synchronisation et le dernier status report ;
- distingue absent, jamais remonté, stale, dupliqué ou présent récemment ;
- vérifie facultativement le groupe/ring attendu ;
- ne déplace aucun computer target et ne déclenche aucun patch.

Artefact AAP : `servicenow_wsus_active_ci_audit_summary`.

## `ansible-servicenow-satellite-active-ci-audit`

- vérifie l'enregistrement du host et du content host dans le Satellite attendu ;
- contrôle organisation, location, Capsule, host group, lifecycle environment et
  content view attendus ;
- remonte dernière communication, facts et identité Candlepin ;
- distingue absent, mal rattaché, inactif, dupliqué ou correctement enregistré ;
- ne réenregistre pas l'hôte et ne modifie aucun contenu.

Artefact AAP : `servicenow_satellite_active_ci_audit_summary`.

## `ansible-servicenow-trellix-active-ci-audit`

- vérifie la présence de l'endpoint attendu dans Trellix ePO ;
- contrôle Agent GUID, statut managé, dernière communication, groupe et tags ;
- distingue absent, agent non managé, stale, doublon ou actif ;
- vérifie facultativement les produits de sécurité minimaux déclarés par profil ;
- ne déploie, ne réveille et ne supprime aucun agent.

Artefact AAP : `servicenow_trellix_active_ci_audit_summary`.

## `ansible-servicenow-trend-active-ci-audit`

- supporte des backends séparés `trend_vision_one` et `trend_apex_central` ;
- vérifie endpoint GUID, état de l'agent/sensor, dernière communication et groupe ;
- distingue absent, stale, sensor désactivé, doublon ou actif ;
- vérifie facultativement les composants attendus selon le profil ;
- ne lance aucune isolation, installation ou suppression.

Artefact AAP : `servicenow_trend_active_ci_audit_summary`.

---

# Audit DNS des CI actifs et retirés

Deux projets autonomes partagent le même rôle de résolution mais conservent des
Job Templates et des artefacts distincts.

## `ansible-servicenow-dns-active-ci-audit`

Effectue des requêtes DNS de type `nslookup` pour chaque CI actif depuis un ou
plusieurs résolveurs de référence.

Contrôles :

- résolution du nom court et du FQDN ServiceNow ;
- résolution de chaque alias ou CNAME connu dans les champs configurés ;
- suivi et journalisation de la chaîne CNAME jusqu'au nom canonique ;
- collecte des réponses A et AAAA ;
- comparaison aux IP et interfaces actives connues dans la CMDB ;
- reverse lookup/PTR des IP ServiceNow et des IP résolues ;
- détection d'un alias qui pointe vers un autre CI ou vers un ancien nom ;
- détection d'un FQDN qui résout vers une IP non rattachée au CI ;
- détection d'une IP du CI dont le PTR pointe vers un autre nom ;
- exécution contre plusieurs DNS pour détecter les divergences split-horizon ou
  une réplication incomplète ;
- conservation du TTL et du résolveur ayant fourni chaque réponse lorsque possible.

États :

- `active_resolves_expected` ;
- `active_nxdomain` ;
- `active_alias_expected` ;
- `active_alias_mismatch` ;
- `active_ip_mismatch` ;
- `active_ptr_missing` ;
- `active_ptr_mismatch` ;
- `active_multiple_unexpected_ips` ;
- `split_dns_inconsistent` ;
- `ambiguous`.

Un alias n'est pas considéré comme une erreur s'il fait partie des aliases attendus
pour le CI et converge vers l'identité ou les IP autorisées.

Artefact AAP : `servicenow_dns_active_ci_audit_summary`.

## `ansible-servicenow-dns-retired-ci-audit`

Effectue les mêmes requêtes `nslookup` pour les CI retirés hors période de grâce.

Contrôles :

- nom court et FQDN encore résolus ;
- A/AAAA encore présents ;
- CNAME/aliases encore présents même lorsque le nom principal a disparu ;
- chaîne CNAME pointant vers un autre nom encore actif ;
- PTR encore présent pour les anciennes adresses ;
- enregistrements divergents entre résolveurs ;
- détection d'une IP désormais rattachée à un CI actif pour éviter de qualifier
  son enregistrement comme simple résidu ;
- distinction entre résidu DNS certain, réutilisation d'adresse et ambiguïté.

États :

- `retired_nxdomain` ;
- `retired_a_or_aaaa_remaining` ;
- `retired_alias_remaining` ;
- `retired_ptr_remaining` ;
- `retired_ip_reused_by_active_ci` ;
- `split_dns_inconsistent` ;
- `ambiguous`.

Aucun enregistrement DNS n'est supprimé.

Artefact AAP : `servicenow_dns_retired_ci_audit_summary`.

---

# Rapports consolidés

## Extension de `ansible-servicenow-retired-ci-audit-report`

Le rapport existant intègre désormais :

- les VM VMware retirées encore présentes ;
- les VM Hyper-V retirées encore présentes ;
- les noms, aliases et PTR DNS résiduels.

Les VM encore allumées, les checkpoints/snapshots et les noms DNS encore actifs
sont mis en évidence comme écarts prioritaires.

## `ansible-servicenow-active-ci-coverage-report`

Agrège les audits des CI actifs :

- Veeam et NetBackup ;
- Centreon ;
- SCCM et WSUS ;
- Satellite ;
- Trellix et Trend ;
- DNS actif.

Le rapport contient :

- une vue par CI avec outils attendus, présents et absents ;
- une vue par outil et par équipe responsable ;
- un résumé HTML dans le mail ;
- CSV détaillé par connecteur ;
- JSON complet pour archivage et retour ServiceNow ;
- un compteur distinct des CI sans policy/job et des CI sans backup récent ;
- les exemptions et profils d'applicabilité utilisés ;
- l'ancienneté de chaque écart et sa première date d'observation lorsqu'elle est
  disponible.

Artefact AAP : `servicenow_active_ci_coverage_report_summary`.

## Variables proposées

```yaml
active_server_ci_query: null
retired_server_ci_query: null
retirement_grace_days: 7
ci_batch_size: 100

coverage_profiles: {}
coverage_profile_field: null
coverage_exception_field: null
coverage_exception_expiration_field: null

vmware_vcenters: []
vmware_include_snapshots: true
vmware_include_orphan_vms_without_ci: true

scvmm_servers: []
hyperv_include_checkpoints: true
hyperv_include_orphan_vms_without_ci: true

veeam_servers: []
veeam_default_rpo_hours: 24
veeam_check_effective_container_coverage: true
veeam_check_restore_points: true

netbackup_masters: []
netbackup_default_rpo_hours: 24
netbackup_check_effective_policy_coverage: true
netbackup_check_backup_images: true

centreon_url: null
sccm_site_code: null
sccm_provider: null
wsus_servers: []
satellite_instances: []
trellix_backend: trellix_epo
trellix_epo_url: null
trend_backend: trend_vision_one
trend_api_url: null

dns_resolvers: []
dns_query_timeout_seconds: 5
dns_query_types:
  - A
  - AAAA
  - CNAME
  - PTR
servicenow_dns_name_fields:
  - name
  - fqdn
servicenow_dns_alias_fields: []
servicenow_ip_relation_source: cmdb

mail_enabled: true
mail_only_on_findings: true
mail_recipients: []
mail_allowed_domains: []
mail_subject_prefix: "[CMDB coverage]"
```

## Garde-fous

1. snapshot des CI figé au début du run ;
2. matrice d'applicabilité obligatoire pour qualifier `expected_missing` ;
3. exemptions datées et auditables ;
4. corrélation exacte et explicable ;
5. aucun changement dans vCenter, SCVMM, Veeam, NetBackup ou les outils de gestion ;
6. aucune suppression DNS ;
7. distinction policy/job absent, backup absent et backup stale ;
8. prise en compte des inclusions indirectes et exclusions ;
9. requêtes DNS exécutées contre les résolveurs explicitement déclarés ;
10. aucune erreur sur un alias attendu et correctement rattaché au CI ;
11. un connecteur en échec n'empêche pas les autres audits de terminer ;
12. distinction `not_expected`, `not_checked` et `expected_missing` ;
13. artefacts sans secrets et destinataires mail allowlistés ;
14. timeouts, pagination, limites de lots et reprise ;
15. aucun résultat d'audit ne déclenche une remédiation implicite.

## Intégration AAP / ServiceNow

Job Templates distincts :

- audit VMware des CI retirés ;
- audit Hyper-V des CI retirés ;
- audit couverture/backup Veeam ;
- audit couverture/backup NetBackup ;
- audit actif Centreon ;
- audit actif SCCM ;
- audit actif WSUS ;
- audit actif Satellite ;
- audit actif Trellix ;
- audit actif Trend ;
- audit DNS actif ;
- audit DNS retiré ;
- rapport consolidé CI actifs ;
- extension du rapport consolidé CI retirés.

Workflow CI actifs recommandé :

1. extraction figée des CI actifs ;
2. résolution de leur profil de couverture et des exemptions ;
3. lancement parallèle des audits de sauvegarde, gestion, sécurité, supervision et DNS ;
4. conservation des résultats partiels en cas d'échec d'un connecteur ;
5. agrégation par CI et qualification des absences attendues ;
6. génération HTML/CSV/JSON ;
7. envoi par mail ;
8. publication du statut consolidé dans AAP ou ServiceNow sans mutation technique.

Workflow CI retirés recommandé :

1. extraction des CI retirés hors période de grâce ;
2. audit VMware et Hyper-V ;
3. audit DNS direct, aliases et PTR ;
4. agrégation avec AD, WSUS, SCCM, Satellite, EDR, Centreon et Pure Storage ;
5. génération du rapport consolidé ;
6. traitement manuel ou workflow de remédiation séparé après approbation.

## Ordre de réalisation recommandé

1. modèle commun de profil de couverture et états de résultat ;
2. audits VMware et Hyper-V des CI retirés ;
3. audit DNS actif et retiré ;
4. Veeam puis NetBackup avec couverture effective et restore points/images ;
5. Centreon, SCCM, WSUS et Satellite actifs ;
6. Trellix et Trend actifs ;
7. rapport consolidé des CI actifs ;
8. intégration au rapport des CI retirés ;
9. exécution par lots, historique des écarts et planification AAP.

## Validation attendue

- tests VMware powered on/off, snapshot, template, orphan et doublon ;
- tests Hyper-V powered on/off, checkpoint, VHDX, host absent et doublon ;
- tests Veeam d'inclusion directe, conteneur, exclusion, job sans restore point et
  backup stale ;
- tests NetBackup de client direct, règle intelligente, policy sans image et image
  expirée ;
- tests d'applicabilité Windows/Linux et exemptions ;
- tests Centreon/SCCM/WSUS/Satellite/EDR présent, absent, stale et dupliqué ;
- tests DNS A/AAAA, CNAME, PTR, NXDOMAIN, alias valide, alias erroné et split DNS ;
- tests d'échec partiel sans perte des autres résultats ;
- tests des rapports HTML/CSV/JSON et de l'envoi mail sécurisé ;
- preuve qu'aucune action de remédiation ou suppression n'est exécutée.
