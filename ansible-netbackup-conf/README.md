# ansible-netbackup-conf

Configuration des paramètres de notification d'un serveur primaire
**Veritas NetBackup** : SMTP et SNMP. Le projet suit la méthodologie du
dépôt : inventaire sans appliance statique, préflight bloquant, secrets
Vault/AAP, rôles séparés et artefact `set_stats`.

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : les réglages de notification du serveur primaire NetBackup
lui-même (SMTP, SNMP), au même niveau que les autres projets `*-conf` du
dépôt (identité/alerting d'un équipement, pas son contenu fonctionnel).

**Non couvert, volontairement** : la création/modification de policies de
sauvegarde, de storage lifecycle policies, l'enregistrement de clients, ni
la vérification ou la restauration d'une sauvegarde. C'est l'écart
4.15/4.16 identifié dans
[`CYCLE-DE-VIE-GAPS.md`](../CYCLE-DE-VIE-GAPS.md) : ce projet referme la
brique « le serveur de sauvegarde a une configuration d'alerting », pas
« il existe une politique de sauvegarde vérifiable pour telle VM ». Cette
dernière partie resterait un projet séparé et plus ambitieux
(orchestration de policies, préflight « sauvegarde valide » avant
`deletevm`/`inplace-upgrade`).

## Authentification : JWT, pas de l'auth basique

L'API REST de NetBackup n'utilise pas d'authentification HTTP basique.
Elle utilise un login qui renvoie un jeton JWT :

1. `POST https://<serveur>:1556/netbackup/login`, en JSON, avec
   `userName`, `password` et, optionnellement, `domainName`/`domainType`.
2. La réponse contient un `token` (JWT) à utiliser sur les appels suivants
   via `Authorization: Bearer <token>`, ainsi qu'un `refreshToken`.
3. Chaque appel - y compris le login - doit porter l'en-tête de type
   MIME versionné propre à NetBackup (ex.
   `application/vnd.netbackup+json;version=10.0`), qui change selon la
   version du serveur.

Le rôle `auth` réalise l'étape 1 une fois par run et expose
`netbackup_conf_access_token` aux rôles suivants. Ce flux
d'authentification (login JSON + JWT + media type versionné) a été
vérifié auprès de la documentation Veritas avant d'écrire ce rôle ; le
chemin exact du endpoint de login (`netbackup_conf_login_endpoint`,
`/netbackup/login` par défaut) reste toutefois à confirmer contre le
guide « Getting Started » de la version cible - c'est la seule valeur de
ce projet qui a un défaut non vide plutôt qu'une variable bloquante,
précisément parce que la confiance dans ce chemin est moins totale que
pour le reste du flux.

## Contrat API dépendant de la version NetBackup

Veritas ne publie pas de collection Ansible maintenue couvrant ces
réglages, et le schéma exact des endpoints de notification (SMTP, SNMP)
change selon la version de NetBackup (8.x/9.x/10.x). Le projet ne devine
donc jamais un endpoint : les variables suivantes sont vides par défaut
et le préflight refuse l'exécution tant qu'elles ne sont pas définies
d'après le guide API livré avec **la version cible** :

- `netbackup_conf_media_type` (l'en-tête de type MIME versionné,
  obligatoire pour tout appel, y compris l'authentification) ;
- `netbackup_conf_smtp_endpoint` et `_method` (si
  `netbackup_conf_smtp_enabled: true`) ;
- `netbackup_conf_snmp_endpoint` et `_method` (si
  `netbackup_conf_snmp_enabled: true`).

Les deux notifications sont désactivées par défaut. Les payloads
d'exemple dans `inventory/group_vars/all.yml` sont à aligner sur le
schéma réel de la version cible avant activation.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
credentials NetBackup et la communauté SNMP. Toutes les tâches HTTP sont
en `no_log` (le login transporte le mot de passe dans son corps).
Utiliser un compte API aux droits minimaux.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-playbook playbooks/configure_netbackup.yml --vault-password-file .vault_pass
```

Tester d'abord sur un serveur de qualification. Le résultat
`netbackup_conf_summary` est récupérable par AAP et ServiceNow sans
exposer les secrets.
