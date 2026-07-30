# Tests transverses du dépôt

Suite `pytest` qui couvre les 39 projets Ansible du dépôt d'un seul bloc.
Elle complète les jobs CI existants (`yamllint`, `ansible-lint`,
`--syntax-check`, PSScriptAnalyzer) : ceux-ci valident chaque projet
isolément et de façon statique, alors que cette suite vérifie ce qu'ils ne
peuvent pas voir — la cohérence entre projets, le câblage réel de la CI, et
le comportement effectif des garde-fous de préflight.

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
| `test_layout.py` | Chaque projet a la structure commune (`ansible.cfg`, `requirements.yml`, inventaire d'exemple, configs de lint) et un workflow CI qui surveille le bon répertoire et `--syntax-check` des playbooks qui existent réellement |
| `test_structure.py` | Les rôles inclus existent et sont tous utilisés, chaque tâche est nommée, les modules sont en FQCN, toute collection appelée est déclarée dans `requirements.yml`, et aucun secret en clair dans `group_vars` |
| `test_embedded_scripts.py` | Les extracteurs `scripts/extract_embedded_scripts.py` écrivent bien **tous** les scripts PowerShell/bash embarqués dans le YAML |
| `test_guards.py` | Les `assert` de préflight acceptent les requêtes valides et rejettent réellement les entrées hostiles |

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
