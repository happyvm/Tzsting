#!/usr/bin/env bash
# Construit wpa_collecte.iso a partir des fichiers de ce dossier
# (collecte_wpa.bat + LISEZMOI.txt), pour graver/monter sur la machine
# Windows cible.
#
# Prerequis : genisoimage (paquet Debian/Ubuntu "genisoimage").
set -euo pipefail

cd "$(dirname "$0")"

OUT="wpa_collecte.iso"

genisoimage -o "$OUT" -V "WPA_COLLECTE" -J -r -input-charset utf-8 \
    collecte_wpa.bat LISEZMOI.txt

echo "ISO generee : $(pwd)/$OUT"
