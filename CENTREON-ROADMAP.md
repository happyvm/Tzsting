# Roadmap d'automatisation Centreon

Ce document complète [`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md) pour le
périmètre supervision. Il décrit des projets Ansible autonomes afin qu'un
exploitant puisse récupérer uniquement la configuration Centreon ou les
opérations de cycle de vie des hôtes dont il a besoin.

## Principes

- aucune écriture directe dans la base Centreon ;
- découverte de la version et des capacités avant toute mutation ;
- API de configuration supportée privilégiée ;
- recours à REST v1/CLAPI uniquement lorsque nécessaire et validé pour la version ;
- authentification par credential AAP ou gestionnaire de secrets ;
- résolution non ambiguë des hôtes, templates, groupes et pollers ;
- toute mutation est suivie d'une génération, d'un test, d'un export et d'une
  application de la configuration sur le ou les pollers concernés ;
- un échec de validation interdit le redémarrage ou le rechargement du moteur ;
- chaque projet publie un artefact `set_stats` stable pour AAP/ServiceNow.

## Catalogue cible

### `ansible-centreon-conf`

Configuration déclarative d'un serveur Centreon central installé sur un système
d'exploitation standard.

Périmètre système :

- compte local d'automatisation et groupes autorisés ;
- intégration Active Directory/LDAP et mapping des groupes lorsque supporté ;
- NTP, timezone et DNS ;
- certificats TLS et chaîne de confiance ;
- relais SMTP et destinataires de test ;
- redirection syslog et niveaux de journalisation ;
- contrôle des services Centreon, Gorgone, Broker et moteur de supervision.

Périmètre Centreon :

- compte/API token dédié à l'automatisation et RBAC minimal ;
- inventaire et validation des pollers déclarés ;
- paramètres de journalisation et d'audit ;
- configuration des notifications globales sans créer implicitement de contacts ;
- test de l'API, de Gorgone et de la communication central/pollers ;
- mode `configure`, `audit` et `plan` ;
- refus de modifier les pollers ou objets de supervision non déclarés.

La configuration générique de l'OS doit rester séparée des paramètres Centreon
pour qu'une évolution de l'application ne modifie pas implicitement le système.

Artefact AAP : `centreon_conf_summary`.

### `ansible-centreon-host-add`

Création déclarative et idempotente d'un hôte Centreon :

- nom technique, alias, adresse IP ou FQDN ;
- serveur de supervision/poller explicitement sélectionné ;
- un ou plusieurs host templates dans un ordre déterministe ;
- création optionnelle des services liés aux templates ;
- host groups, catégories, contacts et contact groups ;
- période de contrôle, période de notification et options de notification ;
- macros d'hôte avec masquage des valeurs sensibles ;
- paramètres SNMP et credential associés sans secret dans les variables ;
- activation ou création désactivée ;
- détection des doublons par nom, alias, IP et FQDN ;
- refus d'écraser un hôte existant incompatible ;
- validation de l'existence des templates, groupes, contacts et poller ;
- génération et test de la configuration avant application ;
- export puis reload/restart contrôlé uniquement du poller concerné ;
- vérification finale que l'hôte et les services attendus sont visibles.

L'opération doit être transactionnelle : si le test de configuration échoue,
l'hôte peut rester créé dans la configuration Centreon, mais la configuration
n'est pas appliquée et l'artefact doit publier précisément l'état `configured`
mais `not_deployed` pour permettre un rollback ou une correction explicite.

Artefact AAP : `centreon_host_add_summary`.

### `ansible-centreon-host-remove`

Suppression contrôlée d'un hôte Centreon :

- résolution par identifiant ou nom exact, sans correspondance partielle ;
- inventaire préalable des services, traps, dépendances, groupes, downtimes,
  acknowledgements et poller associés ;
- mode `plan` obligatoire pour publier l'impact avant suppression ;
- refus si l'hôte est encore référencé par une dépendance ou une règle incompatible,
  sauf traitement explicite de cette dépendance ;
- désactivation préalable optionnelle et période de grâce pilotée par workflow ;
- confirmation explicite `confirm_remove_host=true` ;
- suppression de l'objet et de ses services liés uniquement après validation ;
- aucune suppression implicite de l'agent, du client de sauvegarde, de la VM, du
  serveur physique ou des objets CMDB ;
- conservation de l'historique et des métriques lorsque Centreon le permet ;
- génération, test et export de la configuration ;
- reload/restart contrôlé uniquement du poller précédemment affecté ;
- vérification finale de l'absence de l'hôte dans la configuration active.

Artefact AAP : `centreon_host_remove_summary`.

## Variables proposées

```yaml
centreon_url: https://centreon.example.net
centreon_validate_certs: true
centreon_api_mode: auto  # auto | rest | clapi
centreon_api_version: auto

centreon_host_name: srv-example
centreon_host_alias: Serveur exemple
centreon_host_address: 192.0.2.10
centreon_poller_name: Poller-Production
centreon_host_templates: []
centreon_hostgroups: []
centreon_categories: []
centreon_create_template_services: true
centreon_host_enabled: true

centreon_apply_configuration: true
centreon_config_test_required: true
centreon_engine_action: reload  # reload | restart

confirm_remove_host: false
preserve_monitoring_history: true
```

Les tokens, mots de passe, communautés SNMP et clés privées sont fournis via un
Credential AAP, Ansible Vault ou un gestionnaire de secrets externe.

## Garde-fous

1. TLS validé par défaut ;
2. aucun secret dans les logs ou `set_stats` ;
3. aucun accès SQL direct ;
4. allowlist des actions API/CLAPI utilisées ;
5. validation stricte de toutes les valeurs interpolées dans une commande CLAPI ;
6. idempotence des ajouts et suppressions ;
7. détection des doublons nom court/FQDN/IP ;
8. verrou par objet `centreon-host:<nom>` et par poller pendant l'application ;
9. inventaire d'impact obligatoire avant suppression ;
10. test de configuration bloquant avant export ;
11. application limitée au poller concerné ;
12. publication distincte des états configuration créée, validée et déployée ;
13. nettoyage et libération des verrous dans un bloc `always`.

## Intégration AAP / ServiceNow

Chaque opération expose un Job Template distinct :

- configuration/audit Centreon ;
- ajout d'un hôte ;
- suppression d'un hôte ;
- future modification d'un hôte ou changement de poller.

La suppression utilise un workflow avec approbation, numéro de changement,
fenêtre autorisée et résultat de l'analyse d'impact. `ansible-createvm` et les
futurs workflows bare-metal peuvent appeler `ansible-centreon-host-add`, tandis
que `ansible-deletevm` ou un workflow de décommissionnement peut appeler
`ansible-centreon-host-remove`, sans créer de dépendance directe entre projets.

## Ordre de réalisation recommandé

1. `ansible-centreon-conf` et rôle de découverte des capacités ;
2. `ansible-centreon-host-add` avec génération/test/export/apply ;
3. `ansible-centreon-host-remove` avec analyse d'impact et conservation d'historique ;
4. tests d'idempotence et de non-régression sur plusieurs pollers ;
5. intégration facultative aux workflows de création et décommissionnement.

## Validation attendue

- tests unitaires des payloads REST et commandes CLAPI ;
- tests d'injection et de validation des valeurs interpolées ;
- mocks des erreurs API, conflits, timeouts et tokens expirés ;
- tests d'ajout déjà présent et de suppression déjà réalisée ;
- tests de doublons nom/FQDN/IP ;
- tests d'échec de génération empêchant l'application ;
- tests de ciblage du bon poller ;
- environnement Centreon de test avec au moins un poller ;
- matrice publiée Centreon × API/CLAPI × système d'exploitation.