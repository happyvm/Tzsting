# ansible-sccm-device-collection-remove

Retrait ciblé d'une machine d'une device collection **Microsoft
Configuration Manager (SCCM)** existante, via le vrai module PowerShell
`ConfigurationManager` (celui livré avec la console SCCM), exécuté sur un
hôte Windows qui l'a déjà installé. Le projet suit la méthodologie du
dépôt : préflight bloquant, secrets Vault/AAP et artefact `set_stats`.

Ce projet est l'étape 8 de l'ordre de réalisation recommandé dans
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)
(Lot 2 - SCCM), le pendant de
[`ansible-sccm-device-collection-add`](../ansible-sccm-device-collection-add).

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : résolution exacte et sans ambiguïté du device et de la
collection (mêmes critères que `ansible-sccm-device-collection-add`),
suppression de la **direct membership rule** correspondante uniquement,
vérification immédiate après suppression que la règle a bien disparu,
mise à jour facultative de la collection, confirmation obligatoire
`confirm_remove_from_collection=true`.

**Non couvert, volontairement** (voir
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)) :
la suppression de l'objet device SCCM, la désinstallation du client, la
suppression de la machine dans Active Directory/CMDB, la création du
device collection lui-même (`ansible-sccm-device-collection-add`, projet
séparé).

## Ce retrait ne garantit pas l'absence définitive de la collection

`ENDPOINT-MANAGEMENT-ROADMAP.md` demande explicitement de "refuser de
promettre un retrait durable si la machine reste incluse par une query,
une include collection ou une règle externe" et de publier les règles
qui maintiennent potentiellement l'appartenance. Ce projet **ne bloque
pas** l'opération sur cette base (les cmdlets
`Get-CMDeviceCollection{Query,Include,Exclude}MembershipRule` utilisés
pour ce contrôle suivent la même convention de nommage confirmée pour
les cmdlets de type Direct, mais n'ont pas été vérifiés individuellement
un par un - un blocage dur basé sur un nom de cmdlet non confirmé serait
pire qu'un avertissement). Il **publie** trois indicateurs distincts
dans l'artefact (`query_rule_present`, `include_rule_present`,
`exclude_rule_present` - `true`/`false`/`null` si le contrôle a échoué)
pour que l'exploitant sache exactement si la machine risque de rester
membre de la collection par un autre mécanisme après ce retrait.

## Vérification après suppression

Après une suppression réelle, le script relit immédiatement
`Get-CMDeviceCollectionDirectMembershipRule` pour confirmer que la règle
a bien disparu (`direct_rule_still_present_after` dans l'artefact,
normalement `false`).

## Pourquoi un seul script PowerShell, pas plusieurs tâches Ansible

Même raison que `ansible-sccm-device-collection-add` : chaque cmdlet
Configuration Manager doit s'exécuter dans la même session
PowerShell/le même lecteur `CMSite`. `roles/remove_membership` utilise
donc un unique `ansible.windows.win_powershell` qui résout, vérifie,
applique et re-vérifie en une seule session, et publie un résultat
structuré via `$Ansible.Result`/`$Ansible.Changed`.

## Mode `audit` : dry-run natif des cmdlets, pas le check mode Ansible

`sccm_dcr_operation: audit` par défaut. Comme
`ansible-sccm-device-collection-add`, le dry-run utilise le support natif
`-WhatIf` de `Remove-CMDeviceCollectionDirectMembershipRule`, piloté par
le paramètre `$Operation` passé au script - pas le check mode d'Ansible.

## Connexion à Configuration Manager

Identique à `ansible-sccm-device-collection-add` - voir son README pour
le détail de l'import du module et du montage du lecteur `CMSite`.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
identifiants WinRM vers l'hôte console. La tâche de connexion est en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/remove_device_from_collection.yml --vault-password-file .vault_pass
```

Tester d'abord en mode `audit`. Le résultat
`sccm_device_collection_remove_summary` est récupérable par AAP et
ServiceNow sans exposer de secrets.
