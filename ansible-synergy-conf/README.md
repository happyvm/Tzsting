# ansible-synergy-conf

Configuration d'une appliance HPE OneView pilotant une infrastructure Synergy :
NTP, timezone/locale, fournisseur Active Directory, compte administrateur
local d'automatisation, redirection syslog distante, alertes email SMTP et
SNMPv3 (utilisateurs et destinations de traps).

Le module officiel `hpe.oneview.oneview_appliance_time_and_locale_configuration`
gère NTP et timezone (`oneview_timezone` accepte les fuseaux IANA à deux ou
trois niveaux, ex. `America/Argentina/Buenos_Aires`) ; `oneview_user`
maintient le compte local. Le schéma des fournisseurs AD varie selon la
génération et la version API OneView : le rôle AD utilise l'API REST, reste
désactivé par défaut et exige un payload `oneview_ad_configuration`
préalablement validé sur l'appliance cible. Ne pas activer un exemple
générique en production. La session OneView ouverte pour cet appel REST est
systématiquement refermée (`block`/`always`), même en cas d'échec de la
configuration.

La redirection syslog et le relais SMTP suivent le même schéma que le rôle
AD : aucun module `hpe.oneview` ne les couvre, le contrat REST
(endpoint/payload) dépend de la version OneView, `oneview_syslog_api_path`/
`oneview_smtp_api_path` sont vides et désactivés par défaut
(`oneview_syslog_enabled`/`oneview_smtp_enabled: false`). SNMPv3
(`oneview_snmp_enabled: false` par défaut) utilise les vrais modules
`oneview_appliance_device_snmp_v3_users`/`_trap_destinations` ; le schéma du
`data` provient des exemples officiels du module, mais `securityLevel`/les
protocoles restent à valider selon la génération d'API de l'appliance cible.

Tous les mots de passe viennent de Vault/AAP. L'Execution Environment doit
faire confiance au certificat TLS OneView.

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/configure_synergy.yml --vault-password-file .vault_pass
```

Adapter `inventory/group_vars/all.yml`, notamment `oneview_api_version`, le
domaine de login, les NTP, la timezone et les permissions du compte local. Le
résultat est publié dans `synergy_conf_summary`.
