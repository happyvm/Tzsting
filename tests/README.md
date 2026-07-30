# Tests transverses du dépôt

Suite `pytest` qui couvre les 39 projets Ansible du dépôt d'un seul bloc.
Elle complète les jobs CI existants (`yamllint`, `ansible-lint`,
`--syntax-check`, PSScriptAnalyzer) : ceux-ci valident chaque projet
isolément et de façon statique, alors que cette suite vérifie ce qu'ils ne
peuvent pas voir — la cohérence entre projets, le câblage réel de la CI, et
le comportement effectif des garde-fous de préflight.

## Les workflows du dépôt

| Workflow | Déclenchement | Rôle |
|---|---|---|
| `ansible-projects.yml` | matrice calculée depuis les chemins modifiés | yamllint + ansible-lint + `--syntax-check` du ou des projets touchés, plus ShellCheck pour `ansible-resizedisk` |
| `powershell-quality.yml` | fichiers PowerShell et 6 projets à script embarqué | PSScriptAnalyzer |
| `tests.yml` | tout push | cette suite |

`ansible-projects.yml` remplace les 39 fichiers `*-ci.yml` d'origine (1745
lignes pour trois formes distinctes une fois le nom du projet normalisé).
Il ne contient aucune liste de projets : le job `detect` retient les
répertoires de premier niveau modifiés qui contiennent un `ansible.cfg`, le
même marqueur que `conftest.py` utilise pour les découvrir. Un nouveau
projet est donc pris en charge sans toucher à la CI.

## Exécution

```bash
pip install -r tests/requirements.txt
cd tests && pytest -n auto
```

`-n auto` (pytest-xdist) est recommandé : `test_guards.py` lance un vrai
`ansible-playbook` par condition testée, ce qui passe d'environ 3 min 40 à
un peu plus d'une minute.

Pour n'exécuter que les tests rapides (tout sauf les garde-fous) :

```bash
cd tests && pytest --ignore=test_guards.py
```

## Contenu

| Fichier | Ce qu'il vérifie |
|---|---|
| `conftest.py` | Découverte des projets, parcours des tâches (y compris dans `block`/`rescue`/`always`), et le harnais qui rejoue les garde-fous d'un rôle via `ansible-playbook` |
| `test_layout.py` | Chaque projet a la structure commune (`ansible.cfg`, `requirements.yml`, inventaire d'exemple, configs de lint), et le workflow consolidé `ansible-projects.yml` conserve ses quatre contrôles, couvre tous les playbooks et ne contient aucune liste de projets en dur |
| `test_structure.py` | Les rôles inclus existent et sont tous utilisés, chaque tâche est nommée, les modules sont en FQCN, toute collection appelée est déclarée dans `requirements.yml`, aucun secret en clair dans `group_vars`, et **chaque projet reste autonome** (aucun chemin `../`, aucune référence à un projet voisin, aucun lien symbolique sortant, aucune collection interne partagée) |
| `test_embedded_scripts.py` | Les extracteurs `scripts/extract_embedded_scripts.py` écrivent bien **tous** les scripts PowerShell/bash embarqués dans le YAML |
| `test_guards.py` | Les `assert` de préflight acceptent les requêtes valides et rejettent réellement les entrées hostiles |
| `test_api_contracts.py` | Résolution du contrat REST depuis la release pour les projets DXi/StoreOnce : sélection de branche, priorité des surcharges, garde de capacité SNMPv3 |
| `test_backup_preflight.py` | `preflight_backup` refuse bien une suppression ou un upgrade sans sauvegarde valide, face à un serveur de sauvegarde simulé |

## Pourquoi l'autonomie des projets est testée

Chaque répertoire de projet doit pouvoir être récupéré seul, par cherry-pick,
et fonctionner sans rien d'autre du dépôt. C'est la raison pour laquelle les
préflights, les verrous et les résumés sont **dupliqués** d'un projet à
l'autre plutôt que factorisés dans une collection interne : un projet extrait
tirerait sinon une dépendance vers un artefact qui ne le suit pas.

Cette propriété ne se voit ni au lint ni à l'exécution — un chemin relatif
commode la casse sans que rien ne proteste. `test_structure.py` la vérifie
donc explicitement.

La contrepartie assumée de la duplication est le risque de divergence entre
copies. Le garde-fou n'est pas la mutualisation mais cette suite, qui exécute
les mêmes contrôles sur toutes les copies : c'est ce qui a fait apparaître
qu'une copie non adaptée de l'extracteur de scripts laissait les deux tiers
du PowerShell d'un projet hors analyse.

## Pourquoi `test_embedded_scripts.py` existe

Six projets embarquent du PowerShell (et un du bash) sous forme de chaînes
YAML templatées en Jinja. PSScriptAnalyzer et ShellCheck ne savent pas les
lire : `scripts/extract_embedded_scripts.py` les écrit d'abord dans des
fichiers autonomes, que le workflow `powershell-quality.yml` analyse
ensuite.

L'extracteur est donc un point de défaillance silencieux. S'il rate un
script, le workflow reste vert — il analyse simplement moins que ce qu'il
prétend. C'est exactement ce qui s'était produit : `ansible-inplace-upgrade`
embarquait une copie de l'extracteur de `ansible-resizedisk` qui ne
connaissait que `ansible.windows.win_shell`, si bien que les quatre scripts
`win_powershell` du projet — dont celui qui lance réellement `setup.exe` —
n'étaient jamais analysés. Ces tests comparent la sortie de chaque
extracteur aux scripts réellement présents dans le YAML.

## Pourquoi `test_guards.py` rejoue vraiment Ansible

Presque tous les projets interpolent des valeurs venues de la requête
(ServiceNow, AAP) dans des littéraux PowerShell entre apostrophes, exécutés
sur un serveur d'administration (SCVMM, hôte Hyper-V, console WSUS/SCCM).
Les `assert` de préflight sont la seule barrière entre un champ de
formulaire et une exécution de commande là-bas, et `--syntax-check` ne dit
rien de ce qu'ils rejettent réellement.

`test_interpolation_guard_rejects_a_powershell_breakout` lit chaque
condition `is regex(...)` / `is match(...)` directement dans les rôles et
vérifie qu'elle refuse une valeur contenant une apostrophe. Les conditions
étant lues dans les fichiers et non recopiées, le test suit
automatiquement les garde-fous quand ils évoluent. Les garde-fous
conditionnés par un *autre* drapeau (`not X_enabled | bool or Y is
match(...)`) sont volontairement ignorés par ce test générique : les
activer supposerait de deviner, et ils relèvent des tests par projet.
