# windows-scvmm-removevlan

Suppression ordonnée d'un VLAN dans System Center Virtual Machine Manager
(SCVMM) : détachement de la carte réseau d'une VM (si ciblée), suppression
du VM Network, puis suppression du site réseau (définition VLAN) du réseau
logique. Le réseau logique lui-même n'est jamais supprimé - il peut porter
d'autres VLAN/sites réseau, comme `ansible-synergy-vlan-remove` ne
supprime jamais un Network Set, seulement l'appartenance du VLAN à
celui-ci.

`confirm_vlan_remove=true` est obligatoire.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/remove_vlan.yml \
  -e confirm_vlan_remove=true --vault-password-file .vault_pass
```

`scvmm_server` doit référencer un `inventory_hostname` du groupe
`scvmm_management` (même inventaire que
`ansible-createvm`/`ansible-resizecompute`/`ansible-resizedisk`/
`windows-scvmm-addvlan`). Renseigner `scvmm_vlan_id`, `scvmm_logical_network`,
`scvmm_host_group` et `scvmm_vm_network_name`, et facultativement
`scvmm_vm_name` pour détacher une VM avant suppression. Le résultat est
`scvmm_vlan_remove_summary`.
