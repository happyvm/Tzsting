# windows-scvmm-conf

Configuration déclarative des services du serveur de management System
Center Virtual Machine Manager (SCVMM) : jonction Active Directory
(optionnelle), compte local d'automatisation, NTP, fuseau horaire et SNMP
(en option). Ce projet configure le système d'exploitation Windows du
serveur SCVMM lui-même, pas SCVMM (réseaux logiques, VM Networks, host
groups...) - voir `windows-scvmm-addvlan`/`windows-scvmm-removevlan` pour
cette partie.

## Syslog, SMTP, SNMP : ce qui est possible et ce qui ne l'est pas

**SCVMM (l'application VMM elle-même) n'a aucune fonctionnalité native de
SMTP ou de SNMP** : ni réglage dans la console/le module PowerShell
`virtualmachinemanager` (`Get-SCNotification` concerne les notifications de
mise à jour d'un service template, pas l'email), ni génération de trap SNMP
propre à VMM. La seule intégration d'alerting de VMM est via **System
Center Operations Manager (SCOM)**, un produit à part entière (PRO tips) -
c'est SCOM, pas VMM, qui a un vrai canal de notification email ; SCOM n'a
pas de canal SNMP natif documenté non plus (nécessiterait un connecteur
tiers). Déployer/configurer SCOM est hors périmètre de ce projet.

Ce qui suit ne concerne donc **pas** l'application SCVMM mais le système
d'exploitation Windows du serveur qui l'héberge, comme pour
`windows-hyperv-conf` - le SNMP ci-dessous est l'agent SNMP générique de
l'OS (interrogeable, et capable de relayer les traps que Windows lui-même
génère), pas une alerte applicative de VMM sur l'état des VM/hôtes :

- **SNMP** (`scvmm_conf_snmp_enabled: false` par défaut) : installe la
  fonctionnalité Windows historique « SNMP Service » et la configure via le
  vrai module `community.windows.win_snmp` (chaînes de communauté en
  lecture seule + managers autorisés, confirmé par `ansible-doc -j`) - ce
  module et cette fonctionnalité **ne supportent pas SNMPv3** (v1/v2c
  uniquement, aucune option pour l'activer). Les destinations de trap ne
  sont couvertes par aucun module Ansible : elles sont positionnées
  directement via la clé de registre documentée
  `HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\TrapConfiguration\<communauté>`,
  avec un nettoyage des anciens emplacements non utilisés (jusqu'à
  `scvmm_conf_snmp_max_trap_slots`, 8 par défaut) pour rester déclaratif.
- **SMTP** : Windows Server n'expose aucun mécanisme de niveau OS pour
  l'envoi d'alertes email - contrairement à un tableau FlashArray ou à
  vCenter, il n'y a pas d'objet de configuration persistant équivalent à
  un relais SMTP. L'action « Envoyer un e-mail » du Planificateur de tâches
  a été retirée il y a plusieurs versions, et `Send-MailMessage` en
  PowerShell est un simple cmdlet ad hoc (marqué obsolète), pas un service
  à configurer. Ce projet n'offre donc pas de rôle SMTP. (SCOM, un produit
  séparé, gère l'alerting applicatif de SCVMM - hors périmètre de ce
  projet.)
- **Syslog** : aucun client syslog natif sur Windows Server. Une
  redirection nécessiterait soit un agent tiers, soit le transfert
  d'événements Windows (WEF/WEC) vers un collecteur - hors du périmètre de
  ce projet.

## Sécurité

Les secrets (mot de passe WinRM, compte de jonction AD, mot de passe du
compte local) doivent provenir d'Ansible Vault ou d'un credential AAP. Les
tâches sensibles utilisent `no_log`. Utiliser un compte de jonction AD
dédié, aux droits minimaux.

La jonction AD ne redémarre jamais le serveur : SCVMM devenant indisponible
pendant un redémarrage affecte tous les hôtes Hyper-V qu'il gère, donc le
redémarrage nécessaire pour finaliser la jonction est une action de
maintenance à planifier séparément.

`scvmm_conf_timezone` attend un identifiant de fuseau **Windows** (ex.
`Romance Standard Time`), pas un nom IANA (`Europe/Paris`) - voir `tzutil
/l` sur n'importe quel hôte Windows pour la liste complète.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/configure_scvmm.yml --vault-password-file .vault_pass
```

Aucun inventaire statique par hôte : le serveur cible est ajouté
dynamiquement à l'inventaire en mémoire depuis
`scvmm_conf_hostname`/`username`/`password`. Adapter
`inventory/group_vars/all.yml`. La jonction AD est désactivée par défaut
(`scvmm_conf_ad_enabled: false`), tout comme le SNMP
(`scvmm_conf_snmp_enabled: false`). Le playbook publie `scvmm_conf_summary`
pour AAP/ServiceNow.
