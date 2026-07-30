# ansible-azure-arc-agent-deploy

Installe l'agent Azure Connected Machine et enregistre un serveur Windows
ou Linux dans **Azure Arc-enabled Servers**, via SSH ou WinRM. Le projet
suit la méthodologie du dépôt : préflight bloquant, secrets Vault/AAP et
artefact `set_stats`.

Ce projet est l'étape 3 du Lot 1 de l'ordre de réalisation recommandé
dans [`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md).

## Ce projet enveloppe le rôle officiel, il ne le remplace pas

`ENDPOINT-MANAGEMENT-ROADMAP.md` demande explicitement l'"utilisation
prioritaire du rôle officiel de la collection `azure.azcollection`" pour
ce projet - c'est exactement ce que fait ce projet, plutôt que de
réimplémenter l'installation/l'enregistrement d'azcmagent à la main.
`roles/preflight` valide nos propres variables, puis
`playbooks/deploy_azure_arc.yml` inclut directement
[`azure.azcollection.azure_arc`](https://learn.microsoft.com/en-us/azure/azure-arc/servers/onboard-ansible-playbooks),
le rôle officiel documenté par Microsoft pour cet usage. Ce rôle :

- installe l'agent (script officiel `aka.ms/azcmagent`) s'il ne l'est pas
  déjà ;
- est idempotent : une machine déjà connectée est détectée via
  `azcmagent show` et l'enregistrement est sauté ;
- **refuse silencieusement de re-enregistrer une machine déjà connectée
  avec un cloud/resource group/location/tenant/subscription différent**
  (un `assert` interne compare la configuration actuelle à celle
  demandée) - exactement le garde-fou "refus d'enregistrer une machine
  déjà connectée à un autre tenant sans workflow de transfert explicite"
  demandé par la roadmap, obtenu gratuitement en utilisant le rôle
  officiel plutôt qu'en le réimplémentant.

## Architecture à deux plays (différent du reste du dépôt)

La plupart des projets de ce dépôt utilisent un seul play `hosts:
localhost` avec `delegate_to` sur chaque tâche. Ce projet utilise
volontairement un **second play réel ciblant l'hôte ajouté
dynamiquement** (`hosts: azure_arc_target`), pas `delegate_to`. Raison
vérifiée empiriquement : le rôle officiel bascule Linux/Windows en
interne via les facts collectés (`ansible_system`/`ansible_os_family`),
pas via une variable d'entrée explicite - et `delegate_to` ne re-scope
PAS les conditions `when:` basées sur des facts vers l'hôte délégué
(vérifié : elles restent évaluées sur les facts de l'hôte du play, donc
sur le nœud de contrôle). Utiliser `delegate_to` ici casserait
silencieusement l'aiguillage Linux/Windows du rôle officiel.

## Authentification : service principal uniquement

`ENDPOINT-MANAGEMENT-ROADMAP.md` mentionne le service principal, la
workload identity ou "un mécanisme d'onboarding approuvé". Ce projet ne
supporte que le **service principal** (`azure_arc_application_id`/
`azure_arc_client_secret`/`azure_arc_tenant_id`), le seul qui s'intègre
directement au modèle Vault/Credential AAP de ce dépôt sans dépendre
d'une session Azure CLI interactive sur le nœud de contrôle ou d'une
identité managée (qui suppose que le nœud de contrôle lui-même tourne
sur une VM Azure ou un serveur déjà Arc-enabled). Le rôle officiel
supporte ces autres méthodes nativement si vous en avez besoin - voir sa
documentation.

## `azure_arc_location` toujours obligatoire

Le rôle officiel peut déduire la région depuis le resource group si elle
n'est pas fournie (un appel Azure supplémentaire). Ce projet la rend
**toujours obligatoire** à la place : plus simple, un appel Azure de
moins, et cohérent avec le style préflight du reste du dépôt qui préfère
l'explicite à la déduction implicite.

## Mode `audit` : ce qu'il couvre vraiment

`azure_arc_deploy_operation: audit` par défaut, qui force le *check
mode* natif d'Ansible sur l'inclusion du rôle officiel. **Attention, ce
n'est pas un dry-run entièrement hors-ligne** - vérifié empiriquement
sur le rôle officiel réel :

- l'installation de l'agent (script `azcmagent`) est bien simulée, sans
  exécution réelle ;
- **la requête de jeton d'accès Azure AD (`azure_rm_accesstoken_info`)
  s'exécute réellement**, même en mode `audit` - c'est un module de
  lecture seule (non mutant), mais c'est un véritable appel réseau
  authentifié avec le service principal fourni ;
- **sur une machine qui n'a jamais eu l'agent installé**, le mode
  `audit` échouera à l'étape `azcmagent show` du rôle officiel (qui
  s'exécute toujours pour de vrai, `check_mode: false` explicite côté
  rôle, pour remonter un statut à jour) puisque le binaire `azcmagent`
  n'existe pas encore - l'étape d'installation, elle, a bien été simulée
  et sautée. Ce n'est pas un bug de ce projet : c'est un comportement du
  rôle officiel upstream, pas patché ici. **Utilisez `deploy` directement
  pour un premier enregistrement** ; réservez `audit` à une machine où
  l'agent est déjà installé (déjà connectée ou non), pour prévisualiser
  un changement de destination Azure sans le déclencher réellement.
- seule la commande mutante `azcmagent connect` elle-même est bien
  sautée en mode `audit`.

## Ce que ce projet ne couvre pas

Voir [`ENDPOINT-MANAGEMENT-ROADMAP.md`](../ENDPOINT-MANAGEMENT-ROADMAP.md) :
`azcmagent check` (validation réseau/proxy/TLS préalable) n'est pas
exposé par le rôle officiel et n'est donc pas automatisé ici - consultez
la documentation Microsoft sur les prérequis réseau et exécutez `azcmagent
check` manuellement si besoin. La déconnexion/désinstallation, le mode
`upgrade` distinct (rejouer `deploy` avec une machine déjà connectée est
idempotent et ne réinstalle rien d'inutile) et les extensions Azure ne
sont pas couverts non plus.

## Variables et secrets

Adapter `inventory/group_vars/all.yml`. Placer dans Vault/AAP : les
identifiants SSH/WinRM/become vers l'hôte cible et le secret du service
principal Azure. Les tâches de connexion sont en `no_log` ; le rôle
officiel met lui-même en `no_log` sa récupération de jeton d'accès.

## Utilisation

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/deploy_azure_arc.yml --vault-password-file .vault_pass
```

Le résultat `azure_arc_agent_deploy_summary` est récupérable par AAP et
ServiceNow sans exposer de secrets.
