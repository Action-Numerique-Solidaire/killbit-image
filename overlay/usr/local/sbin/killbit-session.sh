#!/usr/bin/env bash
# Accueil opérateur, en console. N'exécute AUCUN effacement : killbit n'est
# jamais appelé avec --yes, l'opérateur tape lui-même la commande.
#
# Avec --aide-seule, affiche l'écran et rend la main (alias « aide » du shell).
set -uo pipefail

RELEASE=/etc/killbit-image-release
report_url="https://actionnumeriquesolidaire.org"
if [[ -r "$RELEASE" ]]; then
  url_lue="$(awk -F= '$1=="report_url"{print $2; exit}' "$RELEASE")"
  [[ -n "$url_lue" ]] && report_url="$url_lue"
fi

printf '\n'
printf '================================================================\n'
printf '  killbit  --  effacement securise de supports\n'
printf '  Action Numerique Solidaire\n'
printf '================================================================\n\n'

if [[ -r "$RELEASE" ]]; then
  sed 's/^/  /' "$RELEASE"
  printf '\n'
fi

ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2": "$4}' | paste -sd' ' -)"
if [[ -n "$ip" ]]; then
  printf '  Reseau : %s\n\n' "$ip"
else
  printf '  Reseau : AUCUNE adresse IP -- la remontee de rapport echouera\n'
  printf '           (cette image ne gere que le reseau filaire)\n\n'
fi

# -e 1,2,7,11 ecarte ram, disquette, loop et lecteur optique. Sans ce filtre,
# le squashfs de l'image live (loop0) et le media de demarrage (sr0) figurent
# dans la liste des supports a effacer, juste a cote des vrais disques.
disques="$(lsblk -d -e 1,2,7,11 -o NAME,SIZE,ROTA,MODEL,SERIAL 2>/dev/null)"
if [[ "$(printf '%s\n' "$disques" | wc -l)" -le 1 ]]; then
  printf '  Supports detectes : AUCUN disque\n'
  printf '    Controleur en mode RAID dans le firmware ? Le basculer en AHCI.\n\n'
else
  printf '  Supports detectes :\n'
  printf '%s\n' "$disques" | sed 's/^/    /'
  printf '\n'
fi

printf '  ----------------------------------------------------------------\n'
printf '  Pour lancer un effacement :\n\n'
printf '      killbit -i <id_du_poste> -u %s\n\n' "$report_url"
printf "  Cette commande est DEJA DANS L'HISTORIQUE : appuyez sur la\n"
printf "  touche FLECHE HAUT, puis remplacez <id_du_poste> par\n"
printf "  l'identifiant du poste avant de valider.\n\n"
printf "  Si vous validez sans l'avoir remplace, le shell refuse la ligne\n"
printf "  et rien ne s'execute : <...> est un caractere special. C'est\n"
printf "  un garde-fou volontaire, pas une panne.\n\n"
printf '  Autres commandes :\n'
printf '      killbit --check    verifie sans rien effacer\n'
printf '      killbit --help     liste les options\n'
printf '      aide               reaffiche cet ecran\n'
printf '  ----------------------------------------------------------------\n\n'
printf '  ATTENTION : un effacement est IRREVERSIBLE.\n\n'

[[ "${1:-}" == "--aide-seule" ]] && exit 0

# Shell interactif : l'opérateur garde la main, et le terminal ne se ferme pas.
exec bash -i
