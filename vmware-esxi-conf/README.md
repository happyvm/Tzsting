# vmware-esxi-conf

Configuration déclarative des services d'un hôte ESXi **autonome** (sans
vCenter) : NTP, syslog distant, jonction Active Directory (optionnelle),
compte local d'automatisation et SNMP (optionnel). Utilise les mêmes
modules `community.vmware` que les autres projets de ce dépôt, connectés
directement à l'API de gestion de l'hôte ESXi plutôt qu'à un vCenter.

## SNMP

`esxi_conf_snmp_enabled: false` par défaut. Le module
`community.vmware.vmware_host_snmp` qui pilote l'agent SNMP embarqué de
l'hôte **n'implémente pas SNMPv3** (limitation documentée du module
lui-même) : seules les communautés v1/v2c et les cibles de trap sont
supportées. Il n'existe pas d'alternative SNMPv3 pour l'agent SNMP natif
ESXi dans `community.vmware` à ce jour ; si SNMPv3 est requis au niveau de
l'hôte, il faut passer par un outil tiers hors du périmètre de ce dépôt.

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
