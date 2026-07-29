# ansible-synergy-vlan-add

Ajout idempotent d'un VLAN Ethernet dans HPE OneView/Synergy :

1. création ou maintien du réseau Ethernet/VLAN ;
2. ajout au Network Set consommé par Virtual Connect ;
3. ajout ou remplacement facultatif d'une connexion dans un Server Profile
   affecté à une lame.

Dans Synergy, la configuration réseau d'une lame est portée par son Server
Profile : le playbook ne modifie pas directement le système d'exploitation de
l'hôte. Il préserve les autres connexions du profil et du Network Set.

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/add_vlan.yml --vault-password-file .vault_pass
```

Configurer `oneview_vlan`, `oneview_network_set_name` et, si nécessaire,
`oneview_server_profile_name`/`oneview_profile_connection`. L'identifiant de
connexion doit être unique dans le profil. Si `oneview_server_profile_name`
est renseigné mais ne résout à aucun profil unique, le rôle échoue clairement
avant toute modification plutôt que d'échouer sur un accès à un profil vide.
Le résultat AAP est `synergy_vlan_add_summary`.
