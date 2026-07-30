# ansible-sccm-conf

Configuration déclarative d'une infrastructure **Microsoft Configuration
Manager (SCCM/MECM)** existante, via le vrai module PowerShell
`ConfigurationManager` exécuté sur un hôte Windows qui l'a déjà installé
(la console ou un poste d'administration). Le projet suit la
méthodologie du dépôt : préflight bloquant, secrets Vault/AAP et
artefact `set_stats`.

Ce projet est l'étape 5 de l'ordre de réalisation recommandé dans
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)
(Lot 2 - SCCM).

## Cette première version couvre uniquement les boundaries/boundary groups

`ENDPOINT-MANAGEMENT-ROADMAP.md` propose un périmètre bien plus large
pour `ansible-sccm-conf` : comptes/groupes Active Directory, RBAC,
méthodes de découverte, boundaries/boundary groups, paramètres de site,
client settings, mode HTTPS/PKI, fallback status point, validation
WMI/services. Cette première version se limite volontairement aux
**boundaries et boundary groups** - la partie la plus concrètement
spécifiée par la roadmap et la seule pour laquelle chaque cmdlet utilisé
a été vérifié individuellement contre la documentation officielle
Microsoft avant d'écrire le moindre code
(`New-CMBoundary`, `New-CMBoundaryGroup`, `Add-CMBoundaryToGroup`,
`Get-CMBoundary`, `Get-CMBoundaryGroup`, `Get-CMSite`,
`Get-CMManagementPoint`, `Get-CMDistributionPoint`).

**Non couvert par cette version** (voir
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)) :
comptes/groupes AD, RBAC, méthodes de découverte, paramètres de site
pour le déploiement client, client settings, mode HTTPS/PKI, fallback
status point, validation approfondie WMI/services/composants de site.

## Découverte toujours exécutée, mutation toujours gardée par variable explicite

`roles/discover` inventorie systématiquement l'état actuel du site
(code/nom/version, boundaries, boundary groups, management points,
distribution points) - **quel que soit le mode**, conformément au
principe "découverte avant toute mutation" du dépôt.

`ENDPOINT-MANAGEMENT-ROADMAP.md` exige explicitement que les
modifications de boundaries soient "activées par variables explicites"
en raison de leur impact potentiel (affectation automatique de site,
résolution de contenu). `sccm_conf_manage_boundaries: false` par défaut
est cette porte : `roles/manage_boundaries` ne s'exécute que si elle est
mise à `true`.

## Modèle déclaratif : ce projet ne gère que ce qu'il déclare lui-même

`sccm_conf_boundary_groups[].boundaries` doit référencer des noms
présents dans `sccm_conf_boundaries` - le préflight bloque toute
référence à une boundary non déclarée dans ce même run. Ce projet ne
touche jamais à une boundary ou un boundary group pré-existant qu'il n'a
pas lui-même créé, sauf pour l'associer (`Add-CMBoundaryToGroup`) si
elle correspond exactement (même nom, même valeur - un nom en collision
avec une valeur différente fait échouer le run plutôt que de réutiliser
silencieusement la mauvaise boundary).

## Mode `audit` : `-WhatIf` natif, comme les projets device-collection

Contrairement à `ansible-wsus-computer-group-create` (un appel API brut
sans dry-run natif), chaque cmdlet utilisé ici
(`New-CMBoundary`/`New-CMBoundaryGroup`/`Add-CMBoundaryToGroup`) supporte
nativement `-WhatIf`, confirmé dans leur documentation officielle - le
mode `audit` s'appuie directement dessus, comme
`ansible-sccm-device-collection-add`/`-remove`. Limite à noter :
lorsqu'un boundary group n'existe pas encore, l'audit ne peut pas
prévisualiser quelles boundaries y seraient assignées (il faudrait le
groupe déjà créé pour lire son contenu actuel) - seule la création du
groupe lui-même est prévisualisée dans ce cas.

## Association de site systems - à la création uniquement

`sccm_conf_boundary_groups[].site_systems` (management points/
distribution points) n'est appliqué **qu'à la création** du boundary
group, via le paramètre `-AddSiteSystemServerName` de
`New-CMBoundaryGroup`. Ajouter des site systems à un groupe déjà
existant nécessiterait une cmdlet différente (`Set-CMBoundaryGroup` ou
`Get-CMBoundaryGroupSiteSystem`/une cmdlet d'ajout dédiée) non vérifiée
pour cette première version - non implémenté.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
identifiants WinRM vers l'hôte console. La tâche de connexion est en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/configure_sccm_boundaries.yml --vault-password-file .vault_pass
```

Tester d'abord en mode `audit`. Le résultat `sccm_conf_summary` est
récupérable par AAP et ServiceNow sans exposer de secrets.
