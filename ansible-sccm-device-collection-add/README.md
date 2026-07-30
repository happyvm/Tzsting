# ansible-sccm-device-collection-add

Ajout idempotent d'une machine dans une device collection **Microsoft
Configuration Manager (SCCM)** existante, via le vrai module PowerShell
`ConfigurationManager` (celui livré avec la console SCCM), exécuté sur un
hôte Windows qui l'a déjà installé. Le projet suit la méthodologie du
dépôt : préflight bloquant, secrets Vault/AAP et artefact `set_stats`.

Ce projet est l'étape 7 de l'ordre de réalisation recommandé dans
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)
(Lot 2 - SCCM).

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : résolution exacte et sans ambiguïté du device (par
`ResourceId` ou par nom exact, `-DisableWildcardHandling` pour empêcher
toute interprétation de caractères génériques) et de la collection (par
ID ou nom), ajout d'une **direct membership rule** uniquement (jamais de
règle query/include/exclude), détection d'idempotence (déjà présent →
aucune action), mise à jour facultative de la collection
(`Invoke-CMCollectionUpdate`).

**Non couvert, volontairement** (voir
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)) :
l'installation du client SCCM (`ansible-sccm-client-deploy`, projet
séparé), la création de la collection elle-même, tout déploiement
applicatif, le retrait d'un device (`ansible-sccm-device-collection-remove`,
projet séparé).

## Pourquoi un seul script PowerShell, pas plusieurs tâches Ansible

Chaque cmdlet Configuration Manager doit s'exécuter dans la **même**
session PowerShell/le même lecteur `CMSite` (`Import-Module` puis
`New-PSDrive`/`Set-Location`) - fractionner ça en plusieurs tâches
Ansible obligerait à ré-importer le module et recréer le PSDrive à
chaque tâche. `roles/add_membership` utilise donc un unique
`ansible.windows.win_powershell` qui résout, vérifie et applique en une
seule session, et publie un résultat structuré via `$Ansible.Result`/
`$Ansible.Changed` (mécanisme documenté du module, pas un parsing de
sortie).

## Mode `audit` : dry-run natif des cmdlets, pas le check mode Ansible

`sccm_dca_operation: audit` par défaut. Comme ce projet utilise un script
PowerShell personnalisé plutôt que des tâches Ansible individuellement
compatibles check-mode, le dry-run est obtenu via le **propre support
natif `-WhatIf`** de `Add-CMDeviceCollectionDirectMembershipRule`
(confirmé dans sa documentation officielle), piloté par le paramètre
`$Operation` passé au script - pas par le check mode d'Ansible.

## Avertissement (non bloquant) sur les règles dynamiques

`ENDPOINT-MANAGEMENT-ROADMAP.md` demande de refuser de modifier
silencieusement une collection pilotée uniquement par des règles
query/include/exclude. Ce projet **publie** cette information
(`dynamic_rule_warning` dans l'artefact : `true` si de telles règles
existent, `false` si aucune, `null` si le contrôle lui-même a échoué) au
lieu de bloquer l'opération : les cmdlets `Get-CMDeviceCollection*MembershipRule`
utilisés pour ce contrôle suivent la même convention de nommage que
`Add-CMDeviceCollectionDirectMembershipRule`/`Get-CMDeviceCollectionDirectMembershipRule`
(confirmés directement dans la documentation Microsoft), mais n'ont pas
été vérifiés individuellement un par un - un blocage dur basé sur un nom
de cmdlet non confirmé serait pire qu'une simple publication
d'avertissement.

## Connexion à Configuration Manager

`sccm_console_host` doit être un hôte Windows avec la console
Configuration Manager déjà installée (le site server lui-même ou un
poste d'administration). Le module se charge par son nom si la console
est en version 2111+ (ajoutée à `PSModulePath`), sinon via
`sccm_console_module_path` (chemin explicite du `.psd1`) ou
`$env:SMS_ADMIN_UI_PATH` par défaut - voir la documentation officielle
["Import the Configuration Manager PowerShell module"](https://learn.microsoft.com/en-us/powershell/sccm/overview).

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
identifiants WinRM vers l'hôte console. La tâche de connexion est en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/add_device_to_collection.yml --vault-password-file .vault_pass
```

Le résultat `sccm_device_collection_add_summary` est récupérable par AAP
et ServiceNow sans exposer de secrets.
