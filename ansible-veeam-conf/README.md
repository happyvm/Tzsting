# ansible-veeam-conf

Configuration déclarative du serveur Windows hébergeant **Veeam Backup &
Replication (VBR)** - jonction Active Directory (optionnelle), compte
local d'automatisation, NTP et fuseau horaire, directement via WinRM,
comme `windows-hyperv-conf`/`windows-scvmm-conf` - et des paramètres de
notification globaux de VBR lui-même (email, SNMP) via sa vraie API REST.
Le projet suit la méthodologie du dépôt : inventaire sans appliance
statique, préflight bloquant, secrets Vault/AAP, rôles séparés et
artefact `set_stats`.

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : le système d'exploitation Windows du serveur VBR (AD, compte
local, NTP, fuseau horaire) et les réglages globaux de notification du
serveur VBR lui-même (email, SNMP), au même niveau que les autres projets
`*-conf` du dépôt (identité/alerting d'un équipement, pas son contenu
fonctionnel). L'intégration LDAP/RBAC applicative de VBR (rôles/permissions
internes à Veeam, distincts de la jonction AD de l'hôte Windows) n'est
**pas encore couverte** - à ajouter dans une future itération si
nécessaire.

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

## Hôte Windows (rôles `ad`, `local_admin`, `ntp`, `timezone`)

`veeam_conf_winrm_hostname`/`_username`/`_password` sont les identifiants
WinRM du serveur Windows lui-même, distincts de `veeam_conf_username`/
`_password` (le compte applicatif VBR pour l'API REST) - même si les deux
ciblent généralement la même machine, ce sont deux comptes différents. La
jonction AD (`veeam_conf_ad_enabled: false` par défaut) ne redémarre
jamais le serveur : VBR devenant indisponible pendant un redémarrage
interrompt toutes les sauvegardes planifiées sur ce serveur, donc le
redémarrage nécessaire pour finaliser la jonction est une action de
maintenance à planifier séparément. `veeam_conf_timezone` attend un
identifiant de fuseau **Windows** (ex. `Romance Standard Time`), pas un
nom IANA (`Europe/Paris`).

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
credentials VBR (API et WinRM), le compte de jonction AD, le mot de passe
du compte local et la communauté SNMP. Toutes les tâches HTTP et
sensibles sont en `no_log` (la requête de token transporte le mot de
passe dans son corps). Utiliser un compte API et un compte de jonction AD
aux droits minimaux.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-playbook playbooks/configure_veeam.yml --vault-password-file .vault_pass
```

Aucun inventaire statique par hôte : le serveur cible est ajouté
dynamiquement à l'inventaire en mémoire depuis
`veeam_conf_winrm_hostname`/`username`/`password`. La jonction AD est
désactivée par défaut (`veeam_conf_ad_enabled: false`). Tester d'abord
sur un serveur de qualification. Le résultat `veeam_conf_summary` est
récupérable par AAP et ServiceNow sans exposer les secrets.
