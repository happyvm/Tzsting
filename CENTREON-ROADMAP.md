# Roadmap d'automatisation Centreon

Ce document complète [`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md) pour le
périmètre supervision. Il décrit des projets Ansible autonomes afin qu'un
exploitant puisse récupérer uniquement la configuration Centreon ou les
opérations de cycle de vie dont il a besoin.

## Principes

- aucune écriture directe dans la base Centreon ;
- découverte de la version et des capacités avant toute mutation ;
- API de configuration supportée privilégiée ;
- recours à REST v1/CLAPI uniquement lorsque nécessaire et validé pour la version ;
- authentification par Credential AAP ou gestionnaire de secrets ;
- résolution non ambiguë des hôtes, services, templates, groupes et pollers ;
- toute mutation de configuration est suivie d'une génération, d'un test, d'un
  export et d'une application sur le ou les pollers concernés ;
- les downtimes et acknowledgements sont des opérations runtime et ne provoquent
  pas de génération/export de configuration ;
- un échec de validation interdit le redémarrage ou le rechargement du moteur ;
- chaque projet publie un artefact `set_stats` stable pour AAP/ServiceNow.

## Statut de réalisation

🟡 **`ansible-centreon-downtime-create`** (étape 4) et
**`ansible-centreon-acknowledgement-create`** (étape 5) implémentés en
premier, avant `ansible-centreon-conf`/`host-add`/`service-add` (étapes
1-3) : les opérations runtime downtime/acknowledgement ne dépendent
d'aucune résolution de configuration, contrairement à la création
d'hôtes/services, et se prêtaient donc mieux à une confirmation partielle
des endpoints REST. Pour les deux : le flux d'authentification est
corroboré par `docs.centreon.com`, mais l'endpoint de création
lui-même est laissé vide/obligatoire, à confirmer par l'exploitant sur la
documentation API vivante de son propre serveur (voir le README de
chaque projet). Résolution de nom hôte/service vers ID non implémentée
dans les deux ; détection d'un doublon (downtime ou acknowledgement déjà
présent) non implémentée ; la vérification que la cible est bien dans un
état nécessitant un acknowledgement n'est pas non plus implémentée
(même limite de confiance sur le endpoint de statut runtime - voir le
README de `ansible-centreon-acknowledgement-create`). Toutes les autres
briques du catalogue restent à faire.

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
- modes `configure`, `audit` et `plan` ;
- refus de modifier les pollers ou objets de supervision non déclarés.

La configuration générique de l'OS reste séparée des paramètres Centreon.

Artefact AAP : `centreon_conf_summary`.

### `ansible-centreon-host-add`

Création déclarative et idempotente d'un hôte Centreon :

- nom technique, alias, adresse IP ou FQDN ;
- poller explicitement sélectionné ;
- un ou plusieurs host templates dans un ordre déterministe ;
- création optionnelle des services liés aux templates ;
- host groups, catégories, contacts et contact groups ;
- périodes de contrôle et de notification ;
- macros d'hôte avec masquage des valeurs sensibles ;
- paramètres SNMP et Credential associés ;
- activation ou création désactivée ;
- détection des doublons par nom, alias, IP et FQDN ;
- validation de l'existence des templates, groupes, contacts et poller ;
- génération, test, export et application de la configuration ;
- vérification finale de l'hôte et des services attendus.

En cas d'échec du test, l'artefact publie séparément les états `configured`,
`validated` et `deployed` afin de permettre un rollback explicite.

Artefact AAP : `centreon_host_add_summary`.

### `ansible-centreon-host-update`

Mise à jour déclarative d'un hôte existant :

- résolution par identifiant ou nom exact ;
- modification contrôlée de l'alias, de l'adresse, des templates, groupes,
  catégories, contacts, périodes, notifications et macros ;
- publication du diff avant mutation ;
- protection des macros sensibles dans le diff et les logs ;
- refus de remplacer tous les templates ou groupes à cause d'une liste vide non
  explicitement confirmée ;
- validation des services hérités ajoutés ou retirés par les templates ;
- génération, test, export et application uniquement sur le poller concerné ;
- rollback de la configuration de l'objet si le déploiement échoue lorsque la
  version et l'API le permettent.

Artefact AAP : `centreon_host_update_summary`.

### `ansible-centreon-host-move-poller`

Déplacement contrôlé d'un hôte entre pollers :

- résolution exacte de l'hôte, du poller source et du poller destination ;
- validation de la connectivité du poller destination vers l'hôte ;
- contrôle de la disponibilité des plugins, connecteurs, commandes et templates
  nécessaires sur le poller destination ;
- inventaire des dépendances, services passifs, traps et flux Broker ;
- création facultative d'une downtime couvrant la bascule ;
- génération/test/export sur les deux pollers ;
- application ordonnée destination puis source afin de limiter le trou de
  supervision, selon le mode supporté ;
- vérification de la réception des premiers contrôles sur le poller destination ;
- rollback vers le poller source en cas d'échec ;
- confirmation `confirm_move_poller=true`.

Artefact AAP : `centreon_host_move_poller_summary`.

### `ansible-centreon-host-remove`

Suppression contrôlée d'un hôte Centreon :

- résolution par identifiant ou nom exact ;
- inventaire préalable des services, traps, dépendances, groupes, downtimes,
  acknowledgements et poller associés ;
- mode `plan` obligatoire pour publier l'impact ;
- refus si l'hôte reste référencé par une dépendance non traitée ;
- désactivation préalable optionnelle et période de grâce ;
- confirmation explicite `confirm_remove_host=true` ;
- suppression de l'objet et de ses services liés après validation ;
- aucune suppression implicite de l'agent, de la VM, du serveur physique, des
  sauvegardes ou des objets CMDB ;
- conservation de l'historique lorsque Centreon le permet ;
- génération, test, export et application sur le poller précédemment affecté ;
- vérification finale de l'absence dans la configuration active.

Artefact AAP : `centreon_host_remove_summary`.

### `ansible-centreon-service-add`

Ajout déclaratif d'un service à un hôte :

- résolution exacte de l'hôte et du service template ;
- nom de service unique sur l'hôte ;
- macros, périodes, contacts, catégories et paramètres de notification ;
- prévention des doublons avec les services déjà hérités d'un host template ;
- validation de la commande, des connecteurs et plugins sur le poller ;
- création activée ou désactivée ;
- génération, test, export et application ;
- vérification du premier contrôle du service.

Artefact AAP : `centreon_service_add_summary`.

### `ansible-centreon-service-remove`

Suppression contrôlée d'un service :

- résolution exacte de l'hôte et du service ;
- détection d'un service hérité d'un template, qui doit être traité par le lien de
  template plutôt que supprimé comme objet direct ;
- inventaire des dépendances, escalades, downtimes et acknowledgements ;
- mode `plan` et confirmation `confirm_remove_service=true` ;
- conservation de l'historique lorsque possible ;
- génération, test, export et application sur le poller concerné ;
- aucune suppression de l'hôte ou de l'agent.

Artefact AAP : `centreon_service_remove_summary`.

### `ansible-centreon-downtime-create`

Création idempotente d'une downtime runtime pour un hôte, un service ou un groupe :

- cible résolue sans ambiguïté ;
- heure de début/fin ou durée explicite ;
- downtime fixe ou flexible ;
- auteur, commentaire et référence du changement ServiceNow ;
- propagation optionnelle aux services de l'hôte ;
- refus des durées illimitées par défaut ;
- détection d'une downtime équivalente déjà active ;
- vérification runtime immédiate, sans export de configuration.

Artefact AAP : `centreon_downtime_create_summary`.

### `ansible-centreon-downtime-remove`

Suppression ciblée d'une downtime :

- résolution par identifiant runtime ou critères stricts ;
- refus de supprimer toutes les downtimes d'une cible sans confirmation forte ;
- vérification que la fenêtre de changement permet la reprise des notifications ;
- confirmation `confirm_remove_downtime=true` ;
- vérification runtime de la suppression.

Artefact AAP : `centreon_downtime_remove_summary`.

### `ansible-centreon-acknowledgement-create`

Création d'un acknowledgement runtime :

- cible hôte ou service exacte ;
- refus si la cible n'est pas dans un état nécessitant un acknowledgement, sauf
  mode explicitement autorisé ;
- auteur, commentaire, persistance, sticky et notification selon capacités ;
- référence du ticket incident/changement obligatoire en production ;
- détection d'un acknowledgement équivalent déjà présent ;
- vérification runtime sans export de configuration.

Artefact AAP : `centreon_acknowledgement_create_summary`.

🟡 Implémenté dans [`ansible-centreon-acknowledgement-create`](../ansible-centreon-acknowledgement-create) :
cible hôte/service par ID numérique, commentaire/auteur/référence de
ticket (toujours obligatoire), indicateurs `sticky`/`notify`/`persistent`.
Non couvert : résolution nom → ID, vérification que la cible nécessite
réellement un acknowledgement, détection d'un acknowledgement équivalent
déjà présent.

### `ansible-centreon-acknowledgement-remove`

Retrait ciblé d'un acknowledgement :

- résolution par identifiant ou cible exacte ;
- confirmation `confirm_remove_acknowledgement=true` ;
- conservation du commentaire dans l'artefact de résultat ;
- vérification runtime immédiate ;
- aucune modification de la configuration de l'hôte ou du service.

Artefact AAP : `centreon_acknowledgement_remove_summary`.

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
centreon_destination_poller_name: null
centreon_host_templates: []
centreon_hostgroups: []
centreon_categories: []
centreon_create_template_services: true
centreon_host_enabled: true

centreon_service_name: null
centreon_service_template: null

centreon_runtime_target_type: host  # host | service | hostgroup | servicegroup
centreon_downtime_start: null
centreon_downtime_end: null
centreon_downtime_duration_seconds: null
centreon_runtime_author: aap
centreon_runtime_comment: null
centreon_change_number: null

centreon_apply_configuration: true
centreon_config_test_required: true
centreon_engine_action: reload  # reload | restart

confirm_move_poller: false
confirm_remove_host: false
confirm_remove_service: false
confirm_remove_downtime: false
confirm_remove_acknowledgement: false
preserve_monitoring_history: true
```

Les tokens, mots de passe, communautés SNMP et clés privées sont fournis via un
Credential AAP, Ansible Vault ou un gestionnaire de secrets externe.

## Garde-fous

1. TLS validé par défaut ;
2. aucun secret dans les logs ou `set_stats` ;
3. aucun accès SQL direct ;
4. allowlist des actions API/CLAPI utilisées ;
5. validation stricte des valeurs interpolées dans une commande CLAPI ;
6. idempotence des ajouts, mises à jour et suppressions ;
7. détection des doublons nom court/FQDN/IP ;
8. verrou par objet et par poller pendant une mutation de configuration ;
9. inventaire d'impact obligatoire avant suppression ou changement de poller ;
10. test de configuration bloquant avant export ;
11. application limitée aux pollers concernés ;
12. distinction stricte configuration vs opérations runtime ;
13. durée maximale et ticket obligatoire pour les downtimes de production ;
14. publication distincte des états configuré, validé et déployé ;
15. nettoyage et libération des verrous dans un bloc `always`.

## Intégration AAP / ServiceNow

Chaque opération expose un Job Template distinct :

- configuration/audit Centreon ;
- ajout, mise à jour, déplacement de poller et suppression d'un hôte ;
- ajout et suppression d'un service ;
- création et suppression d'une downtime ;
- création et suppression d'un acknowledgement.

Les workflows de maintenance d'hyperviseur, de patch, de resize, de restauration
ou de décommissionnement peuvent appeler les briques runtime Centreon sans créer
de dépendance directe avec les projets techniques concernés.

## Ordre de réalisation recommandé

1. `ansible-centreon-conf` et découverte des capacités ;
2. `ansible-centreon-host-add`, `host-update` et `host-remove` ;
3. `ansible-centreon-service-add` et `service-remove` ;
4. `ansible-centreon-downtime-create` et `downtime-remove` ;
5. `ansible-centreon-acknowledgement-create` et `acknowledgement-remove` ;
6. `ansible-centreon-host-move-poller` avec rollback ;
7. intégration facultative aux workflows de cycle de vie.

## Validation attendue

- tests unitaires des payloads REST et commandes CLAPI ;
- tests d'injection et de validation des valeurs interpolées ;
- mocks des erreurs API, conflits, timeouts et tokens expirés ;
- tests d'ajout, update et suppression idempotents ;
- tests des services directs et hérités de templates ;
- tests d'échec de génération empêchant l'application ;
- tests de déplacement entre deux pollers avec rollback ;
- tests runtime downtime/acknowledgement sans export de configuration ;
- environnement Centreon de test avec au moins deux pollers ;
- matrice publiée Centreon × API/CLAPI × système d'exploitation.
