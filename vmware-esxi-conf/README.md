# vmware-esxi-conf

Configuration déclarative des services d'un hôte ESXi **autonome** (sans
vCenter) : NTP, syslog distant, jonction Active Directory (optionnelle) et
compte local d'automatisation. Utilise les mêmes modules
`community.vmware` que les autres projets de ce dépôt, connectés
directement à l'API de gestion de l'hôte ESXi plutôt qu'à un vCenter.

## Sécurité

Les secrets (mot de passe API, compte de jonction AD, mot de passe du
compte local) doivent provenir d'Ansible Vault ou d'un credential AAP. Les
tâches sensibles utilisent `no_log`. Utiliser un compte de jonction AD
dédié, aux droits minimaux.

`esxi_conf_esxi_hostname` (le nom de l'hôte tel qu'enregistré auprès de
lui-même) est distinct de `esxi_conf_hostname` (le point de connexion) -
ils sont identiques par défaut, mais certains hôtes exposent un nom
différent (FQDN vs nom court) : ajuster si les modules ne retrouvent pas
l'hôte.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/configure_esxi.yml --vault-password-file .vault_pass
```

Adapter `inventory/group_vars/all.yml`. La jonction AD est désactivée par
défaut (`esxi_conf_ad_enabled: false`). Le playbook publie
`esxi_conf_summary` pour AAP/ServiceNow.
