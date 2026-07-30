# Roadmap d'automatisation — gestion de parc et agents

Ce document complète [`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md),
[`CENTREON-ROADMAP.md`](CENTREON-ROADMAP.md) et
[`VEEAM-NETBACKUP-ROADMAP.md`](VEEAM-NETBACKUP-ROADMAP.md).

Il décrit des projets Ansible autonomes pour Configuration Manager (SCCM),
WSUS, Azure Arc, Centreon/NRPE et Flexera. Chaque brique doit pouvoir être
récupérée et exécutée indépendamment des autres projets du dépôt.

## Statut de réalisation

🟡 **`ansible-azure-arc-agent-deploy`** (Lot 1, étape 3) implémenté comme
une enveloppe fine autour du rôle officiel
`azure.azcollection.azure_arc` (documenté par Microsoft pour cet usage
précis), plutôt qu'une réimplémentation d'`azcmagent` - installation,
idempotence et refus de re-enregistrer une machine déjà connectée à un
autre tenant/cloud/resource group/location sont hérités gratuitement du
rôle officiel. Authentification par service principal uniquement (pas
de CLI interactif ni d'identité managée, pour rester cohérent avec le
modèle Vault/Credential AAP du dépôt). `azcmagent check` (validation
réseau préalable) n'est pas exposé par le rôle officiel et n'est donc pas
automatisé. `ansible-centreon-nrpe-agent-deploy` (étape 2, Linux
uniquement) et `ansible-flexera-agent-deploy` (étape 1) restent
respectivement partiel et à faire.

🟡 **`ansible-sccm-conf`** (Lot 2, étape 5) implémenté pour une première
version limitée aux **boundaries et boundary groups** uniquement -
délibérément plus étroit que le périmètre complet proposé par la
roadmap (comptes/groupes AD, RBAC, méthodes de découverte, client
settings, mode HTTPS/PKI, fallback status point restent à faire), mais
la partie la plus concrètement spécifiée et la seule dont chaque cmdlet
a été vérifié individuellement contre la documentation officielle avant
d'écrire le code. Découverte du site (code/nom/version, boundaries,
boundary groups, management/distribution points) toujours exécutée ;
gestion des boundaries gardée par `sccm_conf_manage_boundaries=false`
par défaut (le garde-fou explicite que la roadmap exige pour cette
catégorie à fort impact). Mode `audit` via le `-WhatIf` natif de chaque
cmdlet (`New-CMBoundary`/`New-CMBoundaryGroup`/`Add-CMBoundaryToGroup`),
comme les projets device-collection - contrairement aux projets WSUS qui
appellent une API brute sans dry-run natif. `ansible-sccm-client-deploy`
(étape 6), `ansible-sccm-device-collection-add` (étape 7) et
`ansible-sccm-device-collection-remove` (étape 8) sont déjà implémentés
- voir leurs README.

🟡 **Tout le Lot 3 (WSUS) est implémenté** :
`ansible-wsus-computer-group-create` (étape 10, via la méthode brute
`IUpdateServer.CreateComputerTargetGroup`, aucune cmdlet dédiée
n'existant),
`ansible-wsus-computer-group-add` (étape 11, via la vraie cmdlet
`Add-WsusComputer`), et
`ansible-wsus-computer-group-remove` (étape 12, via
`IUpdateServer.GetComputerTargetByName`/`IComputerTargetGroup.RemoveComputerTarget`).

## Principes communs

- aucune écriture directe dans les bases SCCM, SUSDB, Centreon ou Flexera ;
- API, modules PowerShell et outils éditeur officiellement supportés privilégiés ;
- découverte de version et des capacités avant toute mutation ;
- installation d'un agent distincte de l'enregistrement dans un groupe,
  une collection ou un tenant ;
- retrait d'un groupe ou d'une collection distinct de la désinstallation de
  l'agent et de la suppression de l'objet machine ;
- packages provenant uniquement d'un dépôt interne approuvé, avec checksum ;
- TLS et validation des certificats activés par défaut ;
- aucun secret dans `group_vars`, les logs ou les artefacts `set_stats` ;
- modes `install`, `upgrade`, `configure`, `audit` et `plan` séparés lorsque
  l'outil le permet ;
- redémarrage interdit par défaut ;
- résolution non ambiguë par identifiant éditeur, FQDN, nom canonique et
  identifiant machine ;
- nettoyage des médias temporaires et libération des verrous dans un bloc
  `always`.

---

## Configuration Manager / SCCM

### `ansible-sccm-conf`

Configuration déclarative d'une infrastructure Microsoft Configuration Manager
existante. Le projet ne réalise pas l'installation initiale d'un site SCCM.

Périmètre proposé :

- découverte du site code, du SMS Provider et de la version Configuration Manager ;
- validation du module PowerShell `ConfigurationManager` ;
- comptes/groupes Active Directory utilisés pour l'administration et le client push ;
- RBAC minimal pour le compte d'automatisation ;
- méthodes de découverte explicitement déclarées ;
- boundaries et boundary groups ;
- association des management points et distribution points aux boundary groups ;
- paramètres de site nécessaires au déploiement client ;
- client settings de référence, inventaire matériel/logiciel et fréquence de policy ;
- Enhanced HTTP ou PKI/HTTPS selon le mode retenu ;
- fallback status point lorsque utilisé ;
- validation WMI, SMS Provider, services et composants de site ;
- mode `configure`, `audit` et `plan` ;
- aucune création ou modification implicite de déploiement applicatif.

Les éléments à fort impact, comme la modification des méthodes de découverte,
des boundaries ou du mode HTTPS, doivent être activés par variables explicites.

Artefact AAP : `sccm_conf_summary`.

🟡 Implémenté dans [`ansible-sccm-conf`](../ansible-sccm-conf), limité
à cette première version aux boundaries et boundary groups
(`New-CMBoundary`/`New-CMBoundaryGroup`/`Add-CMBoundaryToGroup`,
gardé par `sccm_conf_manage_boundaries=false`), avec une découverte du
site toujours exécutée. Non couvert : comptes/groupes AD, RBAC, méthodes
de découverte, client settings, mode HTTPS/PKI, fallback status point,
validation approfondie WMI/services.

### `ansible-sccm-client-deploy`

Installation, réparation ou mise à niveau du client Configuration Manager sur
un serveur Windows physique ou virtuel :

- découverte de la version du client et de l'identité du site ;
- validation que la machine est découverte/importée lorsque le mode de
  déploiement choisi l'exige ;
- installation par client push via SCCM ou exécution contrôlée de `ccmsetup.exe` ;
- sources provenant d'un distribution point ou d'un dépôt interne approuvé ;
- configuration du site code, management point, source et fallback status point ;
- options PKI, Enhanced HTTP, certificat client et validation CRL ;
- nettoyage préalable d'une installation cassée uniquement en mode réparation ;
- contrôle du service `CcmExec`, de WMI, du certificat et de l'enregistrement ;
- déclenchement facultatif des cycles machine policy et discovery data ;
- contrôle de l'apparition du client comme actif dans SCCM ;
- modes `install`, `repair`, `upgrade` et `audit` ;
- redémarrage interdit par défaut ;
- désinstallation dans un projet ou mode séparé avec confirmation explicite.

Artefact AAP : `sccm_client_deploy_summary`.

🟡 Implémenté dans [`ansible-sccm-client-deploy`](../ansible-sccm-client-deploy) :
`ccmsetup.exe` exécuté directement (checksum obligatoire du média),
modes `install`/`repair`/`upgrade`/`audit`, vérification bornée post-
installation (`SMS_Client`, `CcmExec`, site assigné), déclenchement
facultatif des cycles policy/discovery. Non couvert : client push
console, ajout à une device collection, vérification côté-site "actif",
désinstallation.

### `ansible-sccm-device-collection-add`

Ajout idempotent d'une machine dans une device collection SCCM existante :

- résolution exacte de la collection et du device ;
- validation de la limiting collection ;
- ajout par direct membership rule uniquement par défaut ;
- refus de modifier silencieusement une collection dont le périmètre est piloté
  uniquement par query, include ou exclude rules ;
- détection des doublons par ResourceID, GUID, FQDN et nom NetBIOS ;
- création facultative d'une include/exclude rule dans un mode séparé ;
- déclenchement facultatif d'une mise à jour de collection ;
- attente bornée et vérification de l'appartenance effective ;
- aucune installation du client et aucun déploiement applicatif implicites.

Artefact AAP : `sccm_device_collection_add_summary`.

🟡 Implémenté dans [`ansible-sccm-device-collection-add`](../ansible-sccm-device-collection-add) :
résolution exacte du device (ResourceId ou nom exact,
`-DisableWildcardHandling`) et de la collection, ajout d'une direct
membership rule idempotent, avertissement non bloquant sur les règles
query/include/exclude existantes, mise à jour facultative de la
collection. Non couvert : installation du client, création de la
collection.

### `ansible-sccm-device-collection-remove`

Retrait contrôlé d'une machine d'une device collection SCCM :

- résolution exacte de la collection, du device et de la règle responsable ;
- suppression de la direct membership rule correspondant au ResourceID ;
- refus de promettre un retrait durable si la machine reste incluse par une query,
  une include collection ou une règle externe ;
- mode `plan` publiant les règles qui maintiennent potentiellement l'appartenance ;
- déclenchement facultatif d'une mise à jour de collection ;
- vérification finale de l'absence effective ;
- aucune suppression de l'objet device SCCM ;
- aucune désinstallation du client ;
- aucune suppression de la machine Active Directory ou CMDB ;
- confirmation `confirm_remove_from_collection=true`.

Artefact AAP : `sccm_device_collection_remove_summary`.

🟡 Implémenté dans [`ansible-sccm-device-collection-remove`](../ansible-sccm-device-collection-remove) :
suppression d'une direct membership rule idempotente, vérification
immédiate après suppression, publication de trois indicateurs distincts
(`query_rule_present`/`include_rule_present`/`exclude_rule_present`)
plutôt qu'un blocage, confirmation `confirm_remove_from_collection=true`
obligatoire. Non couvert : suppression de l'objet device, désinstallation
du client, suppression Active Directory/CMDB.

---

## WSUS

WSUS ne possède pas un agent séparé à installer : les machines utilisent le
Windows Update Agent intégré à Windows. Le projet agit sur les groupes WSUS et
sur des clients ayant déjà contacté le serveur.

### `ansible-wsus-computer-group-create`

Création déclarative d'un groupe d'ordinateurs WSUS utilisé comme anneau ou
groupe de diffusion :

- connexion au serveur WSUS via les cmdlets/API `UpdateServices` ;
- nom unique, description et convention de nommage ;
- validation que le groupe n'est pas un groupe système réservé ;
- création idempotente ;
- association facultative à une définition de ring documentée dans les variables ;
- aucun approval de mise à jour créé implicitement ;
- aucun accès direct à SUSDB.

Artefact AAP : `wsus_computer_group_create_summary`.

🟡 Implémenté dans [`ansible-wsus-computer-group-create`](../ansible-wsus-computer-group-create) :
validation du nom (caractères interdits, longueur, groupes réservés),
création idempotente via `IUpdateServer.CreateComputerTargetGroup`
(aucune cmdlet dédiée n'existe pour cette opération). Non couvert :
association à une définition de ring (laissée à l'exploitant via le nom
du groupe lui-même).

### `ansible-wsus-computer-group-add`

Ajout ou déplacement contrôlé d'une machine déjà enregistrée dans WSUS vers un
groupe de diffusion :

- résolution par WSUS computer target ID, FQDN ou nom exact ;
- refus si la machine n'a jamais contacté le serveur WSUS ;
- détection des objets dupliqués ou obsolètes ;
- ajout au groupe cible sans supprimer les autres appartenances par défaut ;
- mode `move` distinct pour retirer les groupes non conservés ;
- contrôle du ciblage serveur ou client ;
- avertissement ou blocage si une GPO de client-side targeting risque de
  réappliquer une autre appartenance ;
- vérification finale de l'appartenance ;
- aucun déclenchement de patch ou de redémarrage implicite.

Artefact AAP : `wsus_computer_group_add_summary`.

🟡 Implémenté dans [`ansible-wsus-computer-group-add`](../ansible-wsus-computer-group-add) :
résolution exacte sur `FullDomainName` (jamais la correspondance
partielle de `-NameIncludes`), refus si la machine n'a jamais reporté de
statut, ajout idempotent via la vraie cmdlet `Add-WsusComputer` (mode
`audit` via son propre `-WhatIf` natif), vérification finale de
l'appartenance. Le ciblage client-side (GPO) n'est pas détecté
automatiquement - publié via une variable déclarée par l'exploitant.
Non couvert : le mode `move` (retrait des autres groupes).

### `ansible-wsus-computer-group-remove`

Retrait d'une machine d'un groupe WSUS :

- résolution exacte de la machine et du groupe ;
- refus de supprimer l'objet machine de WSUS par défaut ;
- conservation de l'appartenance au groupe système `Unassigned Computers` selon
  le comportement WSUS ;
- détection du client-side targeting et du risque de réaffectation par GPO ;
- retrait d'un groupe précis sans modifier les autres groupes ;
- vérification finale ;
- aucun changement des approvals, deadlines ou classifications ;
- confirmation `confirm_remove_from_wsus_group=true`.

Artefact AAP : `wsus_computer_group_remove_summary`.

🟡 Implémenté dans [`ansible-wsus-computer-group-remove`](../ansible-wsus-computer-group-remove) :
résolution directe via `IUpdateServer.GetComputerTargetByName` (retourne
un vrai `IComputerTarget`, sans passer par l'objet wrapper
`WsusComputer` des cmdlets), retrait via
`IComputerTargetGroup.RemoveComputerTarget` (déplace documentairement
vers `Unassigned Computers`), idempotence vérifiée via
`IComputerTarget.GetComputerTargetGroups()` avant et après, confirmation
`confirm_remove_from_wsus_group=true` obligatoire. Non couvert :
suppression de l'objet machine, changement d'approval/deadline/
classification.

---

## Azure Arc-enabled Servers

### `ansible-azure-arc-agent-deploy`

Installation, mise à niveau et enregistrement d'une machine Windows ou Linux
dans Azure Arc-enabled Servers :

- utilisation prioritaire du rôle officiel de la collection `azure.azcollection` ;
- détection de l'OS, de l'architecture et de la version de l'Azure Connected
  Machine agent ;
- validation des prérequis réseau, proxy, TLS et endpoints Azure ;
- installation depuis le dépôt Microsoft ou un miroir interne approuvé ;
- authentification par service principal, workload identity ou mécanisme
  d'onboarding approuvé, fourni via Credential AAP ;
- enregistrement dans le tenant, la subscription, le resource group et la région
  explicitement indiqués ;
- support des clouds Azure public/souverains via variable allowlistée ;
- nom de ressource, tags, location physique et correlation ID ;
- prise en compte d'un proxy ou d'Azure Arc gateway ;
- vérification avec `azcmagent show` et `azcmagent check` ;
- contrôle que la ressource Azure créée correspond à l'identité locale attendue ;
- refus d'enregistrer une machine déjà connectée à un autre tenant sans workflow
  de transfert explicite ;
- modes `install`, `upgrade`, `connect` et `audit` ;
- déconnexion et désinstallation séparées, avec approbation ;
- aucune installation d'extension Azure implicite.

Artefact AAP : `azure_arc_agent_deploy_summary`.

🟡 Implémenté dans [`ansible-azure-arc-agent-deploy`](../ansible-azure-arc-agent-deploy) :
enveloppe fine du rôle officiel `azure.azcollection.azure_arc`
(installation, idempotence, refus de re-enregistrement croisé hérités du
rôle), authentification par service principal uniquement, mode `audit`
(avec ses limites documentées dans le README - le rôle officiel exécute
toujours pour de vrai sa requête de jeton Azure AD et son `azcmagent
show`, seule la commande `connect` elle-même est simulée). Non couvert :
`azcmagent check`, CLI interactif/identité managée, déconnexion/
désinstallation.

---

## Centreon — agent NRPE

### `ansible-centreon-nrpe-agent-deploy`

Installation et configuration d'un agent compatible NRPE pour la supervision
Centreon sur Windows ou Linux :

- Linux : NRPE4 et plugins Centreon compatibles avec la distribution ;
- Windows : NSClient++ en mode NRPE uniquement pour les environnements qui le
  nécessitent explicitement ;
- découverte de l'OS, de l'architecture, de la version de l'agent et des plugins ;
- packages issus des dépôts Centreon ou d'un miroir interne approuvé ;
- configuration de la liste exacte des pollers autorisés ;
- port, TLS, timeout, taille de payload et paramètres NRPE négociés ;
- allowlist de commandes et de plugins ;
- interdiction des commandes arbitraires et des arguments non validés ;
- ouverture ciblée du pare-feu uniquement depuis les pollers déclarés ;
- installation des plugins locaux requis par les host templates choisis ;
- contrôle du service et test `check_nrpe` depuis le poller ;
- publication des macros/paramètres nécessaires à
  `ansible-centreon-host-add`, sans créer l'hôte implicitement ;
- modes `install`, `upgrade`, `configure` et `audit` ;
- redémarrage de l'agent autorisé, redémarrage du serveur interdit par défaut.

Pour les nouveaux déploiements, le projet doit signaler que Centreon Monitoring
Agent (CMA) est le chemin moderne recommandé. Le backend Windows NRPE, désormais
historique, nécessite `allow_legacy_windows_nrpe=true`. Une évolution future
pourra être publiée sous `ansible-centreon-cma-agent-deploy`.

Artefact AAP : `centreon_nrpe_agent_deploy_summary`.

🟡 Implémenté pour Linux dans
[`ansible-centreon-nrpe-agent-deploy`](../ansible-centreon-nrpe-agent-deploy) :
installation depuis un dépôt interne approuvé, `nrpe.cfg` (pollers
autorisés, commandes allowlistées), pare-feu ciblé, contrôle du service,
publication des macros/paramètres pour `ansible-centreon-host-add`. Non
couvert : Windows/NSClient++, la résolution nom → ID (n'importe pas ici,
ce projet ne parle qu'à l'hôte lui-même), et le passage à CMA.

---

## Flexera Inventory Agent

### `ansible-flexera-agent-deploy`

Installation, configuration et mise à niveau du FlexNet Inventory Agent sur
Windows et Linux/Unix, avec rattachement à un Inventory Beacon :

- détection de l'OS, de l'architecture, de la version installée et de l'identité
  Flexera existante ;
- packages et bootstrap configuration provenant d'un beacon ou d'un dépôt interne
  approuvé ;
- validation de checksum et de signature ;
- installation silencieuse sans réinitialiser l'identité d'un agent existant ;
- configuration du bootstrap beacon, des download locations et reporting locations ;
- import contrôlé de la configuration avec les outils Flexera, dont `mgsconfig`
  sur les plateformes Unix-like lorsque requis ;
- configuration du proxy, du certificat et de la validation TLS ;
- récupération de la policy depuis le beacon et vérification de la hiérarchie de
  beacons effectivement reçue ;
- paramètres de schedule, inventaire matériel/logiciel et usage tracking selon
  une configuration déclarée ;
- modes `install`, `upgrade`, `configure` et `audit` ;
- support du self-update piloté par policy ou d'une version forcée ;
- refus de downgrade par défaut ;
- exécution facultative d'un inventaire de validation ;
- contrôle du fichier d'inventaire produit et de son upload vers le beacon ;
- absence de secrets ou mots de passe de beacon dans les logs ;
- désinstallation et purge d'identité séparées, avec confirmation explicite.

Artefact AAP : `flexera_agent_deploy_summary`.

---

## Matrice cible

| Projet | Windows | Linux/Unix | Configuration plateforme | Agent | Groupe/collection | Mutation |
|---|:--:|:--:|:--:|:--:|:--:|---|
| `sccm-conf` | Oui | — | Oui | — | — | Configuration |
| `sccm-client-deploy` | Oui | — | — | Oui | — | Installation/upgrade |
| `sccm-device-collection-add` | Oui | — | — | — | Oui | Ajout |
| `sccm-device-collection-remove` | Oui | — | — | — | Oui | Retrait du scope |
| `wsus-computer-group-create` | Oui | — | Groupe | Natif Windows | Oui | Création |
| `wsus-computer-group-add` | Oui | — | — | Natif Windows | Oui | Ajout/déplacement |
| `wsus-computer-group-remove` | Oui | — | — | Natif Windows | Oui | Retrait du scope |
| `azure-arc-agent-deploy` | Oui | Oui | Tenant Azure | Oui | Resource group/tags | Installation/enregistrement |
| `centreon-nrpe-agent-deploy` | Oui, legacy | Oui | — | Oui | Via Centreon séparé | Installation/configuration |
| `flexera-agent-deploy` | Oui | Oui | Beacon/policy | Oui | Inventory groups via policy | Installation/configuration |

## Variables communes proposées

```yaml
endpoint_operation: audit  # install | upgrade | configure | add | remove | audit | plan
endpoint_name: srv-example.example.net
endpoint_os_family: windows  # windows | linux
allow_reboot: false
package_source_mode: internal_repository
package_checksum_required: true
validate_certs: true

sccm_site_code: P01
sccm_collection_name: Servers-Ring-1
confirm_remove_from_collection: false

wsus_server: wsus.example.net
wsus_group_name: Servers-Ring-1
wsus_targeting_mode: server  # server | client
confirm_remove_from_wsus_group: false

azure_tenant_id: null
azure_subscription_id: null
azure_resource_group: rg-arc-production
azure_location: francecentral
azure_cloud: AzureCloud
azure_arc_tags: {}

centreon_pollers: []
centreon_agent_backend: nrpe4  # nrpe4 | nsclient_nrpe
allow_legacy_windows_nrpe: false

flexera_bootstrap_beacon: beacon01.example.net
flexera_allowed_version: latest
flexera_allow_downgrade: false
flexera_run_inventory_after_install: false
```

## Garde-fous

1. validation de version et découverte des capacités ;
2. TLS et certificats validés par défaut ;
3. packages approuvés, checksums et signatures contrôlés ;
4. résolution non ambiguë des machines et objets de groupe ;
5. verrou par machine et par objet de collection/groupe modifié ;
6. idempotence des installations, ajouts et retraits ;
7. aucune suppression de device, agent ou ressource cloud lors d'un simple retrait ;
8. aucune modification de déploiement SCCM ou approval WSUS implicite ;
9. aucune connexion Azure Arc à un autre tenant sans transfert explicite ;
10. aucun endpoint NRPE exposé à une source non allowlistée ;
11. aucune commande NRPE arbitraire ;
12. conservation de l'identité Flexera lors d'un upgrade ;
13. refus des downgrades par défaut ;
14. aucun redémarrage système implicite ;
15. artefact `set_stats` sans secret ;
16. nettoyage dans un bloc `always` ;
17. matrice produit × version × OS publiée et testée.

## Intégration AAP / ServiceNow

Chaque opération expose un Job Template distinct :

- configuration SCCM ;
- installation/réparation du client SCCM ;
- ajout et retrait d'une collection SCCM ;
- création d'un groupe WSUS ;
- ajout et retrait d'un groupe WSUS ;
- installation et enregistrement Azure Arc ;
- installation/configuration de l'agent Centreon NRPE ;
- installation/configuration/mise à niveau de l'agent Flexera.

Les workflows de décommissionnement peuvent chaîner les retraits SCCM/WSUS,
Azure Arc, Centreon, sauvegarde et Flexera, mais chaque projet reste autonome et
le workflow doit rendre explicite chaque suppression ou désinstallation.

## Ordre de réalisation recommandé

### Lot 1 — Agents simples et audit

1. `ansible-flexera-agent-deploy` ;
2. `ansible-centreon-nrpe-agent-deploy` ;
3. `ansible-azure-arc-agent-deploy` ;
4. tests Windows/Linux, upgrade et audit.

### Lot 2 — SCCM

5. `ansible-sccm-conf` ;
6. `ansible-sccm-client-deploy` ;
7. `ansible-sccm-device-collection-add` ;
8. `ansible-sccm-device-collection-remove` ;
9. tests avec collections directes, query, include et exclude.

### Lot 3 — WSUS

10. `ansible-wsus-computer-group-create` ;
11. `ansible-wsus-computer-group-add` ;
12. `ansible-wsus-computer-group-remove` ;
13. tests server-side et client-side targeting.

### Lot 4 — Workflows de cycle de vie

14. intégration facultative à `ansible-createvm` et aux futurs workflows bare-metal ;
15. intégration au décommissionnement sans dépendance directe ;
16. validation du retour CMDB et des états intermédiaires.

## Validation attendue

- tests unitaires des cmdlets SCCM/WSUS et commandes agent ;
- mocks des API, WMI, PowerShell et erreurs réseau ;
- tests d'idempotence `install`, `upgrade`, `add` et `remove` ;
- tests SCCM avec direct/query/include/exclude membership rules ;
- tests WSUS avec ciblage serveur et client/GPO ;
- tests Azure Arc multi-tenant, proxy et ressource déjà connectée ;
- tests NRPE depuis un vrai poller, TLS et liste de pollers autorisés ;
- tests Flexera de bootstrap, récupération de policy et upload d'inventaire ;
- machines Windows et Linux jetables ;
- matrice publiée SCCM/WSUS/Azure Arc/Centreon/Flexera × OS × version.
