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
| CMDB / inventaire invité | [`SERVICENOW-CMDB-ROADMAP.md`](SERVICENOW-CMDB-ROADMAP.md) | Synchronisation des IP, interfaces et OS depuis VMware Tools ou les Integration Services vers ServiceNow IRE |

## Chaîne cible de création d'un serveur

1. réservation de l'identité, de l'IP et du DNS ;
2. création de la VM ou préparation du serveur physique ;
3. configuration OS et jonction au domaine ;
4. enregistrement SCCM/WSUS ou Satellite ;
5. installation des agents Azure Arc, Centreon et Flexera ;
6. installation du client/agent de sauvegarde ;
7. affectation aux groupes, collections, jobs et policies ;
8. création ou mise à jour de l'objet Centreon ;
9. collecte des IP/interfaces et de l'OS depuis les outils invités ;
10. réconciliation du CI dans ServiceNow via IRE et publication de l'état final.

## Chaîne cible de maintenance

1. approbation et fenêtre de changement ;
2. vérification d'une sauvegarde valide ;
3. création d'une downtime Centreon ;
4. entrée en maintenance et évacuation des workloads ;
5. update/remediation ;
6. contrôles techniques et fonctionnels ;
7. sortie de maintenance ;
8. suppression de la downtime ;
9. nouvelle collecte des IP et de l'OS après changement réseau ou upgrade ;
10. mise à jour de la conformité et de la CMDB.

## Chaîne cible de décommissionnement

1. arrêt logique et période de grâce ;
2. vérification de la dernière sauvegarde et de la rétention ;
3. dernière collecte CMDB de l'identité réseau et de l'OS ;
4. retrait Centreon, SCCM/WSUS, Satellite, Azure Arc et Flexera ;
5. retrait des jobs/policies de sauvegarde sans purge implicite des données ;
6. désinstallation explicite des agents lorsque demandée ;
7. suppression de la VM ou décommissionnement physique ;
8. nettoyage stockage, DNS, AD, IPAM et CMDB ;
9. conservation du journal d'audit et des preuves de traitement.

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

- Active Directory, DNS, DHCP/IPAM et cycle de vie complet des CI ServiceNow ;
- patch récurrent Windows et Linux au niveau workload ;
- certificats/PKI et renouvellement ;
- EDR et collecte de logs ;
- zoning SAN et réseau physique ;
- tests automatisés de restauration et PRA ;
- collection Ansible interne pour les préflights, verrous et résumés communs.
