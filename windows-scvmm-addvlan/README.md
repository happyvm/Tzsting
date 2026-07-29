# windows-scvmm-addvlan

Ajout idempotent d'un VLAN dans le modèle réseau de System Center Virtual
Machine Manager (SCVMM) :

1. création ou maintien du réseau logique et d'un site réseau (VLAN +
   sous-réseau optionnel) sur un host group SCVMM ;
2. création ou maintien d'un VM Network exposant ce VLAN aux VM ;
3. rattachement optionnel d'une carte réseau de VM à ce VM Network.

Mirroir de `ansible-synergy-vlan-add` (ethernet_network → network_set →
server_profile) transposé au modèle SCVMM (réseau logique/site réseau →
VM Network → carte réseau de VM). Aucune collection Ansible dédiée ne
couvre le réseau logique SCVMM : les rôles utilisent le même module
PowerShell `virtualmachinemanager` que `ansible-createvm`/
`ansible-resizecompute`/`ansible-resizedisk` pour leurs propres opérations
SCVMM.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/add_vlan.yml --vault-password-file .vault_pass
```

`scvmm_server` doit référencer un `inventory_hostname` du groupe
`scvmm_management` (le même inventaire que celui utilisé par
`ansible-createvm`/`ansible-resizecompute`/`ansible-resizedisk` peut être
réutilisé tel quel). Configurer `scvmm_vlan`, `scvmm_host_group` et
`scvmm_vm_network_name`. Le rattachement à une VM (`scvmm_vm_name`) est
facultatif - laisser vide pour ne préparer que la partie réseau, sans
toucher à aucune VM. Le résultat AAP est `scvmm_vlan_add_summary`.
