# Roadmap d'automatisation ServiceNow / CMDB

Ce document décrit une brique Ansible autonome chargée de collecter les
informations invitées depuis VMware vCenter ou Hyper-V via SCVMM, puis de les
réconcilier dans ServiceNow CMDB.

Le premier périmètre couvre les adresses IP et le système d'exploitation. Les
informations proviennent de VMware Tools ou des services d'intégration Hyper-V,
mais ServiceNow conserve ses règles d'identification, de réconciliation et
d'autorité des sources.

## Principes

- aucune écriture directe dans les tables CMDB par simple appel CRUD lorsque
  l'objet relève de l'Identification and Reconciliation Engine (IRE) ;
- utilisation de l'API IRE avec une source de découverte dédiée et stable ;
- vCenter ou SCVMM est une source technique, pas nécessairement l'autorité sur
  tous les attributs du CI ;
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
- artefact AAP stable permettant de distinguer collecté, accepté par IRE,
  ignoré par réconciliation, ambigu ou en erreur.

## Catalogue cible

### `ansible-servicenow-vm-guest-sync`

Collecte et synchronisation des données invitées d'une ou plusieurs VM vers
ServiceNow CMDB.

#### Sources supportées

**VMware via vCenter** :

- résolution de la VM par Instance UUID, BIOS UUID, MoRef et nom ;
- contrôle de l'état VMware Tools et de la fraîcheur des données invitées ;
- collecte du hostname invité ;
- collecte de `guestFullName`, `guestId`, famille d'OS et données détaillées
  lorsque disponibles ;
- inventaire des cartes invitées, adresses MAC, réseaux, IPv4 et IPv6 ;
- collecte de l'IP primaire signalée par vCenter uniquement comme candidat ;
- collecte facultative du power state, de la version VMware Tools et de la
  version matérielle pour audit.

**Hyper-V via SCVMM** :

- résolution de la VM par VM ID/GUID, identifiant SCVMM et nom ;
- rafraîchissement contrôlé de l'objet VMM avant lecture ;
- vérification de l'état des Integration Services et de la disponibilité des
  informations invitées ;
- collecte du ComputerName/hostname invité lorsque disponible ;
- collecte de l'objet OperatingSystem et de sa chaîne descriptive ;
- inventaire des cartes virtuelles, adresses MAC, IPv4 et IPv6 remontées par
  Hyper-V/SCVMM ;
- collecte facultative du host, du cluster, du power state et de la version des
  Integration Services pour audit.

Le projet doit publier `source_data_fresh=false` lorsqu'une VM est arrêtée, que
les outils invités ne fonctionnent pas ou que l'hyperviseur ne fournit pas une
information suffisamment fiable. Le mode `sync` refuse alors d'effacer les
anciennes valeurs ServiceNow.

#### Identification du CI ServiceNow

Ordre proposé :

1. recherche du CI par corrélation de source existante et `source_native_key` ;
2. VMware : BIOS UUID/Instance UUID selon la règle CMDB validée ;
3. Hyper-V : VM ID/GUID stable ;
4. corrélation secondaire par numéro de série/UUID déjà présent dans ServiceNow ;
5. nom/FQDN uniquement comme aide à la détection, jamais comme identifiant unique
   automatique en présence d'une ambiguïté.

La classe cible est configurable et validée contre le modèle CMDB de
l'entreprise. Le projet ne doit pas créer de nouveaux enregistrements dans une
ancienne classe VMware dépréciée. Une création éventuelle utilise la classe
`cmdb_ci_vm_instance` ou une sous-classe approuvée par le modèle CSDM/CMDB local.

#### Synchronisation des interfaces et adresses IP

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
  après un nombre configurable de collectes cohérentes ;
- refus d'écraser une IP administrativement fixée ou fournie par une source plus
  prioritaire selon les règles IRE.

#### Calcul de l'IP principale

L'IP principale ne doit jamais être choisie selon l'ordre de retour de l'API.
Politique proposée :

1. adresse déjà déclarée principale dans ServiceNow et encore observée ;
2. adresse appartenant à une liste de réseaux de production priorisés ;
3. IPv4 routable préférée à IPv6 lorsque la politique d'entreprise le demande ;
4. adresse portée par une interface connectée et non technique ;
5. adresse correspondant au DNS direct et inverse du hostname invité ;
6. en cas d'égalité ou d'ambiguïté, ne pas modifier l'IP principale et publier
   `primary_ip_status=ambiguous`.

Variables distinctes permettent de privilégier IPv6, une interface ou un réseau
selon le contexte.

#### Synchronisation du système d'exploitation

- collecte de la chaîne brute fournie par VMware Tools ou SCVMM ;
- conservation facultative de cette valeur brute dans un attribut technique ;
- normalisation par table de correspondance versionnée : famille, éditeur,
  produit, version et édition ;
- distinction Windows Server/Windows client et distributions Linux ;
- refus d'inventer une version précise lorsque la source ne fournit qu'une
  famille générique ;
- détection d'une incohérence entre l'OS configuré dans l'hyperviseur et l'OS
  réellement remonté par les outils invités ;
- mise à jour des champs ServiceNow uniquement si la source est autorisée pour
  ces attributs par les règles de réconciliation ;
- aucune reclassification automatique du CI vers une autre classe sans mode
  explicite et règle IRE validée.

#### Données complémentaires optionnelles

Le même collecteur peut publier en audit, sans les synchroniser par défaut :

- hostname/FQDN invité ;
- état de la VM ;
- hôte et cluster de résidence ;
- vCPU et mémoire ;
- version et état VMware Tools/Integration Services ;
- identifiants UUID/GUID ;
- date de dernière collecte valide.

Ces attributs ne deviennent synchronisables qu'après définition de leur source
d'autorité dans ServiceNow.

Artefact AAP : `servicenow_vm_guest_sync_summary`.

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
servicenow_ire_source_name: Ansible Virtualization Guest Sync
servicenow_target_class: cmdb_ci_vm_instance
servicenow_operation: audit  # collect | audit | plan | sync
servicenow_allow_ci_create: false

sync_ip_addresses: true
sync_primary_ip: true
sync_operating_system: true
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
allow_ci_reclassification: false

os_normalization_map: {}
fail_on_ambiguous_ci: true
fail_on_ambiguous_primary_ip: false
```

Les credentials vCenter, SCVMM et ServiceNow sont fournis par Credential AAP,
Ansible Vault ou un gestionnaire de secrets.

## Garde-fous

1. validation TLS par défaut sur les trois plateformes ;
2. accès ServiceNow à travers IRE et non par écriture directe aveugle du CI ;
3. identifiant de source et clé native stables ;
4. aucune corrélation automatique sur le seul nom de VM ;
5. refus de créer un CI par défaut ;
6. contrôle de l'état et de la fraîcheur des outils invités ;
7. aucune suppression d'une valeur en cas de donnée source absente ou périmée ;
8. IP principale déterminée par politique et non par ordre de retour ;
9. détection des doublons d'IP et des CI ambigus ;
10. filtrage des réseaux techniques configurable et auditable ;
11. délai de grâce avant retrait d'une IP disparue ;
12. normalisation OS versionnée avec conservation de la valeur brute ;
13. respect des règles d'autorité et de priorité IRE par attribut ;
14. mode `plan` publiant le diff avant synchronisation ;
15. verrou par CI et par identifiant natif de VM ;
16. journalisation sans token, mot de passe ni payload sensible ;
17. publication des attributs acceptés, ignorés et rejetés par IRE ;
18. nettoyage et libération des verrous dans un bloc `always`.

## Intégration AAP / ServiceNow

Job Templates distincts :

- collecte/audit VMware ;
- collecte/audit Hyper-V ;
- plan de réconciliation ServiceNow ;
- synchronisation d'une VM ;
- synchronisation d'un lot limité ;
- rapport des CI ambigus, IP dupliquées et données invitées périmées.

Déclenchements recommandés :

- après création ou personnalisation d'une VM ;
- après changement d'adresse, ajout/retrait de carte ou changement de VLAN ;
- après upgrade majeur de l'OS ;
- après migration ou restauration susceptible de modifier l'identité réseau ;
- en tâche de réconciliation périodique ;
- avant décommissionnement pour capturer le dernier état technique.

Le workflow de création doit attendre que VMware Tools ou les Integration
Services remontent une information stable, avec timeout borné, avant d'appeler le
mode `sync`. L'échec de cette synchronisation ne doit pas supprimer la VM, mais
le workflow doit terminer dans un état partiellement réussi visible dans
ServiceNow.

## Ordre de réalisation recommandé

1. collecteur VMware en lecture seule ;
2. collecteur SCVMM en lecture seule ;
3. modèle commun interfaces/MAC/IP/OS ;
4. résolution IRE sans création de CI ;
5. mode `plan` et synchronisation IP ;
6. normalisation et synchronisation OS ;
7. gestion des IP périmées et des doublons ;
8. exécution par lots avec limites et reprise ;
9. intégration aux workflows create, resize réseau, upgrade et restore.

## Validation attendue

- tests unitaires des collecteurs VMware et SCVMM ;
- fixtures multi-NIC, IPv4/IPv6, APIPA, link-local et réseaux techniques ;
- tests avec VMware Tools arrêté, absent et données invitées périmées ;
- tests avec Integration Services indisponibles et VM arrêtée ;
- tests de corrélation UUID/GUID et noms dupliqués ;
- mocks IRE : création interdite, source non autorisée, attribut ignoré et CI ambigu ;
- tests de calcul déterministe de l'IP principale ;
- tests de non-effacement lors d'une collecte incomplète ;
- tests de normalisation Windows et Linux ;
- tests de délai de grâce avant retrait d'une IP ;
- environnement ServiceNow de test avec règles IRE représentatives ;
- matrice vCenter/VMware Tools × SCVMM/Integration Services × version ServiceNow.
