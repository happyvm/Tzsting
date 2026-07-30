# ansible-quantum-dxi-conf

Configuration des services d'identité et de temps d'une appliance **Quantum
DXi** : comptes locaux, intégration Active Directory, NTP et timezone, plus
redirection syslog, alertes SMTP et SNMP en options. Le projet suit la
méthodologie du dépôt : inventaire sans appliance statique, préflight
bloquant, secrets Vault/AAP, rôles séparés et artefact `set_stats`.

## Contrat API DXi par release

Les endpoints d'administration, leurs méthodes et les fonctionnalités
disponibles dépendent de la branche logicielle DXi et de la génération de
l'appliance. Quantum ne publie pas de collection Ansible maintenue couvrant
uniformément ces réglages sur toutes les générations.

La branche est donc une **donnée d'entrée** : `dxi_release` porte la release
de l'appliance (par exemple `-e dxi_release=4.5.1`), et le rôle
`api_contract` la résout contre la table `dxi_api_contracts` définie dans
`inventory/group_vars/all.yml`. Seul `major.minor` sélectionne le contrat —
le niveau de patch ne change pas la surface REST, mais il est conservé dans
l'artefact AAP pour la traçabilité.

Un même inventaire couvre ainsi un parc hétérogène : déclarer chaque branche
une fois, et toutes les appliances qui la font tourner sont prises en charge.

```yaml
dxi_release: "4.5.1"

dxi_api_contracts:
  "4.5":
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

Les variables `dxi_<réglage>_endpoint` et `dxi_<réglage>_method` restent
acceptées et **priment** sur la table. Elles servent à épingler un chemin pour
une seule appliance sans dupliquer tout le contrat ; laissées vides, elles
n'écrasent rien. Un inventaire écrit pour la forme plate précédente continue
donc de fonctionner sans modification.

Les rôles acceptent les succès HTTP 200/201/202/204 et utilisent la validation
TLS. Le profil fourni utilise Basic Auth ; si la release visée exige une
création de session ou un bearer token, implémenter ce flux documenté avant
activation.

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
