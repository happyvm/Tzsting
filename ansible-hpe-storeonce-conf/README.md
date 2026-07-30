# ansible-hpe-storeonce-conf

Configuration des comptes locaux, Active Directory, NTP et timezone d'une
appliance **HPE StoreOnce**, plus redirection syslog, alertes SMTP et SNMP
en options. Le playbook orchestre des appels HTTPS depuis `localhost`,
protège les secrets avec Vault/AAP et publie `storeonce_conf_summary` pour
AAP/ServiceNow.

## Contrat API StoreOnce par release

Les endpoints d'administration, leurs méthodes et les fonctionnalités
disponibles dépendent de la branche StoreOnce Software, du modèle et du mode
appliance/federation. Aucune collection Ansible HPE maintenue ne couvre
uniformément ces réglages.

La branche est donc une **donnée d'entrée** : `storeonce_release` porte la
release de l'appliance (par exemple `-e storeonce_release=4.3.2`), et le rôle
`api_contract` la résout contre la table `storeonce_api_contracts` définie dans
`inventory/group_vars/all.yml`. Seul `major.minor` sélectionne le contrat —
le niveau de patch ne change pas la surface REST, mais il est conservé dans
l'artefact AAP pour la traçabilité.

Un même inventaire couvre ainsi un parc hétérogène : déclarer chaque branche
une fois, et toutes les appliances qui la font tourner sont prises en charge.

```yaml
storeonce_release: "4.3.2"

storeonce_api_contracts:
  "4.3":
    endpoints:
      local_accounts: /...      # depuis le guide API de CETTE release
      ad: /...
      ntp: /...
      timezone: /...
      syslog: /...
      smtp: /...
      snmp: /...
    methods:
      local_accounts: POST      # PUT/PATCH si la release documente un upsert
      ad: PUT
      ntp: PUT
      timezone: PUT
      syslog: PUT
      smtp: PUT
      snmp: PUT
    capabilities:
      snmp_v3: true             # false si la branche n'expose que v1/v2c
```

> **Les chemins livrés sont vides et les clés de branche sont des exemples.**
> Ils ne sont volontairement pas pré-remplis : ils doivent provenir du guide
> API de la release exacte visée. Un chemin repris d'une branche voisine peut
> résoudre vers une autre ressource et reconfigurer silencieusement le mauvais
> objet. Le préflight bloque tant qu'un chemin nécessaire est vide, en nommant
> la branche et le réglage à renseigner.

### Sélection des fonctionnalités

`capabilities` déclare ce que la branche expose réellement. Demander SNMPv3
sur une branche déclarée sans `snmp_v3` échoue au préflight avec un message
explicite, au lieu de laisser l'appliance retomber silencieusement sur une
configuration à community string.

### Surcharges par appliance

Les variables `storeonce_<réglage>_endpoint` et `storeonce_<réglage>_method`
restent acceptées et **priment** sur la table. Elles servent à épingler un
chemin pour une seule appliance sans dupliquer tout le contrat ; laissées
vides, elles n'écrasent rien. Un inventaire écrit pour la forme plate
précédente continue donc de fonctionner sans modification.

Les rôles acceptent les succès HTTP 200/201/202/204 et utilisent la validation
TLS. Le profil fourni utilise Basic Auth ; si la release visée exige une
création de session ou un bearer token, implémenter ce flux documenté avant
activation.

## Exploitation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-playbook playbooks/configure_storeonce.yml \
  --vault-password-file .vault_pass
```

Les credentials API, mots de passe locaux et credentials de jonction AD ne
doivent jamais être passés en clair. Tester sur une appliance de
qualification,
exporter la configuration avant changement et conserver un compte local de
secours testé avant de modifier Active Directory.
