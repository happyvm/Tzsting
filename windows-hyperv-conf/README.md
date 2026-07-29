# windows-hyperv-conf

Configuration déclarative des services d'un hôte Windows Server Hyper-V
natif : jonction Active Directory (optionnelle), compte local
d'automatisation, NTP, fuseau horaire et SNMP (en option). Contrairement à
`ansible-createvm`/`ansible-resizecompute`/etc., ce projet ne gère aucune
VM : il configure le système d'exploitation de l'hôte Hyper-V lui-même,
exactement comme `ansible-synergy-conf` ou `ansible-hpe-storeonce-conf` le
font pour leurs appliances respectives, mais via WinRM/PowerShell plutôt
qu'une API REST.

## Syslog, SMTP, SNMP : ce qui est possible et ce qui ne l'est pas

- **SNMP** (`hyperv_conf_snmp_enabled: false` par défaut) : installe la
  fonctionnalité Windows historique « SNMP Service » et la configure via le
  vrai module `community.windows.win_snmp` (chaînes de communauté en
  lecture seule + managers autorisés, confirmé par `ansible-doc -j`) - ce
  module et cette fonctionnalité **ne supportent pas SNMPv3** (v1/v2c
  uniquement, aucune option pour l'activer). Les destinations de trap ne
  sont couvertes par aucun module Ansible : elles sont positionnées
  directement via la clé de registre documentée
  `HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\TrapConfiguration\<communauté>`,
  avec un nettoyage des anciens emplacements non utilisés (jusqu'à
  `hyperv_conf_snmp_max_trap_slots`, 8 par défaut) pour rester déclaratif.
- **SMTP** : Windows Server n'expose aucun mécanisme de niveau OS pour
  l'envoi d'alertes email - contrairement à un tableau FlashArray ou à
  vCenter, il n'y a pas d'objet de configuration persistant équivalent à
  un relais SMTP. L'action « Envoyer un e-mail » du Planificateur de tâches
  a été retirée il y a plusieurs versions, et `Send-MailMessage` en
  PowerShell est un simple cmdlet ad hoc (marqué obsolète), pas un service
  à configurer. Ce projet n'offre donc pas de rôle SMTP.
- **Syslog** : aucun client syslog natif sur Windows Server. Une
  redirection nécessiterait soit un agent tiers, soit le transfert
  d'événements Windows (WEF/WEC) vers un collecteur - hors du périmètre de
  ce projet.

## Sécurité

Les secrets (mot de passe WinRM, compte de jonction AD, mot de passe du
compte local) doivent provenir d'Ansible Vault ou d'un credential AAP. Les
tâches sensibles utilisent `no_log`. Utiliser un compte de jonction AD
dédié, aux droits minimaux.

La jonction AD ne redémarre jamais l'hôte : un hôte Hyper-V héberge
généralement des VM en cours d'exécution, et le redémarrage nécessaire pour
finaliser la jonction est une action de maintenance à planifier
séparément, pas quelque chose à déclencher sans supervision depuis ce
playbook.

`hyperv_conf_timezone` attend un identifiant de fuseau **Windows** (ex.
`Romance Standard Time`), pas un nom IANA (`Europe/Paris`) - voir `tzutil
/l` sur n'importe quel hôte Windows pour la liste complète.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/configure_hyperv.yml --vault-password-file .vault_pass
```

Aucun inventaire statique par hôte : l'hôte cible est ajouté dynamiquement
à l'inventaire en mémoire depuis `hyperv_conf_hostname`/`username`/
`password`. Adapter `inventory/group_vars/all.yml`. La jonction AD est
désactivée par défaut (`hyperv_conf_ad_enabled: false`) - l'activer
explicitement et valider le payload avant utilisation en production. Le
SNMP est également désactivé par défaut
(`hyperv_conf_snmp_enabled: false`). Le playbook publie
`hyperv_conf_summary` pour AAP/ServiceNow.
