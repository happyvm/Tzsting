# ansible-satellite-activation-key-manage

Création, mise à jour ou suppression déclarative d'une **activation key**
Red Hat Satellite, via le vrai module `theforeman.foreman.activation_key`.
Le projet suit la méthodologie du dépôt : inventaire sans appliance
statique, préflight bloquant, secrets Vault/AAP, rôles séparés et
artefact `set_stats`.

Ce projet est l'étape 2 de l'ordre de réalisation recommandé dans
[`SATELLITE-ROADMAP.md`](../SATELLITE-ROADMAP.md).

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : création/mise à jour/suppression d'une activation key
(organisation, lifecycle environment + content view *ou* content view
environments multiples, host collections, content overrides, limite
d'hôtes, system purpose, release version, service level).

**Non couvert, volontairement** (voir
[`SATELLITE-ROADMAP.md`](../SATELLITE-ROADMAP.md)) : l'enregistrement ou
la désinscription d'hôtes, la création d'organisations/lifecycle
environments/content views, la promotion de contenu, l'affectation à un
host group. Ce sont des projets séparés du catalogue Satellite.

## `theforeman.foreman`, pas `redhat.satellite`

`redhat.satellite` (la collection officielle Red Hat) n'est distribuée
que via Red Hat Automation Hub, pas sur Galaxy public. Ce projet utilise
`theforeman.foreman`, la collection open source amont sur laquelle
`redhat.satellite` est construite - les mêmes modules, le même contrat
d'API Foreman/Katello. Le module `activation_key` a été vérifié via
`ansible-doc -j` contre la collection réellement installée avant
d'écrire ce rôle.

## Mode `audit`

`satellite_ak_operation: manage` par défaut. En `audit`, le rôle force le
*check mode* natif d'Ansible sur la tâche `theforeman.foreman.activation_key`
(`check_mode: true`), quel que soit l'appel de la playbook - un vrai
dry-run Ansible, pas un mécanisme maison.

## Content view vs content view environments

`satellite_ak_lifecycle_environment`/`satellite_ak_content_view` (une
paire classique) et `satellite_ak_content_view_environments` (plusieurs
environnements, un par content view) sont **mutuellement exclusifs** -
documentation du module elle-même. Le préflight bloque toute
configuration ambiguë (les deux vides, ou les deux renseignés) sauf en
mode `absent`, où seul le nom est nécessaire pour supprimer la clé.

## Authentification

`satellite_username`/`satellite_password`. Un jeton d'accès personnel
Foreman/Katello fonctionne aussi comme mot de passe avec le même nom
d'utilisateur (mécanisme Foreman documenté, pas spécifique à ce projet).

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
credentials Satellite. La tâche de gestion de la clé est en `no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/manage_activation_key.yml --vault-password-file .vault_pass
```

Tester d'abord en mode `audit`. Le résultat
`satellite_activation_key_summary` est récupérable par AAP et ServiceNow
sans exposer les secrets.
