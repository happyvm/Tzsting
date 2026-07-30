# ansible-satellite-hostgroup-add

Affectation idempotente d'un hôte existant à un **host group** Red Hat
Satellite, via le vrai module `theforeman.foreman.host`. Le projet suit
la méthodologie du dépôt : inventaire sans appliance statique, préflight
bloquant, secrets Vault/AAP, rôles séparés et artefact `set_stats`.

Ce projet est l'étape 4 de l'ordre de réalisation recommandé dans
[`SATELLITE-ROADMAP.md`](../SATELLITE-ROADMAP.md). Voir
`ansible-satellite-hostgroup-remove` (à venir) pour le retrait, une
opération volontairement séparée.

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : affectation d'un hôte déjà enregistré dans Satellite à un
host group (par titre, ex. `RHEL9/Production`), avec publication du
contexte avant application.

**Non couvert, volontairement** :

- l'enregistrement de l'hôte lui-même (`ansible-satellite-host-register`,
  projet séparé) ;
- l'exécution des rôles Ansible/classes Puppet hérités du host group -
  l'affectation ne déclenche rien d'autre que le changement d'appartenance ;
- **le mode `plan` complet décrit dans `SATELLITE-ROADMAP.md`** (diff
  calculé de chaque paramètre hérité - OS, activation keys, lifecycle
  environment, content view, paramètres). Ce projet publie l'état actuel
  de l'hôte et la définition du host group cible via
  `theforeman.foreman.host_info`/`hostgroup_info` (rôle
  `inspect_hostgroup`), mais ces modules renvoient un dictionnaire
  générique dont le schéma exact n'est pas documenté - calculer un diff
  fiable de chaque paramètre hérité nécessiterait de vérifier ce schéma
  contre une instance Satellite réelle, ce que cette implémentation ne
  fait pas encore. Utiliser le mode `audit` (voir plus bas) en attendant
  pour un aperçu via le *diff* natif d'Ansible.

## Mode `audit`

`satellite_hostgroup_add_operation: manage` par défaut. En `audit`, le
rôle `assign_hostgroup` force le *check mode* natif d'Ansible sur la
tâche `theforeman.foreman.host` (`check_mode: true`), quel que soit
l'appel de la playbook - un vrai dry-run Ansible.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
credentials Satellite. Les tâches de lecture et d'affectation sont en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/add_to_hostgroup.yml --vault-password-file .vault_pass
```

Tester d'abord en mode `audit`. Le résultat
`satellite_hostgroup_add_summary` est récupérable par AAP et ServiceNow
sans exposer les secrets.
