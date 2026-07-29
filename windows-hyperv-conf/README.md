# windows-hyperv-conf

Configuration déclarative des services d'un hôte Windows Server Hyper-V
natif : jonction Active Directory (optionnelle), compte local
d'automatisation, NTP et fuseau horaire. Contrairement à
`ansible-createvm`/`ansible-resizecompute`/etc., ce projet ne gère aucune
VM : il configure le système d'exploitation de l'hôte Hyper-V lui-même,
exactement comme `ansible-synergy-conf` ou `ansible-hpe-storeonce-conf` le
font pour leurs appliances respectives, mais via WinRM/PowerShell plutôt
qu'une API REST.

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
playbook publie `hyperv_conf_summary` pour AAP/ServiceNow.
