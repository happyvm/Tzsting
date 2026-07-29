# ansible-purestorage-volhost-remove

Suppression contrôlée de connexions, hostgroups, hosts et volumes Pure Storage
FlashArray. Ce projet est séparé de la création pour permettre un RBAC, une
approbation et un Job Template AAP plus stricts.

## Garde-fous et ordre

`confirm_remove=true` est obligatoire, ainsi qu'au moins un objet ou une
connexion à retirer (`pure_remove_hostgroups`, `pure_remove_hosts`,
`pure_remove_volumes` ou `pure_remove_host_volume_connections`) : un run qui
ne fait que déconnecter des mappings directs, sans supprimer de host, de
hostgroup ni de volume, est un usage valide et n'est pas bloqué par le
préflight. L'ordre évite de tenter de supprimer un objet encore utilisé :

1. déconnexion des mappings directs host-volume déclarés ;
2. suppression des hostgroups (et de leurs associations) ;
3. suppression des hosts ;
4. suppression des volumes en dernier.

Par défaut, un volume supprimé reste récupérable pendant la fenêtre
d'éradication de la baie. `pure_eradicate_volumes=true` est irréversible et
exige en plus `confirm_eradicate=true`. Une suppression de baie n'est pas une
procédure de sauvegarde : vérifier backup, réplication, protection group,
dépendances applicatives, multipathing et approbation du changement.

## Modèle de variables

```yaml
confirm_remove: true
pure_remove_host_volume_connections:
  - {host: linux01, volume: app01-data}
pure_remove_hostgroups: [esx-cluster01]
pure_remove_hosts: [esx01, linux01]
pure_remove_volumes: [app01-data]
pure_eradicate_volumes: false
```

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/remove_storage.yml \
  -e confirm_remove=true --vault-password-file .vault_pass
```

Le token API doit venir de Vault/AAP. Le playbook publie
`purestorage_remove_summary` comme artefact AAP/ServiceNow.
