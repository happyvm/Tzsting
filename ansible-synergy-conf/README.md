# ansible-synergy-conf

Configuration d'une appliance HPE OneView pilotant une infrastructure Synergy :
NTP, timezone/locale, fournisseur Active Directory et compte administrateur
local d'automatisation.

Le module officiel `hpe.oneview.oneview_appliance_time_and_locale_configuration`
gère NTP et timezone ; `oneview_user` maintient le compte local. Le schéma des
fournisseurs AD varie selon la génération et la version API OneView : le rôle
AD utilise l'API REST, reste désactivé par défaut et exige un payload
`oneview_ad_configuration` préalablement validé sur l'appliance cible. Ne pas
activer un exemple générique en production.

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
