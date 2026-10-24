#!/usr/bin/env bash
# Accueil opérateur de l'image live killbit.
# Ne lance JAMAIS d'effacement automatiquement : killbit est appelé sans --yes,
# il conserve donc ses propres confirmations interactives.
set -uo pipefail

release_info() {
  [[ -r /etc/killbit-image-release ]] && sed 's/^/  /' /etc/killbit-image-release
}

net_info() {
  local ip
  ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2": "$4}' | paste -sd' ' -)"
  if [[ -n "$ip" ]]; then
    echo "  réseau : $ip"
  else
    echo "  réseau : AUCUNE adresse IP — la remontée de rapport échouera"
  fi
}

while true; do
  clear
  cat <<'BANNER'
================================================================
  killbit — effacement sécurisé de supports
  Action Numérique Solidaire
================================================================
BANNER
  release_info
  net_info
  echo
  echo "Supports détectés :"
  lsblk -d -o NAME,SIZE,ROTA,MODEL,SERIAL 2>/dev/null | sed 's/^/  /'
  echo
  echo "  ATTENTION : l'effacement est IRRÉVERSIBLE."
  echo
  echo "  1) Lancer killbit (interactif)"
  echo "  2) Vérifier seulement, sans effacer (killbit --check)"
  echo "  3) Aide de killbit"
  echo "  4) Shell"
  echo "  5) Redémarrer     6) Éteindre"
  echo
  read -r -p "Choix : " choice

  case "$choice" in
    1)
      read -r -p "Identifiant ANS de la machine (vide si aucun) : " ans_id
      if [[ -n "$ans_id" ]]; then killbit -i "$ans_id"; else killbit; fi
      read -r -p "Appuyez sur Entrée pour revenir au menu." _
      ;;
    2) killbit --check; read -r -p "Entrée pour continuer." _ ;;
    3) killbit --help 2>&1 | less -R ;;
    4)
      echo "Tapez 'exit' pour revenir au menu."
      bash -l
      ;;
    5) systemctl reboot ;;
    6) systemctl poweroff ;;
    *) ;;
  esac
done
