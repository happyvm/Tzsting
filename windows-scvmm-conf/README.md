# windows-scvmm-conf

Configuration déclarative des services du serveur de management System
Center Virtual Machine Manager (SCVMM) : jonction Active Directory
(optionnelle), compte local d'automatisation, NTP et fuseau horaire. Ce
projet configure le système d'exploitation Windows du serveur SCVMM
lui-même, pas SCVMM (réseaux logiques, VM Networks, host groups...) -
voir `windows-scvmm-addvlan`/`windows-scvmm-removevlan` pour cette partie.

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
(`scvmm_conf_ad_enabled: false`). Le playbook publie `scvmm_conf_summary`
pour AAP/ServiceNow.
