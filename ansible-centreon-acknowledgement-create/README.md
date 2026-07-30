# ansible-centreon-acknowledgement-create

Création d'un acknowledgement runtime Centreon (hôte ou service) via
l'API REST Centreon. Le projet suit la méthodologie du dépôt : préflight
bloquant, secrets Vault/AAP, rôles séparés et artefact `set_stats`.

Ce projet est l'étape 5 de l'ordre de réalisation recommandé dans
[`CENTREON-ROADMAP.md`](../CENTREON-ROADMAP.md).

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : création d'un acknowledgement sur un hôte ou un service
identifié par son ID Centreon numérique, avec commentaire, auteur,
référence de ticket incident/changement, et les indicateurs standards
Nagios/Centreon `sticky`/`notify`/`persistent`.

**Non couvert, volontairement** (voir
[`CENTREON-ROADMAP.md`](../CENTREON-ROADMAP.md)) :

- la résolution nom → ID pour l'hôte/le service (fournir directement
  `centreon_host_id`/`centreon_service_id` - même choix que
  [`ansible-centreon-downtime-create`](../ansible-centreon-downtime-create)) ;
- **la vérification que la cible est bien dans un état nécessitant un
  acknowledgement** : la roadmap demande de refuser l'opération si ce
  n'est pas le cas, sauf mode explicite. Cela suppose d'interroger un
  endpoint de statut runtime dont l'endpoint et le schéma de réponse
  n'ont pas pu être corroborés avec un niveau de confiance suffisant lors
  des recherches menées pour ce projet (même limite que pour l'endpoint
  d'acknowledgement lui-même, voir plus bas). Construire une
  vérification sur un schéma incertain risquerait soit de bloquer des
  acknowledgements valides, soit d'en laisser passer d'invalides - pire
  que l'absence de vérification. **L'opérateur reste responsable de
  juger qu'un acknowledgement est justifié avant de lancer ce projet** ;
- la détection d'un acknowledgement équivalent déjà présent sur la cible
  (pas d'endpoint de recherche/liste implémenté, même limite que
  `ansible-centreon-downtime-create`) ;
- le retrait d'acknowledgement (`ansible-centreon-acknowledgement-remove`,
  projet séparé du catalogue) ;
- toute génération/export de configuration Centreon : un acknowledgement
  est une opération runtime, pas une modification de la configuration
  supervisée.

## Ce qui est corroboré, ce qui ne l'est pas

Aucune collection Ansible maintenue ne couvre l'API REST v2 de Centreon -
ce projet utilise `ansible.builtin.uri` directement, avec le même niveau
de confiance différencié que `ansible-centreon-downtime-create` :

- **Le flux d'authentification** (`roles/auth`) est identique à celui de
  `ansible-centreon-downtime-create` et corroboré par la documentation
  officielle `docs.centreon.com`.
- **L'endpoint de création d'acknowledgement**
  (`centreon_ack_endpoint`) est **volontairement laissé vide/obligatoire**
  pour les mêmes raisons que l'endpoint de downtime : le chemin exact
  varie selon la version de Centreon et n'a pas pu être corroboré avec
  assez de confiance. **Confirmez le chemin, la méthode HTTP et la forme
  exacte du corps JSON attendu sur la documentation API vivante de votre
  propre serveur** (`https://<serveur>/centreon/api/<version>/doc`). Les
  noms de champs utilisés par `roles/acknowledgement` (`target_type`,
  `host_id`, `service_id`, `comment`, `author`, `ticket_reference`,
  `sticky`, `notify`, `persistent`) sont une hypothèse de travail à
  valider/ajuster contre cette documentation.

## Résolution hôte/service

`centreon_host_id` (et `centreon_service_id` si
`centreon_ack_target_type: service`) doivent être les identifiants
numériques Centreon déjà connus. Ce projet ne fait aucun appel de
résolution nom → ID.

## Ticket obligatoire

`centreon_ack_ticket_reference` est toujours obligatoire (préflight
bloquant) - `CENTREON-ROADMAP.md` exige une référence de ticket
incident/changement pour tout acknowledgement en production, et ce
projet n'a pas de moyen fiable de distinguer un environnement de
production d'un environnement de test.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
credentials Centreon (`centreon_username`/`centreon_password`). Les
tâches d'authentification et de création d'acknowledgement sont en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-playbook playbooks/create_acknowledgement.yml --vault-password-file .vault_pass
```

Le résultat `centreon_acknowledgement_create_summary` est récupérable par
AAP et ServiceNow sans exposer les secrets ni le jeton d'API.
