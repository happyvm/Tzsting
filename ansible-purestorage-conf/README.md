# ansible-purestorage-conf

Configuration déclarative des services d'une baie Pure Storage FlashArray :
compte Active Directory de la baie, NTP, destinations syslog, fuseau horaire,
rotation du mot de passe du compte local `pureuser`, relais SMTP/destinataires
d'alerte email et SNMP (manager de traps et agent, SNMPv3 ou v2c).

## Sécurité

Les secrets (`pure_api_token`, compte de jonction AD, ancien/nouveau mot de
passe local et éventuel mot de passe SSH) doivent provenir d'Ansible Vault ou
d'un credential AAP. Les tâches sensibles utilisent `no_log`. Utiliser un
compte AD dédié à la jonction, aux droits minimaux, et valider LDAPS/TLS.

La collection `purestorage.flasharray` couvre AD, NTP, syslog et utilisateurs.
Elle n'expose pas de module de timezone dans la version épinglée : le rôle
timezone est donc un fallback CLI SSH, désactivé par défaut avec
`pure_timezone_cli_enabled: false`. Il faut valider la commande
`pureadmin setattr --timezone` sur la version Purity cible avant activation.
`pure_timezone` accepte les fuseaux IANA à deux ou trois niveaux (`Europe/Paris`
comme `America/Argentina/Buenos_Aires`).

Le préflight échoue avant toute action si une variable requise est absente ou
invalide, avec un message d'erreur explicite (aucune tâche de validation
n'utilise `no_log`, qui masquerait ce message).

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/configure_array.yml --vault-password-file .vault_pass
```

Adapter `inventory/group_vars/all.yml`. La liste `pure_syslog_servers` accepte
plusieurs destinations `udp`, `tcp` ou `tls`. `pure_local_user.old_password`
et `password` sont nécessaires à une rotation ; ne pas les mettre en clair.

SMTP (`pure_smtp_enabled: false` par défaut) et SNMP (`pure_snmp_enabled:
false` par défaut) sont désactivés par défaut. `pure_snmp_manager` (traps
sortants) et `pure_snmp_agent` (interrogation entrante) acceptent chacun
`version: v3` (utilisateur + passphrases d'authentification/confidentialité,
recommandé) ou `version: v2c` (chaîne de communauté). Les modules
`purefa_smtp`/`purefa_snmp`/`purefa_snmp_agent` ne peuvent pas relire l'état
caché (mot de passe SMTP, passphrases SNMP) pour comparer : ils rapportent
systématiquement un changement quand ces identifiants sont fournis, ce n'est
pas un bug de ce rôle. Le playbook publie `purestorage_conf_summary` pour
AAP/ServiceNow.
