# ansible-inplace-upgrade

Playbook Ansible d'**upgrade in place** pour des VM **Windows Server** ou
**Red Hat Enterprise Linux**, hébergées sous **VMware vSphere** ou
**Microsoft Hyper-V**. Le projet reprend la méthodologie des autres
répertoires de ce dépôt : déclenchement ServiceNow/AAP, aucune VM statique
dans l'inventaire, détection de l'hyperviseur, préflight bloquant, verrou
par VM, point de retour avant mutation et résultat structuré `set_stats`.

> Une montée de version d'OS reste une opération à risque. Tester chaque
> combinaison dans un environnement de qualification, sauvegarder la VM et
> valider la compatibilité applicative/éditeur avant production. Le snapshot
> facilite un retour arrière court mais ne remplace pas une sauvegarde.

## Déroulement

1. `preflight_platform` confirme que le CI correspond à une seule VM et
   détecte VMware ou Hyper-V. `guest_os` est explicite afin de ne pas déduire
   une décision destructive depuis un identifiant d'hyperviseur.
2. `prepare_guest` crée dynamiquement l'hôte WinRM/SSH à partir des extra-vars.
3. `upgrade_lock` empêche deux jobs de modifier simultanément la même VM.
4. `preflight_upgrade_constraints` relève la version active et l'espace libre,
   refuse un chemin non autorisé, un reboot Windows en attente ou un média
   Windows absent.
5. Un snapshot VMware quiescé ou un checkpoint Hyper-V est créé (obligatoire
   par défaut), puis `upgrade_windows` lance `setup.exe` silencieusement ou
   `upgrade_redhat` exécute le workflow Leapp `preupgrade` / `upgrade`.
6. Après reboot, `verify_upgrade` confirme la version majeure et publie
   `inplace_upgrade_summary`, exploitable comme artefact AAP par ServiceNow.

Le snapshot est volontairement **conservé** : sa suppression doit être une
étape séparée après validation fonctionnelle et expiration de la période de
rollback. Sur Hyper-V, configurez le `CheckpointType` de la VM selon votre
politique (Production recommandé). Pour un cluster, inventoriez tous les
nœuds propriétaires possibles.


## Vérification de sauvegarde avant opération

Un snapshot n'est pas une sauvegarde. Avant la réécriture de l'OS en place, le
rôle `preflight_backup`
interroge le serveur de sauvegarde **en lecture seule** et refuse de continuer
sans point de restauration réussi et récent pour la VM. Il ne crée, ne
déclenche et ne supprime jamais rien.

Le contrôle est **actif par défaut et échoue fermé** : sans configuration, le
run s'arrête. Une configuration absente ne doit pas se lire comme « cette VM
n'a pas besoin de sauvegarde ».

```yaml
inplace_upgrade_backup_provider: veeam        # veeam | netbackup
inplace_upgrade_backup_release: "12.1.2"      # release du serveur de sauvegarde
inplace_upgrade_backup_hostname: vbr01.example.local
inplace_upgrade_backup_port: 9419
inplace_upgrade_backup_max_age_hours: 24
```

Le contrat API est résolu depuis la release, comme pour les projets
d'appliance : `inplace_upgrade_backup_api_contracts` porte, par produit puis
par branche
`major.minor`, l'endpoint des points de restauration, l'en-tête de version et
les **noms des champs** de la réponse (nom de la VM, date, statut, valeurs qui
comptent comme un succès). Ces valeurs sont livrées vides : elles doivent
provenir de la référence API de la release visée, car lire le mauvais champ
transformerait « aucune sauvegarde » en apparent succès.

Ce qui est refusé : aucun point de restauration, uniquement des jobs en échec,
un point appartenant à une autre VM, ou un dernier point réussi plus ancien
que `inplace_upgrade_backup_max_age_hours`. L'âge est mesuré sur le dernier
point
**réussi**, donc un job échoué plus récent ne masque pas une sauvegarde
périmée.

Pour déroger, `-e inplace_upgrade_backup_allow_missing=true` sur un run.
L'artefact AAP
porte alors `backup_state: waived` ou `stale-waived`, jamais `verified` : la
décision reste visible après coup. Désactiver complètement le contrôle se fait
avec `-e inplace_upgrade_backup_verification_enabled=false`, également tracé
(`backup_state: disabled`).

## Variables

### Requises

| Variable | Description |
|---|---|
| `vm_name` | Nom exact de la VM dans vCenter ou Hyper-V |
| `guest_os` | `windows` ou `redhat` |
| `target_major_version` | Version majeure cible autorisée par la politique |
| `guest_username` | Compte administrateur Windows ou SSH Linux |
| `guest_password` | Secret invité (Vault/AAP), sauf clé SSH Linux |
| `windows_media_path` | Windows uniquement : chemin du média contenant `setup.exe` |

### Optionnelles

- `hypervisor_type=vmware|hyperv` limite la recherche à une plateforme.
- `target_ip` remplace `vm_name` pour WinRM/SSH.
- `guest_ssh_private_key_file`, `linux_become` et
  `linux_become_password` configurent l'accès Red Hat.
- `windows_dynamic_update=enable|disable` (défaut `disable`).
- `inplace_upgrade_require_snapshot=false` désactive explicitement le point
  de retour (à réserver à une procédure disposant d'une autre sauvegarde).
- Les chemins supportés, seuils d'espace et timeouts sont centralisés dans
  `inventory/group_vars/all.yml` et doivent être adaptés aux matrices
  Microsoft/Red Hat réellement supportées dans l'entreprise.

Les identifiants vCenter, Hyper-V et invités doivent être injectés via
Ansible Vault ou des credentials AAP, jamais stockés en clair.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml

ansible-playbook playbooks/inplace_upgrade.yml \
  -e vm_name=WINSRV01 -e guest_os=windows -e target_major_version=2022 \
  -e guest_username=Administrator -e guest_password='***' \
  -e windows_media_path='D:\\' --vault-password-file .vault_pass

ansible-playbook playbooks/inplace_upgrade.yml \
  -e vm_name=RHELAPP01 -e guest_os=redhat -e target_major_version=9 \
  -e guest_username=ansible -e guest_ssh_private_key_file=~/.ssh/id_rsa \
  -e linux_become=true --vault-password-file .vault_pass
```

## Arborescence

```text
ansible-inplace-upgrade/
├── inventory/{hosts.yml.example,group_vars/all.yml}
├── playbooks/inplace_upgrade.yml
├── roles/
│   ├── preflight_platform/
│   ├── prepare_guest/
│   ├── preflight_upgrade_constraints/
│   ├── upgrade_lock/
│   ├── upgrade_windows/
│   ├── upgrade_redhat/
│   └── verify_upgrade/
├── ansible.cfg
└── requirements.yml
```

## Points d'exploitation

- Les allowlists fournies sont des exemples de sauts directs usuels, pas une
  déclaration universelle de support. Croisez édition, langue, matériel,
  applications, dépôts et abonnements avec la documentation éditeur.
- Leapp peut demander des réponses dans `/var/log/leapp/answerfile`; tout
  inhibiteur arrête ce playbook au lieu d'être contourné automatiquement.
- Sur Windows, consultez `C:\Windows\Temp\AnsibleInPlaceUpgrade` et les logs
  Panther en cas d'échec. La disponibilité WinRM peut prendre plusieurs heures.
- La validation applicative, la suppression différée du snapshot et la clôture
  du changement restent des étapes du workflow ServiceNow hors de ce playbook.
