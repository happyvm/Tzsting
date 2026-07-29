# ansible-veeam-conf

Configuration des paramètres de notification globaux d'un serveur **Veeam
Backup & Replication (VBR)** : email et SNMP. Le projet suit la
méthodologie du dépôt : inventaire sans appliance statique, préflight
bloquant, secrets Vault/AAP, rôles séparés et artefact `set_stats`.

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : les réglages globaux de notification du serveur VBR
lui-même (email, SNMP), au même niveau que les autres projets `*-conf` du
dépôt (identité/alerting d'un équipement, pas son contenu fonctionnel).

**Non couvert, volontairement** : la création/modification de jobs de
sauvegarde, de policies de rétention, de repositories, de proxies, ni la
vérification ou la restauration d'une sauvegarde. C'est l'écart 4.15/4.16
identifié dans [`CYCLE-DE-VIE-GAPS.md`](../CYCLE-DE-VIE-GAPS.md) : ce
projet referme la brique « le serveur de sauvegarde a une configuration
d'alerting », pas « il existe une politique de sauvegarde vérifiable pour
telle VM ». Cette dernière partie resterait un projet séparé et plus
ambitieux (orchestration de jobs, préflight « sauvegarde valide » avant
`deletevm`/`inplace-upgrade`).

## Authentification : OAuth 2.0, pas de l'auth basique

Contrairement aux autres appliances de ce dépôt (StoreOnce, DXi), l'API
REST de VBR n'utilise **pas** d'authentification HTTP basique. Elle
utilise un flux OAuth 2.0 *password grant* réel et documenté :

1. `POST https://<serveur>:9419/api/oauth2/token`, en
   `application/x-www-form-urlencoded`, avec `grant_type=password`,
   `username` et `password`, et l'en-tête `x-api-version` obligatoire sur
   **tout** appel à l'API.
2. La réponse contient un `access_token` (Bearer) à utiliser sur les
   appels suivants via `Authorization: Bearer <token>`.

Le rôle `auth` réalise cette étape une fois par run et expose
`veeam_conf_access_token` aux rôles suivants. Ce flux d'authentification a
été vérifié auprès de la documentation Veeam (référence API VBR 13) avant
d'écrire ce rôle - contrairement aux endpoints de configuration
eux-mêmes (voir ci-dessous), qui varient par version et ne sont donc pas
suivis avec la même certitude.

## Contrat API dépendant de la version VBR

Veeam ne publie pas de collection Ansible maintenue couvrant ces réglages,
et le schéma exact des endpoints de notification (email, SNMP) change
selon la version de VBR (11/12/13...). Le projet ne devine donc jamais un
endpoint : les variables suivantes sont vides par défaut et le préflight
refuse l'exécution tant qu'elles ne sont pas définies d'après la
référence API/Swagger livrée avec **la version cible** :

- `veeam_conf_api_version` (l'en-tête `x-api-version`, obligatoire pour
  tout appel, y compris l'authentification) ;
- `veeam_conf_email_notifications_endpoint` et `_method` (si
  `veeam_conf_email_notifications_enabled: true`) ;
- `veeam_conf_snmp_endpoint` et `_method` (si `veeam_conf_snmp_enabled: true`).

Les deux notifications sont désactivées par défaut. Les payloads
d'exemple dans `inventory/group_vars/all.yml` sont à aligner sur le
schéma réel de la version cible avant activation.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
credentials VBR et la communauté SNMP. Toutes les tâches HTTP sont en
`no_log` (la requête de token transporte le mot de passe dans son corps).
Utiliser un compte API aux droits minimaux.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-playbook playbooks/configure_veeam.yml --vault-password-file .vault_pass
```

Tester d'abord sur un serveur de qualification. Le résultat
`veeam_conf_summary` est récupérable par AAP et ServiceNow sans exposer
les secrets.
