# Roadmap d'automatisation ServiceNow / CMDB

Ce document décrit une brique Ansible autonome chargée de collecter les
informations réseau invitées depuis VMware vCenter ou Hyper-V via SCVMM, puis de
les réconcilier dans ServiceNow CMDB.

Le périmètre couvre exclusivement les interfaces réseau, les adresses MAC, les
adresses IPv4/IPv6 et la détermination contrôlée de l'adresse IP principale.
La collecte et la synchronisation du système d'exploitation sont hors périmètre.

## Principes

- aucune écriture directe dans les tables CMDB par simple appel CRUD lorsque
  l'objet relève de l'Identification and Reconciliation Engine (IRE) ;
- utilisation de l'API IRE avec une source de découverte dédiée et stable ;
- vCenter ou SCVMM est une source technique, sans devenir automatiquement
  l'autorité sur tous les attributs du CI ;
- collecte sans connexion SSH ou WinRM dans l'invité ;
- VMware Tools ou les services d'intégration Hyper-V doivent être présents,
  actifs et suffisamment récents ;
- une donnée absente ou périmée côté hyperviseur ne doit jamais effacer une
  valeur ServiceNow valide par défaut ;
- résolution du CI par identifiant stable de virtualisation, jamais uniquement
  par le nom de la VM ;
- inventaire de toutes les interfaces, adresses MAC et IP avant calcul d'une IP
  principale ;
- IPv4 et IPv6 conservées, avec règles explicites de filtrage et de priorité ;
- séparation des modes `collect`, `audit`, `plan` et `sync` ;
- aucun secret ServiceNow, vCenter ou SCVMM dans Git, les logs ou `set_stats` ;
- artefact AAP distinguant les données collectées, acceptées par IRE, ignorées,
  ambiguës ou en erreur.

## Catalogue cible

### `ansible-servicenow-vm-network-sync`

Collecte et synchronisation des informations réseau d'une ou plusieurs VM vers
ServiceNow CMDB.

### Sources supportées

#### VMware via vCenter

- résolution de la VM par Instance UUID, BIOS UUID, MoRef et nom ;
- contrôle de l'état VMware Tools et de la fraîcheur des données invitées ;
- collecte du hostname invité uniquement comme information de corrélation ;
- inventaire des cartes invitées, adresses MAC, réseaux, IPv4 et IPv6 ;
- collecte de l'IP primaire signalée par vCenter uniquement comme candidate ;
- collecte facultative du power state et de la version VMware Tools pour audit.

#### Hyper-V via SCVMM

- résolution de la VM par VM ID/GUID, identifiant SCVMM et nom ;
- rafraîchissement contrôlé de l'objet VMM avant lecture ;
- vérification de l'état des Integration Services et de la disponibilité des
  informations invitées ;
- collecte du ComputerName uniquement comme information de corrélation ;
- inventaire des cartes virtuelles, adresses MAC, IPv4 et IPv6 remontées par
  Hyper-V/SCVMM ;
- collecte facultative du host, du cluster, du power state et de la version des
  Integration Services pour audit.

Le projet publie `source_data_fresh=false` lorsqu'une VM est arrêtée, que les
outils invités ne fonctionnent pas ou que la source ne fournit pas une donnée
suffisamment fiable. Le mode `sync` refuse alors d'effacer les anciennes valeurs
ServiceNow.

### Identification du CI ServiceNow

Ordre proposé :

1. corrélation de source existante et `source_native_key` ;
2. VMware : BIOS UUID/Instance UUID selon la règle CMDB validée ;
3. Hyper-V : VM ID/GUID stable ;
4. corrélation secondaire par numéro de série ou UUID déjà présent ;
5. nom/FQDN uniquement comme aide à la détection, jamais comme identifiant unique
   automatique en présence d'une ambiguïté.

La classe cible est configurable et validée contre le modèle CMDB de
l'entreprise. La création d'un CI reste désactivée par défaut.

### Synchronisation des interfaces et adresses IP

- création ou mise à jour des cartes réseau associées au CI ;
- corrélation d'une interface par MAC normalisée et identifiant de carte lorsque
  disponible ;
- création ou mise à jour des enregistrements d'adresse IP et de leurs relations
  avec la carte et le CI ;
- conservation des adresses multiples par interface ;
- prise en compte des préfixes IPv4/IPv6 lorsque la source les fournit ;
- filtrage par défaut des adresses loopback, link-local, APIPA et non spécifiées ;
- allowlist/denylist de réseaux pour exclure backup, heartbeat, live migration,
  stockage, cluster ou réseaux techniques ;
- option pour conserver ces IP techniques dans la CMDB sans les rendre éligibles
  comme IP principale ;
- détection des adresses dupliquées observées sur plusieurs CI ;
- aucune suppression immédiate d'une IP disparue : marquage `stale` ou expiration
  après plusieurs collectes cohérentes ;
- refus d'écraser une IP administrativement fixée ou fournie par une source plus
  prioritaire selon les règles IRE.

### Calcul de l'IP principale

L'IP principale n'est jamais choisie selon l'ordre de retour de l'API.

Politique proposée :

1. adresse déjà déclarée principale dans ServiceNow et encore observée ;
2. adresse appartenant à une liste de réseaux de production priorisés ;
3. préférence IPv4 ou IPv6 selon la politique d'entreprise ;
4. adresse portée par une interface connectée et non technique ;
5. adresse correspondant au DNS direct et inverse du hostname invité ;
6. en cas d'égalité ou d'ambiguïté, ne pas modifier l'IP principale et publier
   `primary_ip_status=ambiguous`.

### Données complémentaires en audit uniquement

Le collecteur peut publier sans synchronisation par défaut :

- hostname/FQDN invité ;
- état de la VM ;
- hôte et cluster de résidence ;
- version et état VMware Tools/Integration Services ;
- identifiants UUID/GUID ;
- date de dernière collecte valide.

Artefact AAP : `servicenow_vm_network_sync_summary`.

## Variables proposées

```yaml
virtualization_provider: vmware_vcenter  # vmware_vcenter | hyperv_scvmm
virtualization_manager: vcenter.example.net
virtualization_validate_certs: true

vm_name: null
vm_native_id: null
sync_scope: single_vm  # single_vm | inventory_query | explicit_list
vm_query: null

servicenow_instance: https://example.service-now.com
servicenow_validate_certs: true
servicenow_ire_source_name: Ansible Virtualization Network Sync
servicenow_target_class: cmdb_ci_vm_instance
servicenow_operation: audit  # collect | audit | plan | sync
servicenow_allow_ci_create: false

sync_network_interfaces: true
sync_ip_addresses: true
sync_primary_ip: true
sync_hostname: false
sync_runtime_metadata: false

preferred_ip_family: ipv4  # ipv4 | ipv6 | any
primary_ip_preferred_networks: []
primary_ip_excluded_networks: []
retain_technical_ip_addresses: true
require_forward_dns_match: false
require_reverse_dns_match: false

stale_ip_grace_runs: 3
remove_stale_ip_relations: false
allow_clear_missing_values: false
fail_on_ambiguous_ci: true
fail_on_ambiguous_primary_ip: false
```

Les credentials vCenter, SCVMM et ServiceNow sont fournis par Credential AAP,
Ansible Vault ou un gestionnaire de secrets.

## Garde-fous

1. validation TLS par défaut sur les trois plateformes ;
2. accès ServiceNow à travers IRE et non par écriture directe aveugle ;
3. identifiant de source et clé native stables ;
4. aucune corrélation automatique sur le seul nom de VM ;
5. refus de créer un CI par défaut ;
6. contrôle de l'état et de la fraîcheur des outils invités ;
7. aucune suppression en cas de donnée source absente ou périmée ;
8. IP principale déterminée par politique et non par ordre de retour ;
9. détection des doublons d'IP et des CI ambigus ;
10. filtrage des réseaux techniques configurable et auditable ;
11. délai de grâce avant retrait d'une IP disparue ;
12. respect des règles d'autorité et de priorité IRE ;
13. mode `plan` publiant le diff avant synchronisation ;
14. verrou par CI et identifiant natif de VM ;
15. journalisation sans secret ni payload sensible ;
16. publication des attributs acceptés, ignorés et rejetés par IRE ;
17. nettoyage et libération des verrous dans un bloc `always`.

## Intégration AAP / ServiceNow

Job Templates distincts :

- collecte/audit VMware ;
- collecte/audit Hyper-V ;
- plan de réconciliation ServiceNow ;
- synchronisation réseau d'une VM ;
- synchronisation d'un lot limité ;
- rapport des CI ambigus, IP dupliquées et données invitées périmées.

Déclenchements recommandés :

- après création ou personnalisation d'une VM ;
- après changement d'adresse, ajout/retrait de carte ou changement de VLAN ;
- après restauration ou migration susceptible de modifier l'identité réseau ;
- en tâche de réconciliation périodique ;
- avant décommissionnement pour capturer le dernier état réseau.

Le workflow de création attend que VMware Tools ou les Integration Services
remontent une information stable, avec timeout borné, avant d'appeler le mode
`sync`. L'échec de cette synchronisation ne supprime pas la VM mais produit un
état partiellement réussi visible dans ServiceNow.

## Ordre de réalisation recommandé

1. collecteur VMware en lecture seule ;
2. collecteur SCVMM en lecture seule ;
3. modèle commun interfaces/MAC/IP ;
4. résolution IRE sans création de CI ;
5. mode `plan` et synchronisation des interfaces/IP ;
6. calcul de l'IP principale ;
7. gestion des IP périmées et des doublons ;
8. exécution par lots avec limites et reprise ;
9. intégration aux workflows create, changement réseau, restore et decommission.
