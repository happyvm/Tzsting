# windows-wpa-activation-collect

Script batch autonome pour collecter, sur un poste Windows XP/Server 2003
(architecture d'activation WPA/OEM historique), l'ensemble des clés de
registre et fichiers liés à l'activation Windows, afin de comparer
plusieurs états d'un même poste (avant/après une manipulation, une
réinstallation, un remplacement de fichier, etc.).

Contrairement aux autres projets de ce dépôt, il ne s'agit pas d'un rôle
Ansible : c'est un outil de diagnostic à exécuter manuellement (en
administrateur) sur la machine concernée, la collecte portant sur des
artefacts bas niveau (DLL système, base WPA binaire) pour lesquels il
n'existe pas de module Ansible dédié.

## Contenu

- `collecte_wpa.bat` — script de collecte (voir détail ci-dessous).
- `LISEZMOI.txt` — notice d'utilisation en français, destinée à accompagner
  le script sur la machine cible.
- `build_iso.sh` — génère `wpa_collecte.iso` (image ISO9660/Joliet
  contenant le `.bat` et le `LISEZMOI.txt`) à partir de ces fichiers, pour
  gravure ou montage sur la machine Windows cible. Nécessite
  `genisoimage`.

## Ce que collecte `collecte_wpa.bat`

Exécuté avec une étiquette d'état en argument (`collecte_wpa.bat avant`,
`collecte_wpa.bat apres`, ou saisie interactive si omise), le script crée
un sous-dossier horodaté sous `C:\temp\2k3\<POSTE>_<etat>_<horodatage>\`
et y place :

- `registre\` — export `.reg` de :
  - `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`
  - `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WPAEvents`
  - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion`
  - `HKLM\SOFTWARE\Microsoft\Internet Explorer\Registration`
  - `HKLM\SYSTEM\Setup`
  - `HKLM\SYSTEM\WPA`
- `fichiers\` — copie de `pidgen.dll`, `dpcdll.dll`, `licdll.dll`,
  `licwmi.dll`, `regwizc.dll`, `wpabaln.exe`, `oobe\msoobe.exe`,
  `oembios.bin`, `oembios.dat`, `oembios.sig`, `oembios.cat` (recherché
  récursivement dans `System32\CatRoot`), `wpa.dbl`, `wpa.bak`.
- `dllcache\` — mêmes fichiers recherchés dans `System32\dllcache`.
- `info\` — sortie de `systeminfo`, de
  `wmic path Win32_WindowsProductActivation get /value`, de
  `reg query HKLM\SYSTEM\WPA /s`, et `fichiers_manquants.txt` listant les
  clés/fichiers absents (le script ne s'interrompt jamais sur une absence).

`winver.exe` est également lancé pendant l'exécution (fermer la fenêtre
pour laisser le script continuer) : cette commande n'a pas de sortie
exploitable en ligne de commande, elle sert uniquement de vérification
visuelle de la version affichée.

Chaque exécution est isolée dans son propre sous-dossier horodaté : lancer
le script plusieurs fois (une fois par état à comparer) n'écrase jamais les
collectes précédentes.

## Utilisation

```
build_iso.sh                      # génère wpa_collecte.iso
```

Sur la machine Windows cible, graver/monter `wpa_collecte.iso`, puis en
administrateur :

```
collecte_wpa.bat avant
```

Répéter pour chaque état à comparer (`collecte_wpa.bat apres`, etc.), puis
comparer les sous-dossiers générés dans `C:\temp\2k3`.
