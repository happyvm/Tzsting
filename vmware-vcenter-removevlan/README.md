# vmware-vcenter-removevlan

Suppression ordonnée d'un VLAN dans vCenter : suppression optionnelle de
la carte réseau d'une VM qui l'utilisait, puis suppression du portgroup de
Distributed vSwitch. Mirroir de `ansible-synergy-vlan-remove` (détacher,
puis supprimer le réseau) - vCenter n'a pas de couche "network set"
séparée à détacher au préalable, un portgroup distribué est utilisé
directement par les VM.

**Attention** : si `vcenter_vm_name` est renseigné, la carte réseau
correspondante est **supprimée** (pas seulement déconnectée) - même
sémantique que `ansible-synergy-vlan-remove`, qui retire aussi
l'entrée de connexion entièrement. Laisser `vcenter_vm_name` vide pour ne
supprimer que le portgroup, sans toucher à aucune VM.

`confirm_vlan_remove=true` est obligatoire.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/remove_vlan.yml \
  -e confirm_vlan_remove=true --vault-password-file .vault_pass
```

`vcenter_hostname`/`username`/`password` et `vmware_validate_certs`
reprennent les mêmes noms que `ansible-createvm`/`ansible-resizecompute`/
etc. `vcenter_vlan_id`/`vcenter_port_binding` doivent correspondre à la
valeur avec laquelle le portgroup a été créé (exigés par le module même
pour une suppression). Le résultat est `vcenter_vlan_remove_summary`.
