# ansible-wsus-computer-group-remove

Retrait d'une machine d'un groupe de diffusion **WSUS**, via l'API
d'administration WSUS sous-jacente exécutée sur un hôte Windows qui a
déjà la console/le module `UpdateServices` installés. Le projet suit la
méthodologie du dépôt : préflight bloquant, secrets Vault/AAP et
artefact `set_stats`.

Ce projet est l'étape 12 de l'ordre de réalisation recommandé dans
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)
(Lot 3 - WSUS), le pendant de
[`ansible-wsus-computer-group-add`](../ansible-wsus-computer-group-add).

## Résolution directe via l'API, sans passer par la cmdlet `WsusComputer`

`ansible-wsus-computer-group-add` résout la machine via
`Get-WsusComputer` (une cmdlet qui renvoie un objet wrapper
`Microsoft.UpdateServices.Commands.WsusComputer`). La suppression, elle,
nécessite l'objet brut `IComputerTarget` attendu par la méthode
`IComputerTargetGroup.RemoveComputerTarget` de l'API d'administration -
faire le pont entre les deux avait été jugé insuffisamment corroboré
lors du développement de `ansible-wsus-computer-group-create`. Ce
projet contourne le problème : `IUpdateServer.GetComputerTargetByName(nom)`
([documentation officielle](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/aa349868(v=vs.85)))
renvoie directement un vrai `IComputerTarget` à partir du
`FullDomainName` (recherche insensible à la casse, exception documentée
si la machine n'existe pas) - aucun pont nécessaire.

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : résolution exacte de la machine (`GetComputerTargetByName`,
jamais de correspondance partielle) et du groupe, refus si la machine
n'a jamais reporté de statut, retrait via
`IComputerTargetGroup.RemoveComputerTarget` - qui déplace documentairement
la machine vers le groupe système `Unassigned Computers`, exactement le
comportement attendu par `ENDPOINT-MANAGEMENT-ROADMAP.md` - idempotence
(vérifiée via `IComputerTarget.GetComputerTargetGroups()` avant et après),
confirmation obligatoire `confirm_remove_from_wsus_group=true`.

**Non couvert, volontairement** : aucune suppression de l'objet machine
WSUS, aucun changement d'approval/deadline/classification. Le mode
`audit` ne s'appuie sur aucun `-WhatIf` natif (c'est un appel API brut,
pas une cmdlet, comme `ansible-wsus-computer-group-create`) : il se
contente de ne pas appeler la méthode.

## Ciblage serveur ou client - non détecté automatiquement

Comme `ansible-wsus-computer-group-add`,
`wsus_gr_client_side_targeting_enabled` est une variable déclarée par
l'exploitant (pas une détection automatique) - republiée telle quelle
dans l'artefact pour garder visible le risque qu'une GPO de ciblage
client réaffecte la machine à un autre groupe au prochain contact.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
identifiants WinRM vers l'hôte console. La tâche de connexion est en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/remove_computer_from_group.yml --vault-password-file .vault_pass
```

Tester d'abord en mode `audit`. Le résultat
`wsus_computer_group_remove_summary` est récupérable par AAP et
ServiceNow sans exposer de secrets.
