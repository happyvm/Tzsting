# vmware-vcenter-addvlan

Ajout idempotent d'un VLAN dans vCenter sous la forme d'un portgroup de
Distributed vSwitch, avec rattachement optionnel de la carte réseau d'une
VM. Contrairement à `windows-scvmm-addvlan`/`ansible-synergy-vlan-add`, un
portgroup distribué vCenter est directement utilisable par les VM : pas
d'étape d'agrégation "network set" séparée.

Limité au Distributed vSwitch (`community.vmware.vmware_dvs_portgroup`) -
un environnement en vSwitch standard uniquement n'est pas couvert par
cette version.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/add_vlan.yml --vault-password-file .vault_pass
```

`vcenter_hostname`/`username`/`password` et `vmware_validate_certs`
reprennent les mêmes noms que `ansible-createvm`/`ansible-resizecompute`/
etc. Configurer `vcenter_vlan` (nom, VLAN ID, switch distribué). Le
rattachement à une VM (`vcenter_vm_name`) est facultatif - si renseigné,
`vcenter_vm_network_adapter_label` (ex. `Network adapter 1`) est alors
obligatoire pour reconfigurer une carte existante plutôt que d'en ajouter
une nouvelle. Le résultat AAP est `vcenter_vlan_add_summary`.
