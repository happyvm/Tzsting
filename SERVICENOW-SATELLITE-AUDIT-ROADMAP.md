# Roadmap d'automatisation — audit ServiceNow / Red Hat Satellite

Ce document complète [`SERVICENOW-RECONCILIATION-ROADMAP.md`](SERVICENOW-RECONCILIATION-ROADMAP.md)
et [`SATELLITE-ROADMAP.md`](SATELLITE-ROADMAP.md).

Il décrit un projet Ansible autonome chargé de comparer les CI serveurs retirés
dans ServiceNow avec les hosts encore présents dans Red Hat Satellite afin de
remonter les enregistrements susceptibles de continuer à consommer une
souscription ou une licence.

Le projet est strictement en lecture seule : il ne désinscrit aucun hôte, ne
supprime aucun objet Satellite et ne modifie aucune activation key.

## Projet cible

### `ansible-servicenow-satellite-retired-ci-audit`

Le projet prend en entrée le même snapshot figé de CI retirés que les audits AD,
WSUS, SCCM, Trellix, Trend et Centreon.

Il interroge chaque instance Satellite et Capsule déclarée via l'API Satellite,
les modules Foreman supportés ou `hammer` lorsque cela est nécessaire et validé
pour la version utilisée.

## Corrélation des CI

Ordre proposé :

1. identifiant natif Satellite déjà stocké dans ServiceNow ;
2. UUID d'abonnement, `subscription-manager identity` ou identifiant Candlepin ;
3. UUID/DMI/SMBIOS de l'hôte lorsque disponible ;
4. FQDN normalisé ;
5. nom court uniquement s'il est unique dans l'organisation et la location ;
6. adresse IP uniquement comme indice secondaire.

Une correspondance multiple entre organisations, locations ou instances
Satellite produit `ambiguous` et n'est jamais résolue arbitrairement.

## Contrôles Satellite

Pour chaque CI retiré correspondant à un host Satellite, le projet remonte :

- organisation et location ;
- Satellite et Capsule/content source associés ;
- identifiant du host et du content host ;
- état d'enregistrement ;
- dernière communication et dernière mise à jour des facts ;
- activation key historique lorsqu'elle est disponible ;
- lifecycle environment et content view actifs ;
- host group et host collections ;
- système purpose, rôle, usage et service level lorsque configurés ;
- produits installés et repositories activés ;
- statut de contenu et éventuels errata applicables ;
- présence de certificats ou d'une identité Candlepin encore active ;
- remote execution jobs ou tâches Satellite encore en cours.

## Licence et souscription

La simple présence d'un host dans Satellite ne prouve pas toujours qu'une
licence est effectivement consommée. Le rapport distingue donc plusieurs cas.

### Mode entitlement classique

Lorsque les souscriptions sont attachées individuellement :

- inventaire des pools et entitlements attachés au host ;
- quantité et type de souscription lorsque l'API les expose ;
- statut `subscribed`, `partially_subscribed`, `not_subscribed` ou équivalent ;
- mise en évidence d'un CI retiré possédant encore un entitlement attaché ;
- identification des pools potentiellement libérables après désinscription.

### Simple Content Access

Lorsque Simple Content Access est activé :

- ne pas conclure qu'aucune licence n'est consommée uniquement parce qu'aucun
  entitlement individuel n'est attaché ;
- remonter la présence persistante du host, son organisation, ses produits et sa
  dernière activité comme indicateurs de consommation potentielle ;
- publier `subscription_consumption_status=indeterminate_sca` lorsque Satellite
  ne permet pas d'attribuer précisément la consommation au host ;
- distinguer la conformité technique Satellite de la conformité contractuelle,
  qui peut nécessiter une source Red Hat Subscription Management ou un outil SAM.

## Catégories de résultat

- `absent` : aucun host Satellite correspondant ;
- `present_inactive` : host présent mais sans activité récente ;
- `present_active` : host retiré dans ServiceNow mais communiquant encore ;
- `entitlement_attached` : souscription attachée en mode classique ;
- `potential_consumption_sca` : présence susceptible de compter dans le parc sous
  Simple Content Access ;
- `identity_or_certificate_remaining` : identité locale/Candlepin encore présente ;
- `duplicate` : plusieurs hosts Satellite pour le même CI ;
- `ambiguous` : corrélation non suffisamment fiable ;
- `not_checked` : connecteur ou API indisponible ;
- `error` : erreur technique pendant le contrôle.

Les écarts les plus critiques sont :

1. CI retiré mais host Satellite encore actif ;
2. entitlement encore attaché ;
3. CI retiré présent dans plusieurs organisations ou instances Satellite ;
4. remote execution job encore actif ;
5. objet Satellite sans CI correspondant.

## Reporting et mail

Le projet publie l'artefact AAP :

`servicenow_satellite_retired_ci_audit_summary`.

Il génère :

- un CSV détaillé des CI retirés encore présents ;
- un résumé HTML avec organisation, location, état, dernière activité et statut
  de souscription ;
- un JSON complet pour l'agrégateur de réconciliation ;
- un compteur séparé des entitlements attachés et des consommations potentielles
  sous Simple Content Access.

Le rapport est consommé par `ansible-servicenow-retired-ci-audit-report` afin
d'être intégré au mail consolidé AD/WSUS/SCCM/Trellix/Trend/Centreon/Pure/Satellite.

## Variables proposées

```yaml
satellite_instances: []
satellite_validate_certs: true
satellite_api_mode: auto  # api | hammer | auto
satellite_organizations: []
satellite_locations: []
satellite_inactive_days: 30
satellite_check_capsules: true
satellite_check_entitlements: true
satellite_detect_simple_content_access: true
satellite_report_installed_products: true
satellite_report_enabled_repositories: false
satellite_report_remote_jobs: true
satellite_include_orphan_hosts_without_ci: true
satellite_allow_unregister: false
```

Les credentials Satellite sont fournis par Credential AAP, Ansible Vault ou un
gestionnaire de secrets. Le compte d'audit dispose uniquement des droits de
lecture nécessaires.

## Garde-fous

1. snapshot des CI retirés figé au début du run ;
2. période de grâce appliquée avant contrôle ;
3. corrélation exacte et explicable ;
4. prise en compte du mode Simple Content Access ;
5. aucune assimilation automatique entre présence Satellite et consommation
   contractuelle certaine ;
6. aucune désinscription ni suppression de host/content host ;
7. aucune suppression d'entitlement, activation key ou certificat ;
8. aucun lancement ou annulation de remote execution job ;
9. aucun secret dans les logs, CSV, HTML, JSON ou `set_stats` ;
10. timeouts, pagination et limites de lots ;
11. un échec Satellite n'empêche pas les autres audits de terminer ;
12. `satellite_allow_unregister` reste `false` et hors usage dans ce projet d'audit.

## Intégration AAP / ServiceNow

Job Templates distincts :

- audit Satellite d'une liste explicite de CI retirés ;
- audit périodique par requête ServiceNow ;
- rapport des entitlements encore attachés ;
- rapport des hosts persistants sous Simple Content Access ;
- export vers l'agrégateur de réconciliation.

Workflow recommandé :

1. extraction des CI retirés hors période de grâce ;
2. interrogation parallèle des instances Satellite ;
3. détection du mode entitlement classique ou Simple Content Access ;
4. corrélation des hosts et content hosts ;
5. qualification de la consommation certaine, potentielle ou indéterminée ;
6. génération de l'artefact et du CSV ;
7. intégration au mail consolidé ;
8. traitement manuel ou workflow de désinscription séparé après approbation.

## Validation attendue

- tests host absent, actif, inactif et dupliqué ;
- tests multi-organisations, multi-locations et multi-Satellite ;
- tests entitlement classique avec et sans pool attaché ;
- tests Simple Content Access sans faux statut « aucune licence » ;
- tests identité Candlepin et certificats persistants ;
- tests remote execution job actif ;
- tests d'API indisponible et de pagination ;
- preuve qu'aucune désinscription ou suppression n'est exécutée.
