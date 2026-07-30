# ansible-wsus-computer-group-add

Ajout contrôlé d'une machine déjà enregistrée dans **WSUS** vers un
groupe de diffusion, via le vrai module PowerShell `UpdateServices`
exécuté sur un hôte Windows qui l'a déjà installé. Le projet suit la
méthodologie du dépôt : préflight bloquant, secrets Vault/AAP et
artefact `set_stats`.

Ce projet est l'étape 11 de l'ordre de réalisation recommandé dans
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)
(Lot 3 - WSUS).

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : résolution exacte de la machine (correspondance stricte
sur `FullDomainName`, jamais la correspondance partielle de
`-NameIncludes`), refus si la machine n'a jamais envoyé son statut au
serveur WSUS (`LastReportedStatusTime` égal à `DateTime.MinValue`,
documenté par Microsoft comme signifiant "jamais contacté"), ajout via
la vraie cmdlet `Add-WsusComputer` (qui ajoute sans retirer les autres
appartenances - comportement documenté de la cmdlet), idempotence et
vérification finale de l'appartenance.

**Non couvert, volontairement** (voir
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)) :
le mode `move` (retrait des autres groupes) n'est pas implémenté -
`Add-WsusComputer` n'a pas de contrepartie documentée pour retirer une
appartenance en même temps qu'elle en ajoute une ; aucun déclenchement de
patch, d'approval ou de redémarrage.

## Ciblage serveur ou client - non détecté automatiquement

WSUS permet au client lui-même de décider de son groupe cible via une
GPO/un réglage de registre ("client-side targeting"), ce qui peut
silencieusement annuler l'affectation faite ici au prochain contact du
client. Ce projet **ne détecte pas automatiquement** si le ciblage
client est actif sur le serveur (cela nécessiterait un appel API
supplémentaire non corroboré avec assez de confiance pour ce round) :
`wsus_ga_client_side_targeting_enabled` est une variable déclarée par
l'exploitant, republiée telle quelle dans l'artefact pour que le risque
reste visible plutôt que silencieusement ignoré.

## Résolution exacte, pas de correspondance partielle

`Get-WsusComputer -NameIncludes` fait une correspondance **partielle**
(pas de wildcard, pas de correspondance exacte) d'après sa propre
documentation - ce projet filtre ensuite les résultats sur
`FullDomainName -eq` pour garantir une résolution exacte, et refuse de
continuer si zéro ou plusieurs machines correspondent exactement.

## Mode `audit`

`wsus_ga_operation: audit` par défaut. Contrairement à
`ansible-wsus-computer-group-create` (qui appelle une méthode .NET brute
sans `-WhatIf`), `Add-WsusComputer` est une vraie cmdlet PowerShell avec
un support natif `-WhatIf` (confirmé dans sa documentation officielle) -
c'est ce mécanisme qui est utilisé ici pour le dry-run, pas le check
mode d'Ansible.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
identifiants WinRM vers l'hôte console. La tâche de connexion est en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/add_computer_to_group.yml --vault-password-file .vault_pass
```

Le résultat `wsus_computer_group_add_summary` est récupérable par AAP et
ServiceNow sans exposer de secrets.
