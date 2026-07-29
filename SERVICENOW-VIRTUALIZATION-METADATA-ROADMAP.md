# Roadmap d'automatisation — métadonnées CMDB vers SCVMM et vCenter

Ce document décrit la synchronisation descendante de métadonnées ServiceNow vers
les objets VM gérés par SCVMM ou vCenter.

ServiceNow reste la source d'autorité. Les plateformes de virtualisation reçoivent
une copie normalisée des informations utiles aux opérations, au placement, au
reporting et aux workflows de maintenance.

Le premier périmètre couvre :

- type d'environnement : production, préproduction, validation, test, développement ;
- niveau de service ou SLA ;
- statut GxP / non-GxP ;
- niveau de reprise après sinistre ou DR level.

## Terminologie cible

Dans SCVMM, l'équivalent retenu d'un tag est une **Custom Property** associée aux
objets `VM`.

Dans vCenter, les valeurs sont représentées par des tags regroupés dans des
catégories à cardinalité unique.

Le modèle commun utilise les dimensions suivantes :

| Clé commune | SCVMM Custom Property | Catégorie vCenter |
|---|---|---|
| `environment` | `CMDB.Environment` | `CMDB.Environment` |
| `sla` | `CMDB.SLA` | `CMDB.SLA` |
| `gxp` | `CMDB.GxP` | `CMDB.GxP` |
| `dr_level` | `CMDB.DRLevel` | `CMDB.DRLevel` |

Les noms sont configurables, mais une même convention doit être conservée entre
les plateformes.

## Principes

- synchronisation unidirectionnelle ServiceNow vers SCVMM/vCenter ;
- aucune modification des champs CMDB depuis les plateformes de virtualisation ;
- corrélation par identifiant natif stable avant tout recours au nom de VM ;
- normalisation des valeurs avant mutation ;
- listes de valeurs autorisées et versionnées ;
- séparation du schéma de métadonnées et de la synchronisation des valeurs ;
- modes `audit`, `plan` et `apply` ;
- aucune suppression ou remise à vide d'une valeur en cas de donnée ServiceNow
  absente, ambiguë ou inaccessible par défaut ;
- publication du diff et de la source exacte utilisée pour chaque valeur ;
- aucun secret ServiceNow, SCVMM ou vCenter dans les logs et artefacts ;
- chaque projet reste autonome et exploitable dans AAP.

---

# Définition du schéma SCVMM

## `ansible-scvmm-custom-properties-conf`

Ce projet crée ou vérifie les définitions de Custom Properties nécessaires dans
SCVMM.

Contrôles :

- connexion au serveur VMM déclaré ;
- inventaire des propriétés existantes ;
- vérification du nom, de la description et du membership `VM` ;
- création facultative des propriétés manquantes ;
- ajout du type d'objet `VM` lorsqu'une propriété existe mais ne s'applique pas aux VM ;
- détection des collisions avec des propriétés existantes non gérées par Ansible ;
- aucune suppression ou renommage automatique d'une propriété existante ;
- publication d'un plan avant toute création ou extension de membership.

Variables principales :

```yaml
scvmm_metadata_schema_operation: audit  # audit | plan | apply
scvmm_create_missing_custom_properties: false
scvmm_allow_add_vm_member: false

scvmm_custom_properties:
  environment:
    name: CMDB.Environment
    description: Environment synchronized from ServiceNow CMDB
  sla:
    name: CMDB.SLA
    description: Service level synchronized from ServiceNow CMDB
  gxp:
    name: CMDB.GxP
    description: GxP classification synchronized from ServiceNow CMDB
  dr_level:
    name: CMDB.DRLevel
    description: Disaster recovery level synchronized from ServiceNow CMDB
```

Artefact AAP : `scvmm_custom_properties_conf_summary`.

---

# Synchronisation ServiceNow vers SCVMM

## `ansible-servicenow-scvmm-vm-metadata-sync`

Le projet extrait les CI VM du périmètre ServiceNow, les corrèle aux VM SCVMM,
puis synchronise les Custom Properties.

## Corrélation

Ordre proposé :

1. identifiant SCVMM ou VM GUID déjà stocké dans la CMDB ;
2. UUID/GUID de virtualisation ;
3. identifiant de VM Hyper-V ;
4. FQDN exact ;
5. nom de VM exact uniquement s'il est unique dans le scope VMM.

Une correspondance multiple, une VM absente ou un CI sans identifiant exploitable
produit un état explicite sans mutation.

## Lecture ServiceNow

Les données proviennent principalement des champs de la table CI. Le mapping reste
configurable pour tenir compte des champs standards et personnalisés locaux.

Chaque dimension accepte :

- un champ CI direct prioritaire ;
- plusieurs champs de repli ;
- un résolveur facultatif pour une valeur portée par une relation ou une table liée ;
- une table de normalisation ;
- une liste de valeurs autorisées ;
- une valeur `unknown` facultative, jamais implicite.

Exemple :

```yaml
servicenow_metadata_mappings:
  environment:
    source_fields:
      - environment
      - u_environment_type
    normalize:
      prod: Production
      production: Production
      preprod: PreProduction
      pre-production: PreProduction
      val: Validation
      validation: Validation
      test: Test
      dev: Development
      development: Development
    allowed_values:
      - Production
      - PreProduction
      - Validation
      - Test
      - Development
      - DisasterRecovery

  sla:
    source_fields:
      - u_sla_level
      - u_service_level
    allowed_values:
      - Platinum
      - Gold
      - Silver
      - Bronze
      - None

  gxp:
    source_fields:
      - u_gxp
      - u_regulated
    normalize:
      true: GxP
      false: NonGxP
      yes: GxP
      no: NonGxP
    allowed_values:
      - GxP
      - NonGxP
      - Unknown

  dr_level:
    source_fields:
      - u_dr_level
      - u_disaster_recovery_level
    normalize:
      none: DR0
      low: DR1
      medium: DR2
      high: DR3
      critical: DR4
    allowed_values:
      - DR0
      - DR1
      - DR2
      - DR3
      - DR4
```

Les valeurs réelles de SLA et DR ne sont pas imposées par la roadmap : elles doivent
reprendre les référentiels internes.

## Mutation SCVMM

Pour chaque VM :

- lecture des valeurs actuelles des Custom Properties ;
- comparaison à la valeur normalisée ServiceNow ;
- publication du diff ;
- mise à jour uniquement des propriétés gérées par cette intégration ;
- aucune suppression d'une valeur existante lorsque la source CMDB est vide par défaut ;
- option explicite et ciblée pour vider une propriété ;
- refus d'écrire une valeur hors allowlist ;
- verrou par VM GUID ;
- vérification finale des valeurs relues depuis SCVMM.

États principaux :

- `in_sync` ;
- `update_required` ;
- `updated` ;
- `source_value_missing` ;
- `source_value_invalid` ;
- `custom_property_missing` ;
- `vm_not_found` ;
- `ambiguous` ;
- `not_checked` ;
- `error`.

Artefact AAP : `servicenow_scvmm_vm_metadata_sync_summary`.

---

# Synchronisation ServiceNow vers vCenter

## `ansible-servicenow-vcenter-vm-tag-sync`

Ce projet applique la même politique aux VM VMware avec des catégories et tags
vCenter.

## Schéma vCenter

Les quatre catégories sont créées ou validées séparément du job de synchronisation :

- `CMDB.Environment` ;
- `CMDB.SLA` ;
- `CMDB.GxP` ;
- `CMDB.DRLevel`.

Chaque catégorie :

- est limitée aux objets `VirtualMachine` lorsque la version/API le permet ;
- utilise une cardinalité unique ;
- contient uniquement les valeurs approuvées ;
- n'est jamais supprimée ni renommée automatiquement ;
- refuse de réutiliser une catégorie existante incompatible.

## Corrélation

Ordre proposé :

1. Instance UUID VMware ;
2. BIOS UUID ;
3. MoRef stocké dans ServiceNow ;
4. FQDN exact ;
5. nom exact uniquement s'il est unique dans le scope vCenter.

## Mutation vCenter

- lecture des tags actuels par catégorie ;
- calcul du tag attendu depuis ServiceNow ;
- création facultative du tag manquant uniquement s'il appartient à l'allowlist ;
- attachement du tag attendu ;
- détachement de l'ancien tag de la même catégorie uniquement en mode `apply` ;
- conservation des tags étrangers et des catégories non gérées ;
- refus d'appliquer plusieurs valeurs d'une dimension unique ;
- relecture finale des associations.

Artefact AAP : `servicenow_vcenter_vm_tag_sync_summary`.

---

# Audit de dérive

Les deux projets de synchronisation disposent d'un mode audit périodique.

Le rapport consolidé distingue :

- valeur identique à la CMDB ;
- valeur absente dans la plateforme ;
- valeur différente de la CMDB ;
- valeur inconnue ou hors référentiel ;
- propriété/catégorie absente ;
- CI ou VM non corrélable ;
- plusieurs CI correspondant à la même VM ;
- plusieurs VM correspondant au même CI ;
- donnée CMDB manquante ;
- plateforme non joignable.

Nouveau projet d'agrégation :

## `ansible-servicenow-virtualization-metadata-report`

Il génère :

- une vue par VM et par dimension ;
- une vue par environnement, SLA, statut GxP et DR level ;
- un résumé HTML ;
- des CSV SCVMM et vCenter ;
- un JSON complet pour AAP et ServiceNow ;
- la liste des valeurs inconnues à corriger dans la CMDB ;
- la liste des écarts à appliquer aux plateformes.

Artefact AAP : `servicenow_virtualization_metadata_report_summary`.

## Variables communes proposées

```yaml
servicenow_instance: https://example.service-now.com
servicenow_validate_certs: true
servicenow_ci_query: null
servicenow_ci_class: cmdb_ci_server
servicenow_metadata_operation: audit  # audit | plan | apply

metadata_dimensions:
  - environment
  - sla
  - gxp
  - dr_level

metadata_clear_missing_values: false
metadata_create_missing_schema: false
metadata_create_missing_values: false
metadata_fail_on_unknown_value: true
metadata_fail_on_ambiguous_vm: true
metadata_batch_size: 100

scvmm_servers: []
vcenters: []

mail_enabled: true
mail_only_on_findings: true
mail_recipients: []
mail_allowed_domains: []
mail_subject_prefix: "[CMDB virtualization metadata]"
```

## Garde-fous

1. ServiceNow est l'unique source d'autorité ;
2. aucun retour automatique des valeurs SCVMM/vCenter vers la CMDB ;
3. aucune corrélation par nom seul lorsqu'il existe plusieurs correspondances ;
4. schéma et valeurs synchronisés par des projets/modes distincts ;
5. aucune création de propriété, catégorie ou tag par défaut ;
6. allowlists obligatoires pour toutes les dimensions ;
7. aucune valeur vide appliquée par défaut ;
8. aucune modification des métadonnées étrangères ;
9. plan détaillé avant mutation ;
10. verrou par VM et reprise après échec ;
11. TLS validé par défaut ;
12. comptes limités aux droits nécessaires ;
13. aucun secret dans les logs ou rapports ;
14. journal des anciennes et nouvelles valeurs ;
15. un échec sur une VM n'interrompt pas le rapport des autres VM ;
16. idempotence et vérification finale obligatoires.

## Intégration aux workflows

Déclenchements recommandés :

- après création et corrélation initiale de la VM ;
- après changement d'environnement ;
- après modification du SLA ;
- après changement du statut GxP ;
- après modification du niveau de DR ;
- après migration VMware vers Hyper-V ou Hyper-V vers VMware ;
- en audit périodique de dérive ;
- avant une opération de maintenance utilisant ces métadonnées comme filtre.

Les métadonnées peuvent ensuite alimenter :

- ciblage des anneaux de patch ;
- ordre et parallélisme des maintenances ;
- politiques de sauvegarde attendues ;
- règles de supervision ;
- workflows GxP avec approbations renforcées ;
- sélection des tests PRA ;
- reporting de capacité par environnement ou niveau de service.

## Ordre de réalisation recommandé

1. validation des quatre référentiels ServiceNow ;
2. mapping et normalisation des champs CI ;
3. `ansible-scvmm-custom-properties-conf` en audit ;
4. `ansible-servicenow-scvmm-vm-metadata-sync` en audit puis plan ;
5. création contrôlée des propriétés SCVMM ;
6. application sur un périmètre pilote ;
7. `ansible-servicenow-vcenter-vm-tag-sync` avec les mêmes référentiels ;
8. rapport de dérive consolidé ;
9. intégration aux workflows create, migration, patch et PRA.
