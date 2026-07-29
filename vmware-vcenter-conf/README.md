# vmware-vcenter-conf

Configuration des services de l'appliance vCenter Server (VCSA) : NTP,
fuseau horaire, rotation du mot de passe administrateur local de
l'appliance, redirection syslog (VAMI, en option), et réglages généraux du
serveur vCenter (journalisation, alertes SMTP et destinataires SNMP, ces
deux derniers en option).

## Contrat API VAMI

L'API de gestion de l'appliance (VAMI) qui expose NTP/timezone/compte
local/syslog n'est couverte par aucune collection Ansible maintenue - à la
différence des réglages généraux du serveur vCenter (journalisation, mail,
SNMP), qui sont couverts par le module
`community.vmware.vmware_vcenter_settings` et utilisés directement ici
(rôle `logging`). Pour éviter un appel vers un endpoint supposé, les
chemins VAMI suivants sont obligatoires et vides par défaut :

- `vcenter_conf_ntp_endpoint` ;
- `vcenter_conf_timezone_endpoint` ;
- `vcenter_conf_local_admin_endpoint`.

`vcenter_conf_syslog_endpoint` suit la même règle mais n'est requis que si
`vcenter_conf_syslog_enabled: true` (désactivé par défaut). Les renseigner,
avec les méthodes et payloads associés, depuis le guide API VAMI de la
version cible. Le préflight bloque toute exécution incomplète.

## SMTP et SNMP (rôle `logging`)

`community.vmware.vmware_vcenter_settings` gère la journalisation, le mail
et les destinataires SNMP en un seul appel API : chaque paramètre du module
a toujours une valeur (celle fournie, ou son défaut interne codé en dur
s'il est omis). Concrètement, exécuter ce module en ne passant que
`logging_options` (comme le faisait la version précédente de ce rôle)
réinitialise silencieusement le mail et les destinataires SNMP à chaque
run. Le rôle `logging` envoie donc désormais explicitement les trois
catégories à chaque exécution :

- `vcenter_conf_smtp_enabled: false` par défaut ; si `true`, `server` et
  `sender` sont requis (`vcenter_conf_smtp`) ;
- `vcenter_conf_snmp_enabled: false` par défaut ; `vcenter_conf_snmp_receivers`
  ne supporte que des chaînes de communauté v1/v2c - **aucun SNMPv3** pour
  les alertes vCenter dans `community.vmware` à ce jour ;
- quand l'une de ces options est désactivée, le rôle soumet explicitement
  des valeurs vides/désactivées (et non les défauts internes du module,
  dont le récepteur SNMP 1 par défaut est étonnamment `enabled: true` vers
  `localhost:162`), pour garantir un état désactivé sans dépendre d'un
  défaut non documenté.

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
