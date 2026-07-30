# ansible-centreon-nrpe-agent-deploy

Installation et configuration d'un agent compatible NRPE sur un hôte
Linux pour la supervision Centreon, via SSH. Le projet suit la
méthodologie du dépôt : préflight bloquant, secrets Vault/AAP, rôles
séparés et artefact `set_stats`.

Ce projet est l'étape 2 du Lot 1 de l'ordre de réalisation recommandé
dans [`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md).

## Ce que ce projet couvre - et ce qu'il ne couvre pas

**Couvert** : installation du package NRPE (Debian et RHEL/dérivés),
configuration de `nrpe.cfg` (adresse d'écoute, port, liste des pollers
autorisés, timeouts, commandes allowlistées uniquement), ouverture ciblée
du pare-feu depuis les pollers déclarés uniquement (`firewalld` ou
`ufw`), contrôle du service, publication des paramètres nécessaires à
`ansible-centreon-host-add` (sans créer l'hôte Centreon), modes `install`,
`configure` et `audit`.

**Non couvert, volontairement** (voir
[`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md)) :

- **Windows** : NSClient++ en mode NRPE n'est pas implémenté dans cette
  première version - `centreon_nrpe_os_family`/`centreon_agent_backend`
  sont volontairement verrouillés à `linux`/`nrpe4` par le préflight ;
- le mode `upgrade` en tant que mode distinct : rejouer `install` avec un
  nouveau fichier de package (nouvelle URL/checksum) suffit pour
  installer une version supérieure, `apt`/`dnf` gérant nativement le
  remplacement d'un paquet déjà présent par une version différente ;
- la création de l'hôte/des services Centreon eux-mêmes
  (`ansible-centreon-host-add`, projet séparé du catalogue) ;
- le passage à Centreon Monitoring Agent (CMA), le chemin moderne
  recommandé par Centreon pour les nouveaux déploiements - ce projet
  couvre volontairement NRPE, qui reste le protocole legacy le plus
  largement déployé aujourd'hui ; un futur
  `ansible-centreon-cma-agent-deploy` est évoqué par la roadmap ;
- la validation hors-ligne de `nrpe.cfg` avant application : aucune
  option fiable et universellement documentée de test de configuration
  (`-t`/dry-run) n'a été trouvée pour le binaire `nrpe` avec un niveau de
  confiance suffisant pour l'exécuter automatiquement (une commande mal
  choisie pourrait bloquer indéfiniment le play si elle démarre le
  démon au premier plan plutôt que de valider et sortir) - utilisez le
  mode `audit` pour relire la configuration calculée avant de l'appliquer,
  et le redémarrage du service fera surface toute erreur réelle.

## Le package n'est pas téléchargé depuis les dépôts publics/EPEL

Les garde-fous propres de `ENDPOINT-MANAGEMENT-ROADMAP.md` exigent des
packages provenant uniquement d'un **dépôt interne approuvé**, avec
checksum. Par ailleurs, le paquet exact varie selon l'organisation : NRPE
classique (celui des dépôts Debian/EPEL, généralement en version 3.x),
NRPE4 (le fork activement maintenu que la roadmap demande explicitement)
ou un bundle de plugins spécifique à Centreon. Aucun de ces choix n'est
deviné ici : `centreon_nrpe_package_url` et
`centreon_nrpe_package_checksum_sha256` sont laissés vides et obligatoires
- déposez votre propre build sur votre dépôt/artifact store interne
approuvé (`.deb` pour Debian, `.rpm` pour RHEL/dérivés) avant de lancer ce
projet en mode `install`.

## Commandes allowlistées uniquement

`centreon_nrpe_commands` est la seule source des directives
`command[...]=` de `nrpe.cfg` - aucune commande ou argument arbitraire
n'est jamais accepté depuis le poller (`dont_blame_nrpe` reste à `0` par
défaut, conformément aux recommandations de sécurité historiques de
NRPE). `centreon_nrpe_extra_config_lines` permet d'ajouter des directives
verbatim pour tout ce qui dépend de la version exacte de votre build
NRPE (par exemple les directives TLS/ciphers de NRPE4, dont les noms
précis varient selon le build et ne sont pas corroborés avec assez de
confiance pour être codés en dur ici).

## Pare-feu

`centreon_nrpe_configure_firewall: true` par défaut : une règle est créée
par poller déclaré dans `centreon_pollers` (`firewalld` en famille RHEL,
`ufw` en famille Debian), scoping le port NRPE à ces seules sources.

## Vérification depuis un poller (optionnelle)

`centreon_nrpe_verify_from_poller: false` par défaut. Si activé, le
projet se connecte en SSH à chaque poller déclaré et exécute
`check_nrpe -H <cible> -p <port>` pour confirmer la connectivité
protocolaire - nécessite des identifiants SSH séparés vers le(s)
poller(s) et suppose que `check_nrpe` est installé au chemin indiqué par
`centreon_nrpe_poller_check_nrpe_path` (le chemin réel varie selon la
distribution du poller - à adapter).

## Mode `audit`

`centreon_nrpe_operation: audit` par défaut. Force le *check mode* natif
d'Ansible sur toutes les tâches mutantes - un vrai dry-run Ansible.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
identifiants SSH/become vers l'hôte cible et, si activé, vers le(s)
poller(s). Les tâches de connexion sont en `no_log`.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/deploy_nrpe_agent.yml --vault-password-file .vault_pass
```

Tester d'abord en mode `audit`. Le résultat
`centreon_nrpe_agent_deploy_summary` est récupérable par AAP et
ServiceNow, et par `ansible-centreon-host-add` pour créer l'hôte
Centreon correspondant, sans exposer de secrets.
