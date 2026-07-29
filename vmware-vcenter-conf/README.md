# vmware-vcenter-conf

Configuration des services de l'appliance vCenter Server (VCSA) : NTP,
fuseau horaire, rotation du mot de passe administrateur local de
l'appliance, et niveau de journalisation du serveur vCenter.

## Contrat API VAMI

L'API de gestion de l'appliance (VAMI) qui expose NTP/timezone/compte
local n'est couverte par aucune collection Ansible maintenue - à la
différence des réglages généraux du serveur vCenter (journalisation,
SNMP...), qui sont couverts par le module
`community.vmware.vmware_vcenter_settings` et utilisés directement ici
(rôle `logging`). Pour éviter un appel vers un endpoint supposé, les
chemins VAMI suivants sont obligatoires et vides par défaut :

- `vcenter_conf_ntp_endpoint` ;
- `vcenter_conf_timezone_endpoint` ;
- `vcenter_conf_local_admin_endpoint`.

Les renseigner, avec les méthodes et payloads associés, depuis le guide
API VAMI de la version cible. Le préflight bloque toute exécution
incomplète.

## Sécurité

Les secrets (mots de passe API vCenter/SSO, VAMI, compte local) doivent
provenir d'Ansible Vault ou d'un credential AAP. Toutes les tâches HTTP
sont en `no_log`. `vcenter_hostname`/`username`/`password` et
`vmware_validate_certs` reprennent les mêmes noms que
`ansible-createvm`/`ansible-resizecompute`/`ansible-resizedisk`/etc, pour
réutiliser un jeu d'identifiants vCenter déjà existant.
`vcenter_vami_username`/`password` sont distincts (par défaut identiques
à `vcenter_username`/`password`) car certaines appliances exigent un
compte dédié (souvent `root`) pour l'API VAMI.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/configure_vcenter.yml --vault-password-file .vault_pass
```

Tester d'abord sur une appliance de qualification. Le résultat
`vcenter_conf_summary` est récupérable par AAP et ServiceNow sans exposer
les mots de passe.
