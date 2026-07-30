# Roadmap d'automatisation Red Hat Satellite

Ce document complète [`ENDPOINT-MANAGEMENT-ROADMAP.md`](ENDPOINT-MANAGEMENT-ROADMAP.md)
et [`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md) pour le cycle de vie des
serveurs Linux gérés par Red Hat Satellite.

Les projets restent autonomes : l'enregistrement d'un hôte, son affectation à un
host group et la promotion de contenu sont des opérations séparées avec des
droits AAP distincts.

## Principes

- aucune écriture directe dans les bases Satellite, Candlepin ou Pulp ;
- API Satellite/Foreman, `hammer` et outils Red Hat supportés uniquement ;
- découverte de la version, de l'organisation, de la location et des Capsules ;
- validation TLS activée par défaut ;
- activation keys, host groups, lifecycle environments et content views restent
  des objets explicites ;
- aucune promotion de contenu, installation de paquet ou remédiation implicite
  lors d'un simple enregistrement ;
- aucune désinscription ne désinstalle automatiquement les paquets applicatifs ;
- secrets et tokens fournis par Credential AAP, Vault ou gestionnaire de secrets ;
- artefact `set_stats` stable pour ServiceNow et la CMDB.

## Catalogue cible

### `ansible-satellite-conf`

Configuration déclarative d'une infrastructure Satellite existante :

- découverte de la version du Satellite et des Capsules ;
- organisations, locations et associations autorisées ;
- comptes, groupes externes LDAP/AD et RBAC minimal ;
- NTP, timezone, DNS, certificats, SMTP et syslog du système ;
- validation des Capsules, content sources et flux vers les dépôts ;
- produits et repositories explicitement déclarés ;
- sync plans et associations produit/sync plan ;
- lifecycle environments et chemins de promotion ;
- inventaire des content views et composite content views ;
- contrôle de santé des services Satellite, Pulp et Candlepin ;
- modes `configure`, `audit` et `plan` ;
- refus de synchroniser ou publier du contenu non déclaré.

Artefact AAP : `satellite_conf_summary`.

### `ansible-satellite-activation-key-manage`

**Statut** : implémenté via le vrai module
`theforeman.foreman.activation_key` - organisation, lifecycle
environment/content view (ou content view environments multiples),
host collections, content overrides, limite d'hôtes, system purpose,
release version, service level, modes `present`/`present_with_defaults`/
`absent` et `audit` (check mode natif Ansible). Restent à faire :
repositories/produits autorisés en tant que garde-fou dédié (le module
gère les content overrides mais pas une allowlist de produits), un mode
`disabled` propre à ce projet (les activation keys Foreman n'ont pas de
bascule enabled/disabled native - à concevoir si un besoin réel apparaît).
Voir [`ansible-satellite-activation-key-manage/README.md`](ansible-satellite-activation-key-manage/README.md).

Création ou mise à jour déclarative d'une activation key :

- organisation et location explicites ;
- lifecycle environment et content view ;
- repositories et produits autorisés ;
- host collections optionnelles ;
- system purpose, release version et service level lorsque utilisés ;
- limite d'hôtes et activation/désactivation ;
- prévention des doublons et renommages implicites ;
- mode `present`, `audit` et `disabled` ;
- aucune réinscription automatique des hôtes existants après modification.

Les changements d'une activation key s'appliquent par défaut aux futurs
enregistrements. Toute réalignement d'hôtes existants est une opération séparée.

Artefact AAP : `satellite_activation_key_summary`.

### `ansible-satellite-host-register`

Enregistrement idempotent d'un serveur RHEL ou compatible dans Satellite :

- détection de l'OS, de l'architecture et de l'état d'enregistrement existant ;
- téléchargement de la CA depuis une source approuvée et validation de son
  empreinte avant installation ;
- organisation, location, Capsule/content source et activation key explicites ;
- host group optionnel ;
- nom canonique, facts et identité machine non ambigus ;
- proxy et paramètres réseau déclarés ;
- installation des outils Satellite Client requis par la version ;
- enregistrement via global registration ou mécanisme supporté par la version ;
- validation avec `subscription-manager identity` et lecture de l'hôte via API ;
- refus de rattacher silencieusement un hôte enregistré auprès d'une autre
  organisation ou d'un autre Satellite ;
- aucune exécution de patch ou installation applicative implicite.

Artefact AAP : `satellite_host_register_summary`.

### `ansible-satellite-host-unregister`

Désinscription contrôlée d'un hôte :

- résolution exacte de l'hôte et de son content host ;
- inventaire des host groups, host collections, errata et remote execution jobs ;
- refus si une tâche Satellite est active sur l'hôte ;
- suppression de l'enregistrement local et de l'objet Satellite selon le mode ;
- modes séparés `disconnect`, `unregister` et `remove_host_object` ;
- conservation des paquets installés et des données locales ;
- suppression de l'identité et des certificats uniquement avec confirmation ;
- aucune suppression de la VM, du serveur, de l'objet AD/DNS/CMDB ou des
  sauvegardes ;
- confirmation `confirm_satellite_unregister=true`.

Artefact AAP : `satellite_host_unregister_summary`.

### `ansible-satellite-hostgroup-add`

**Statut** : implémenté via le vrai module `theforeman.foreman.host` -
affectation idempotente, mode `audit` (check mode natif Ansible),
publication de l'état actuel de l'hôte et de la définition du host group
cible avant application (`host_info`/`hostgroup_info`). **Partiellement
fait** : ce n'est pas encore le diff calculé de chaque paramètre hérité
(OS, activation keys, lifecycle environment, content view...) décrit
ci-dessous - `host_info`/`hostgroup_info` renvoient un dictionnaire
générique dont le schéma exact n'est pas documenté, donc ce calcul n'a
pas été implémenté sans l'avoir vérifié contre une instance réelle. Le
refus de changement implicite de content view/lifecycle environment et le
mode `plan` obligatoire restent à faire. Voir
[`ansible-satellite-hostgroup-add/README.md`](ansible-satellite-hostgroup-add/README.md).

Affectation idempotente d'un hôte existant à un host group :

- résolution exacte de l'hôte et du host group ;
- publication préalable de l'impact hérité : OS, activation keys, lifecycle
  environment, content view, paramètres, Ansible roles et Puppet classes ;
- refus si l'opération changerait implicitement un content view ou un lifecycle
  environment sans autorisation ;
- mode `plan` obligatoire lorsque des paramètres hérités seraient modifiés ;
- vérification finale de l'affectation et des valeurs effectives ;
- aucune exécution automatique des rôles ou jobs hérités.

Artefact AAP : `satellite_hostgroup_add_summary`.

### `ansible-satellite-hostgroup-remove`

Retrait contrôlé d'un hôte de son host group :

- inventaire des paramètres hérités qui disparaîtront ;
- refus si le retrait laisse l'hôte sans content source, lifecycle environment ou
  content view valide ;
- conservation de l'enregistrement Satellite ;
- conservation de l'activation key historique et des paquets installés ;
- aucune désinscription ou suppression d'objet implicite ;
- confirmation `confirm_remove_from_satellite_hostgroup=true`.

Artefact AAP : `satellite_hostgroup_remove_summary`.

### `ansible-satellite-content-view-promote`

Promotion contrôlée d'une version de content view :

- résolution exacte de l'organisation, du content view et de sa version ;
- validation de la publication complète et de l'état des repositories ;
- chemin de lifecycle environments allowlisté ;
- promotion séquentielle et refus de sauter un environnement sans autorisation ;
- publication optionnelle dans un mode distinct avant promotion ;
- contrôle des filtres, errata inclus/exclus et dépendances de composite content view ;
- mode `plan` publiant la différence entre version source et destination ;
- refus de promouvoir une version plus ancienne par défaut ;
- aucune remédiation automatique des hôtes après promotion ;
- vérification finale des environnements associés à la version.

Artefact AAP : `satellite_content_view_promote_summary`.

## Variables proposées

```yaml
satellite_url: https://satellite.example.net
satellite_validate_certs: true
satellite_api_mode: auto  # api | hammer | auto
satellite_organization: Production
satellite_location: Paris
satellite_capsule: capsule01.example.net

satellite_host_name: srv-rhel-01.example.net
satellite_activation_key: ak-rhel9-production
satellite_hostgroup: RHEL9/Production
satellite_lifecycle_environment: Production
satellite_content_view: CV-RHEL9

satellite_content_view_version: null
satellite_publish_before_promote: false
satellite_allow_skip_environment: false
satellite_allow_content_downgrade: false

confirm_satellite_unregister: false
confirm_remove_from_satellite_hostgroup: false
preserve_satellite_identity: true
```

## Garde-fous

1. validation TLS et empreinte de CA ;
2. aucun secret dans les logs ou `set_stats` ;
3. aucun accès SQL direct ;
4. résolution non ambiguë des organisations, locations, Capsules, hôtes et contenu ;
5. verrou par hôte et par content view pendant une mutation ;
6. idempotence des enregistrements et affectations ;
7. mode `plan` avant tout changement d'héritage de host group ;
8. aucune promotion de contenu ou remédiation implicite ;
9. aucun changement silencieux de Satellite, organisation ou lifecycle environment ;
10. refus des downgrades de contenu par défaut ;
11. désinscription distincte de la suppression de l'objet et de l'identité locale ;
12. nettoyage et libération des verrous dans un bloc `always` ;
13. matrice Satellite × Capsule × RHEL/Oracle Linux publiée et testée.

## Intégration AAP / ServiceNow

Chaque opération expose un Job Template distinct :

- configuration/audit Satellite ;
- gestion des activation keys ;
- enregistrement et désinscription ;
- ajout et retrait d'un host group ;
- publication/promotion de content view.

Les workflows de création de serveur peuvent enchaîner l'enregistrement puis
l'affectation au host group. Les workflows de patch consomment un content view
déjà promu ; ils ne déclenchent pas eux-mêmes une promotion implicite.

## Ordre de réalisation recommandé

1. `ansible-satellite-conf` et découverte des capacités - **pas encore fait** ;
2. `ansible-satellite-activation-key-manage` - **fait** ;
3. `ansible-satellite-host-register` et `ansible-satellite-host-unregister` -
   **pas encore fait** ;
4. `ansible-satellite-hostgroup-add` - **fait** (voir statut détaillé
   ci-dessus pour ce qui manque) ; `ansible-satellite-hostgroup-remove` -
   **pas encore fait** ;
5. `ansible-satellite-content-view-promote` - **pas encore fait**, mais
   `theforeman.foreman.content_view_version` existe et couvre la
   promotion - bon candidat pour la suite ;
6. tests de cycle de vie complet sur hôtes jetables.

## Validation attendue

- tests unitaires des payloads API et commandes `hammer` ;
- tests d'enregistrement déjà présent et de changement de Satellite refusé ;
- tests d'héritage host group et mode `plan` ;
- tests de promotion séquentielle et de downgrade bloqué ;
- tests avec Capsule, proxy et certificat interne ;
- tests RHEL 8/9/10 et Oracle Linux selon le parc réellement supporté ;
- matrice publiée Satellite × Capsule × OS × mode d'enregistrement.
