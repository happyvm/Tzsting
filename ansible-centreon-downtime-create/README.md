# ansible-centreon-downtime-create

Création d'une downtime runtime Centreon (hôte ou service) via l'API REST
Centreon. Le projet suit la méthodologie du dépôt : préflight bloquant,
secrets Vault/AAP, rôles séparés et artefact `set_stats`.

Ce projet est l'étape 4 de l'ordre de réalisation recommandé dans
[`CENTREON-ROADMAP.md`](../CENTREON-ROADMAP.md).

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : création d'une downtime fixe ou flexible sur un hôte ou un
service identifié par son ID Centreon numérique, avec propagation
optionnelle aux services de l'hôte, durée explicite ou calculée à partir
d'un couple début/fin, auteur, commentaire et référence de changement.

**Non couvert, volontairement** (voir
[`CENTREON-ROADMAP.md`](../CENTREON-ROADMAP.md)) :

- la résolution nom → ID pour l'hôte/le service (fournir directement
  `centreon_host_id`/`centreon_service_id` - voir plus bas) ;
- les downtimes de groupe (`hostgroup`/`servicegroup`) ;
- la détection d'une downtime équivalente déjà active sur la cible (pas
  d'endpoint de recherche/liste implémenté dans cette première version -
  relancer la playbook sur la même fenêtre crée une downtime
  supplémentaire, `changed_when: true` l'assume explicitement) ;
- la suppression de downtime (`ansible-centreon-downtime-remove`, projet
  séparé du catalogue) ;
- toute génération/export de configuration Centreon : une downtime est une
  opération runtime, pas une modification de la configuration supervisée.

## Ce qui est corroboré, ce qui ne l'est pas

Aucune collection Ansible maintenue ne couvre l'API REST v2 de Centreon -
ce projet utilise `ansible.builtin.uri` directement. Le niveau de
confiance n'est pas le même partout :

- **Le flux d'authentification** (`roles/auth`) est codé en dur :
  `POST /centreon/api/{version}/login`, corps JSON imbriqué
  `security.credentials.{login,password}`, jeton renvoyé dans
  `security.token`, en-tête `X-AUTH-TOKEN` pour les appels suivants, jeton
  expirant après une heure d'inactivité. Cette forme est confirmée par la
  documentation officielle `docs.centreon.com` (structure des endpoints,
  en-tête, expiration) ; les noms exacts des champs du corps JSON
  proviennent d'une source secondaire moins autoritative et méritent d'être
  revérifiés sur votre propre instance avant une mise en production large.

- **L'endpoint de création de downtime** (`centreon_downtime_endpoint`)
  n'est **volontairement pas codé en dur** et est laissé vide/obligatoire
  dans `group_vars/all.yml` : le chemin exact varie selon la version de
  Centreon et les recherches menées pour ce projet n'ont pas permis de le
  corroborer avec un niveau de confiance suffisant (une tentative d'accès à
  `api-documentation.centreon.com` a échoué en résolution DNS, une autre
  vers une page versionnée de `docs-api.centreon.com` n'a renvoyé qu'un
  menu de navigation sans contenu exploitable). Le préflight refuse de
  s'exécuter tant que cette valeur n'a pas été renseignée. **Confirmez le
  chemin, la méthode HTTP et la forme exacte du corps JSON attendu sur la
  documentation API vivante de votre propre serveur**, généralement servie
  sur `https://<serveur>/centreon/api/<version>/doc` - c'est la source la
  plus autoritative puisqu'elle reflète exactement la version installée.
  Les noms de champs utilisés par `roles/downtime` (`target_type`,
  `host_id`, `service_id`, `comment`, `author`, `change_number`,
  `start_time`, `end_time`, `duration`, `is_fixed`, `with_services`) sont
  une hypothèse de travail à valider/ajuster contre cette documentation.

## Résolution hôte/service

`centreon_host_id` (et `centreon_service_id` si
`centreon_downtime_target_type: service`) doivent être les identifiants
numériques Centreon déjà connus. Ce projet ne fait aucun appel de
résolution nom → ID ; combinez-le avec un inventaire externe (CMDB,
export Centreon, etc.) si vous partez d'un nom d'hôte.

## Durée : explicite ou calculée

Fournir soit `centreon_downtime_duration_seconds` directement, soit
`centreon_downtime_start_time`/`centreon_downtime_end_time` (le préflight
calcule alors la durée via le filtre Jinja `to_datetime`, selon le format
`centreon_downtime_time_format`). Dans les deux cas, la durée résultante
est bornée par `centreon_downtime_max_duration_seconds`
(garde-fou du catalogue Centreon contre les downtimes illimitées, 24h par
défaut). `centreon_downtime_time_format` doit correspondre au format
attendu par l'endpoint réel de votre serveur - à confirmer en même temps
que l'endpoint lui-même.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
credentials Centreon (`centreon_username`/`centreon_password`). Les tâches
d'authentification et de création de downtime sont en `no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-playbook playbooks/create_downtime.yml --vault-password-file .vault_pass
```

Le résultat `centreon_downtime_create_summary` est récupérable par AAP et
ServiceNow sans exposer les secrets ni le jeton d'API.
