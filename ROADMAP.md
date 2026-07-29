# Roadmap globale des automatisations

Ce fichier est le point d'entrée des roadmaps du dépôt. Il distingue le code
déjà présent, documenté dans [`ANSIBLE.md`](ANSIBLE.md), des briques encore à
concevoir ou développer.

## Documents de référence

| Domaine | Document | Périmètre principal |
|---|---|---|
| Catalogue existant | [`ANSIBLE.md`](ANSIBLE.md) | Projets et playbooks déjà présents dans le dépôt |
| Analyse transverse | [`CYCLE-DE-VIE-GAPS.md`](CYCLE-DE-VIE-GAPS.md) | Écarts VM, OS, hyperviseurs, matériel et exploitation |
| Sauvegarde | [`VEEAM-NETBACKUP-ROADMAP.md`](VEEAM-NETBACKUP-ROADMAP.md) | Veeam, NetBackup, agents, jobs/policies, DXi et StoreOnce |
| Supervision | [`CENTREON-ROADMAP.md`](CENTREON-ROADMAP.md) | Configuration Centreon, hôtes, services, pollers, downtimes et acknowledgements |
| Gestion de parc | [`ENDPOINT-MANAGEMENT-ROADMAP.md`](ENDPOINT-MANAGEMENT-ROADMAP.md) | SCCM, WSUS, Azure Arc, NRPE et Flexera |
| Gestion Linux | [`SATELLITE-ROADMAP.md`](SATELLITE-ROADMAP.md) | Red Hat Satellite, activation keys, enregistrement, host groups et content views |
| Bases de données | [`SQL-SERVER-ROADMAP.md`](SQL-SERVER-ROADMAP.md) | Installation SQL Server standalone et prérequis des futurs projets HA |
| Hyperviseurs | [`HYPERVISOR-MAINTENANCE-ROADMAP.md`](HYPERVISOR-MAINTENANCE-ROADMAP.md) | Maintenance VMware/Hyper-V, update VCSA, ESXi et nœuds Hyper-V |
| CMDB / réseau invité | [`SERVICENOW-CMDB-ROADMAP.md`](SERVICENOW-CMDB-ROADMAP.md) | Synchronisation des interfaces, MAC et IP depuis VMware Tools ou les Integration Services vers ServiceNow IRE |
| CMDB / réconciliation | [`SERVICENOW-RECONCILIATION-ROADMAP.md`](SERVICENOW-RECONCILIATION-ROADMAP.md) | Classification VM/physique, audits d'orphelins Pure/AD/WSUS/SCCM/Trellix/Trend/Centreon et rapports mail |
| CMDB / Satellite | [`SERVICENOW-SATELLITE-AUDIT-ROADMAP.md`](SERVICENOW-SATELLITE-AUDIT-ROADMAP.md) | Détection des CI retirés encore enregistrés dans Satellite et des souscriptions/licences potentiellement consommées |
| CMDB / couverture | [`SERVICENOW-COVERAGE-AUDIT-ROADMAP.md`](SERVICENOW-COVERAGE-AUDIT-ROADMAP.md) | CI retirés encore présents dans VMware/Hyper-V, couverture Veeam/NetBackup, outils obligatoires manquants et cohérence DNS |

## Chaîne cible de création d'un serveur

1. réservation de l'identité, de l'IP et du DNS ;
2. création de la VM ou préparation du serveur physique ;
3. configuration OS et jonction au domaine ;
4. enregistrement SCCM/WSUS ou Satellite ;
5. installation des agents Azure Arc, Centreon et Flexera ;
6. installation du client/agent de sauvegarde ;
7. affectation aux groupes, collections, jobs et policies ;
8. création ou mise à jour de l'objet Centreon ;
9. collecte des interfaces, MAC et IP depuis les outils invités ;
10. réconciliation du CI dans ServiceNow via IRE et publication de l'état final ;
11. vérification facultative de la classification serveur physique/virtuel ;
12. contrôle différé de la couverture effective, du premier backup et de la résolution DNS.

## Chaîne cible de maintenance

1. approbation et fenêtre de changement ;
2. vérification d'une sauvegarde valide ;
3. création d'une downtime Centreon ;
4. entrée en maintenance et évacuation des workloads ;
5. update/remediation ;
6. contrôles techniques et fonctionnels ;
7. sortie de maintenance ;
8. suppression de la downtime ;
9. nouvelle collecte réseau après changement d'adresse, de carte, de VLAN,
   restauration ou migration ;
10. contrôle DNS et couverture des outils après modification structurante ;
11. mise à jour de la conformité et de la CMDB.

## Chaîne cible de décommissionnement

1. arrêt logique et période de grâce ;
2. vérification de la dernière sauvegarde et de la rétention ;
3. dernière collecte CMDB de l'identité réseau ;
4. retrait Centreon, SCCM/WSUS, Satellite, Azure Arc et Flexera ;
5. retrait des jobs/policies de sauvegarde sans purge implicite des données ;
6. désinstallation explicite des agents lorsque demandée ;
7. suppression de la VM ou décommissionnement physique ;
8. nettoyage stockage, DNS, AD, IPAM et CMDB ;
9. conservation du journal d'audit et des preuves de traitement ;
10. contrôle différé des résidus dans VMware/Hyper-V, DNS et les outils de gestion
    après expiration de la période de grâce.

## Boucle périodique de réconciliation

1. extraction des CI actifs avec leur profil de couverture et leurs exemptions ;
2. vérification de la présence attendue dans Centreon, SCCM, WSUS, Satellite,
   Trellix et Trend ;
3. vérification de la couverture effective Veeam/NetBackup et de l'existence d'un
   backup récent exploitable ;
4. contrôle DNS actif : nom, FQDN, aliases, A/AAAA et PTR ;
5. extraction des CI retirés hors période de grâce ;
6. comparaison en lecture seule avec VMware, Hyper-V, Pure Storage, AD, WSUS,
   SCCM, Trellix, Trend, Centreon et Red Hat Satellite ;
7. contrôle des résidus DNS des CI retirés ;
8. qualification des souscriptions Satellite encore attachées ou potentiellement
   consommées sous Simple Content Access ;
9. distinction des objets présents, absents, stale, ambigus ou non attendus ;
10. agrégation par CI et par outil ;
11. génération d'un rapport HTML/CSV/JSON ;
12. envoi par mail aux destinataires allowlistés ;
13. correction CMDB éventuelle uniquement via un workflow approuvé et IRE.

## Principes communs à toutes les roadmaps

- chaque projet reste utilisable indépendamment ;
- découverte de version et de capacités avant mutation ;
- TLS validé par défaut ;
- aucun secret dans Git, les logs ou `set_stats` ;
- opérations destructives séparées et confirmées ;
- installation, enregistrement, affectation et désinstallation sont des actions
  distinctes ;
- mode `plan` ou `audit` lorsque possible ;
- verrou partagé par ressource ;
- artefact AAP stable et exploitable par ServiceNow ;
- matrice produit × version × OS réellement testée et publiée.

## Prochains domaines structurants encore non couverts

- cycle de vie complet Active Directory, DNS, DHCP/IPAM et remédiation CMDB ;
- patch récurrent Windows et Linux au niveau workload ;
- certificats/PKI et renouvellement ;
- déploiement et retrait des agents EDR et de collecte de logs ;
- zoning SAN et réseau physique ;
- tests automatisés de restauration et PRA ;
- collection Ansible interne pour les préflights, verrous et résumés communs.
