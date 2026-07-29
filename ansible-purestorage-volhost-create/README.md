# ansible-purestorage-volhost-create

Création et maintien idempotent des volumes, hosts, hostgroups et connexions
d'une baie Pure Storage FlashArray avec `purestorage.flasharray`.

## Ordre d'exécution

1. validation de l'endpoint, du token et de l'unicité des noms ;
2. création ou extension des volumes (`purefa_volume`) ;
3. création/maintenance des hosts FC, iSCSI ou NVMe (`purefa_host`) ;
4. création des hostgroups, ajout des hosts et mapping des volumes
   (`purefa_hg`) ;
5. connexions directes host-volume facultatives, avec LUN facultatif.

Le playbook ne réduit pas volontairement les volumes. Les listes vides ne font
rien et ne suppriment aucun objet absent de la déclaration : la suppression
reste séparée dans `ansible-purestorage-volhost-remove`.

## Modèle de variables

```yaml
pure_volumes:
  - name: app01-data
    size: 500G
    with_default_protection: true
pure_hosts:
  - name: esx01
    personality: esxi
    wwns: ['10:00:00:00:00:00:00:01']
pure_hostgroups:
  - name: esx-cluster01
    hosts: [esx01]
    volumes: [app01-data]
pure_host_volume_connections:
  - host: linux01
    volume: app01-data
    lun: 10
```

Un host utilise selon son protocole `wwns`, `iqn` ou `nqn`. Ne connecter le
même volume directement et via un hostgroup que si cette topologie est
intentionnelle et supportée.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/maintain_storage.yml --vault-password-file .vault_pass
```

Le token API vient de Vault/AAP. Le résultat `purestorage_create_summary` est
publié comme artefact AAP exploitable par ServiceNow.
