# ansible-sccm-client-deploy

Installation, réparation ou mise à niveau du client **Microsoft
Configuration Manager (SCCM/MECM)** sur un serveur Windows, via
`ccmsetup.exe` exécuté directement (pas de client push depuis la
console SCCM), sur un hôte joint en WinRM. Le projet suit la
méthodologie du dépôt : préflight bloquant, secrets Vault/AAP et
artefact `set_stats`.

Ce projet est l'étape 6 de l'ordre de réalisation recommandé dans
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)
(Lot 2 - SCCM), aux côtés de
[`ansible-sccm-device-collection-add`](../ansible-sccm-device-collection-add)/
[`-remove`](../ansible-sccm-device-collection-remove).

## `ccmsetup.exe` direct, choisi comme mécanisme fiable et stable

Comme pour `ansible-sql-server-install` (`setup.exe`), ce projet utilise
directement le mécanisme d'installation silencieuse officiel et stable
de Microsoft plutôt que de deviner un contrat d'API. La syntaxe exacte
(paramètres `ccmsetup.exe` préfixés par `/`, propriétés `client.msi` en
MAJUSCULES avec `=`, les paramètres devant toujours précéder les
propriétés sur la ligne de commande) et les codes de retour documentés
(`0` succès, `7` redémarrage requis, `6`/`9`/`10` échecs) proviennent de
la documentation officielle Microsoft
["Client installation parameters and properties"](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/deploy/about-client-installation-properties).

## Modes `install` / `repair` / `upgrade` / `audit`

- `install` : ajoute `/logon` (`ccmsetup.exe` s'arrête si un client
  existe déjà) - un mode volontairement strict pour les machines
  réellement neuves, qui ne doit jamais écraser silencieusement un
  client existant ;
- `repair` : ajoute `/forceinstall` (désinstalle puis réinstalle) -
  seul mode autorisé à nettoyer une installation cassée, conformément à
  `ENDPOINT-MANAGEMENT-ROADMAP.md` ;
- `upgrade` : ne force ni `/logon` ni `/forceinstall` - relancer
  `ccmsetup.exe` sur un client existant avec une source de contenu plus
  récente déclenche nativement une mise à niveau sur place ;
- `audit` : ne lance jamais `ccmsetup.exe`, publie uniquement l'état
  détecté (client déjà présent, version).

## Vérification post-installation

`roles/verify` attend (borné par `sccm_cd_verify_attempts` ×
`sccm_cd_verify_delay_seconds`) que la classe WMI `SMS_Client`
(`root\ccm`) rapporte une version, contrôle que le service `CcmExec`
tourne, et compare le site assigné
(`SMS_Client.GetAssignedSite().sSiteCode`) au site attendu. Le
déclenchement facultatif des cycles policy/discovery utilise
`SMS_Client.TriggerSchedule` avec les GUID documentés officiellement
(`{...21}`/`{...22}` pour Machine Policy Assignments Request/Evaluation,
`{...103}` pour Discovery Data Collection Cycle - voir la
[référence complète des GUID](https://learn.microsoft.com/en-us/intune/configmgr/develop/reference/core/clients/client-classes/triggerschedule-method-in-class-sms_client)).

## Ce que ce projet ne couvre pas

Voir [`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md) :
le client push depuis la console SCCM (ce projet exécute `ccmsetup.exe`
directement sur la cible, pas depuis le site) ; l'ajout à une device
collection (`ansible-sccm-device-collection-add`, projet séparé, la
roadmap elle-même distingue "installation d'un agent" de
"enregistrement dans un groupe/une collection") ; la vérification
côté-site que le client apparaît "actif" dans SCCM (nécessiterait la
même connexion au module `ConfigurationManager` que les projets
device-collection - composable en chaînant les playbooks, pas dupliqué
ici) ; la désinstallation (`ccmsetup.exe /uninstall`, pas implémentée -
mode/projet séparé avec confirmation explicite, comme demandé par la
roadmap) ; Enhanced HTTP (paramètre de site, pas une propriété
d'installation client).

## Media du client

`sccm_cd_ccmsetup_path`/`sccm_cd_ccmsetup_checksum_sha256` sont
obligatoires même en mode `audit` : `ccmsetup.exe` doit être
pré-positionné sur un distribution point ou un dépôt interne approuvé
(jamais téléchargé depuis une source publique), et son intégrité est
vérifiée en place (SHA-256) avant toute exécution.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
identifiants WinRM vers la machine cible. La tâche de connexion est en
`no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/deploy_sccm_client.yml --vault-password-file .vault_pass
```

Tester d'abord en mode `audit`. Le résultat `sccm_client_deploy_summary`
est récupérable par AAP et ServiceNow sans exposer de secrets.
