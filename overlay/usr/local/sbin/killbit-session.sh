#!/usr/bin/env bash
# Accueil opérateur. N'exécute AUCUN effacement : killbit n'est jamais appelé
# avec --yes, l'opérateur tape lui-même la commande.
set -uo pipefail

printf '\n'
printf '================================================================\n'
printf '  killbit  --  effacement securise de supports\n'
printf '  Action Numerique Solidaire\n'
printf '================================================================\n\n'

if [[ -r /etc/killbit-image-release ]]; then
  sed 's/^/  /' /etc/killbit-image-release
  printf '\n'
fi

ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2": "$4}' | paste -sd' ' -)"
if [[ -n "$ip" ]]; then
  printf '  Reseau : %s\n\n' "$ip"
else
  printf '  Reseau : AUCUNE adresse IP -- la remontee de rapport echouera\n\n'
fi

printf '  Supports detectes :\n'
lsblk -d -o NAME,SIZE,ROTA,MODEL,SERIAL 2>/dev/null | sed 's/^/    /'
printf '\n'

printf '  ----------------------------------------------------------\n'
printf '  Pour lancer un effacement, tapez :\n\n'
printf '      killbit -i <id_du_poste>\n\n'
printf '  ou  killbit --help     pour les options\n'
printf '      killbit --check    pour verifier sans rien effacer\n'
printf '  ----------------------------------------------------------\n\n'
printf '  ATTENTION : un effacement est IRREVERSIBLE.\n\n'

# Shell interactif : l'opérateur garde la main, et le terminal ne se ferme pas.
exec bash -i
