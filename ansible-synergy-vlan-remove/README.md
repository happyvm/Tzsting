# ansible-synergy-vlan-remove

Suppression ordonnée d'un VLAN OneView/Synergy : retrait de la connexion du
Server Profile, retrait du Network Set Virtual Connect, puis suppression du
réseau Ethernet. Cet ordre évite de supprimer un réseau encore référencé.

`confirm_vlan_remove=true` est obligatoire. Avant exécution, vérifier les
profils/templates, uplink sets, Logical Interconnect Groups, dépendances
cluster et connectivité de management : OneView refusera une suppression
encore référencée, mais l'approbation opérationnelle reste indispensable.

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/remove_vlan.yml \
  -e confirm_vlan_remove=true --vault-password-file .vault_pass
```

Renseigner le nom du VLAN, du Network Set, et facultativement le profil et le
nom exact de sa connexion. Le résultat est `synergy_vlan_remove_summary`.
