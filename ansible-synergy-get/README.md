# ansible-synergy-get

Inventaire en lecture seule d'une lame HPE Synergy depuis OneView. Le playbook
retourne notamment : modèle, numéro de série, alimentation, état, profil
associé, port map physique et connexions du Server Profile. Ces dernières
contiennent les adresses MAC Ethernet et WWN/WWPN Fibre Channel attribuées par
OneView.

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/get_blade.yml \
  -e 'oneview_server_hardware_name=Encl1, bay 1' \
  -e oneview_server_profile_name=PROFILE-APP01 \
  --vault-password-file .vault_pass
```

Le profil est facultatif et est résolu depuis les faits matériels lorsqu'ils
exposent `serverProfileName`. Pour garantir la récupération des MAC/WWN
logiques, le fournir explicitement. `synergy_get_summary` est publié comme
artefact AAP/ServiceNow ; `physical_port_map` et
`mac_and_wwn_connections` conservent la structure native OneView pour ne pas
perdre d'identifiants spécifiques aux générations de cartes.
