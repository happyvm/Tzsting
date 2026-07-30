# ansible-wsus-computer-group-create

Création idempotente d'un groupe d'ordinateurs **WSUS** (utilisé comme
anneau ou groupe de diffusion), via le vrai module PowerShell
`UpdateServices` exécuté sur un hôte Windows qui l'a déjà installé (la
console WSUS ou une fonctionnalité RSAT). Le projet suit la méthodologie
du dépôt : préflight bloquant, secrets Vault/AAP et artefact
`set_stats`.

Ce projet est l'étape 10 de l'ordre de réalisation recommandé dans
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)
(Lot 3 - WSUS).

## Pas de cmdlet dédiée - la vraie API WSUS sous-jacente

Le module `UpdateServices` ne contient **aucune cmdlet dédiée** à la
création de groupes (`New-WsusComputerTargetGroup` n'existe pas -
confirmé en listant l'intégralité des cmdlets du module sur la
documentation officielle Microsoft). Ce projet utilise donc directement
la méthode `IUpdateServer.CreateComputerTargetGroup` de l'API
d'administration WSUS sous-jacente (accessible via l'objet renvoyé par
`Get-WsusServer`), documentée sur
[`learn.microsoft.com`](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ms746997(v=vs.85)) :
`CreateComputerTargetGroup(nom)` pour un groupe racine,
`CreateComputerTargetGroup(nom, groupeParent)` pour un sous-groupe.

## Validation du nom

Les règles de nommage (moins de 256 caractères, aucun des caractères
`~!@#$^&*()=+[]\{}|;:'"<>/`) et les deux groupes système réservés (`All
Computers`, `Unassigned Computers`) sont documentés par Microsoft et
appliqués par le préflight - jamais par le serveur WSUS lui-même en
silence.

## Mode `audit`

`wsus_gc_operation: audit` par défaut. Comme
`CreateComputerTargetGroup` est un appel brut à l'API .NET et non une
cmdlet PowerShell, il n'existe pas de support natif `-WhatIf` à
utiliser ici (contrairement aux projets SCCM de ce dépôt) : en mode
`audit`, le script se contente de ne **pas appeler** la méthode, et
publie `already_exists`/`created` pour indiquer ce qui aurait été fait.

## Ce que ce projet ne couvre pas

Voir [`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md) :
aucun approval de mise à jour n'est créé implicitement, aucun accès
direct à SUSDB. L'ajout d'une machine au groupe créé ici est un projet
séparé
([`ansible-wsus-computer-group-add`](../ansible-wsus-computer-group-add)).
Le retrait d'un groupe (`ansible-wsus-computer-group-remove`) n'est pas
encore implémenté dans le dépôt : il nécessiterait de faire le pont
entre l'objet `WsusComputer` renvoyé par les cmdlets et le type brut
`IComputerTarget` attendu par la méthode `RemoveComputerTarget` de l'API
d'administration, ce qui n'a pas été corroboré avec assez de confiance
pour ce round - voir `ENDPOINT-MANAGEMENT-ROADMAP.md`.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
identifiants WinRM vers l'hôte console. La tâche de connexion est en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/create_computer_group.yml --vault-password-file .vault_pass
```

Le résultat `wsus_computer_group_create_summary` est récupérable par AAP
et ServiceNow sans exposer de secrets.
