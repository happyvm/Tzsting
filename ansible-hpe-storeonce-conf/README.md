# ansible-hpe-storeonce-conf

Configuration des comptes locaux, Active Directory, NTP et timezone d'une
appliance **HPE StoreOnce**. Le playbook orchestre des appels HTTPS depuis
`localhost`, protège les secrets avec Vault/AAP et publie
`storeonce_conf_summary` pour AAP/ServiceNow.

## Contrat API StoreOnce

Les endpoints d'administration et leurs payloads dépendent de la branche
StoreOnce Software, du modèle et du mode appliance/federation. Aucune
collection Ansible HPE maintenue ne couvre uniformément ces quatre réglages.
Pour éviter un appel vers un endpoint supposé, les chemins suivants sont
obligatoires et vides par défaut :

- `storeonce_local_accounts_endpoint` ;
- `storeonce_ad_endpoint` ;
- `storeonce_ntp_endpoint` ;
- `storeonce_timezone_endpoint`.

Les renseigner, avec les méthodes et payloads associés, depuis le guide API de
la version cible. Le préflight bloque toute exécution incomplète. Les rôles
acceptent les succès HTTP 200/201/202/204 et utilisent la validation TLS. Le
profil fourni utilise Basic Auth ; si la version cible exige une création de
session ou un bearer token, implémenter ce flux documenté avant activation.

## Exploitation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-playbook playbooks/configure_storeonce.yml \
  --vault-password-file .vault_pass
```

Les credentials API, mots de passe locaux et credentials de jonction AD ne
doivent jamais être passés en clair. Tester sur une appliance de qualification,
exporter la configuration avant changement et conserver un compte local de
secours testé avant de modifier Active Directory.
