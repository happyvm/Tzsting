# ansible-quantum-dxi-conf

Configuration des services d'identité et de temps d'une appliance **Quantum
DXi** : comptes locaux, intégration Active Directory, NTP et timezone, plus
redirection syslog, alertes SMTP et SNMP en options. Le projet suit la
méthodologie du dépôt : inventaire sans appliance statique, préflight
bloquant, secrets Vault/AAP, rôles séparés et artefact `set_stats`.

## Contrat API dépendant du firmware

Quantum ne publie pas de collection Ansible maintenue couvrant uniformément
ces réglages sur toutes les générations DXi. Les chemins et schémas REST
changent selon le modèle et la version DXi. Le dépôt ne devine donc jamais un
endpoint destructif : les quatre variables `*_endpoint` ci-dessous sont vides
et le préflight refuse l'exécution tant qu'elles ne sont pas définies
d'après le guide API livré avec **la version cible** (ces quatre réglages
sont appliqués à chaque run) :

- `dxi_local_accounts_endpoint` et `dxi_local_accounts_method` ;
- `dxi_ad_endpoint` et `dxi_ad_method` ;
- `dxi_ntp_endpoint` et `dxi_ntp_method` ;
- `dxi_timezone_endpoint` et `dxi_timezone_method`.

Syslog, SMTP et SNMP sont désactivés par défaut (`dxi_syslog_enabled`/
`dxi_smtp_enabled`/`dxi_snmp_enabled: false`) : activer chacun explicitement
et renseigner son propre endpoint une fois validé sur la version cible.
`dxi_snmp_configuration` propose un modèle SNMPv3 (utilisateur + passphrases
d'authentification/confidentialité) ; certaines versions plus anciennes de
DXi n'exposent que v1/v2c sur cet endpoint - vérifier le guide API avant
activation.

Les payloads exemples sont également à aligner sur ce contrat. Cette approche
évite qu'un chemin supposé compatible configure une ressource différente.
Les appels utilisent HTTPS, validation de certificat et authentification
Basic. Si le firmware impose une session/token, adapter le rôle commun avant
production plutôt que de désactiver TLS.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : credentials API,
mots de passe locaux et compte de jonction AD. Toutes les tâches HTTP sont en
`no_log`. Utiliser un compte API aux droits minimaux et un compte de jonction
AD dédié.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-playbook playbooks/configure_dxi.yml --vault-password-file .vault_pass
```

Tester d'abord sur une appliance de qualification et sauvegarder sa
configuration. Le résultat `dxi_conf_summary` est récupérable par AAP et
ServiceNow sans exposer les mots de passe.
