#!/bin/sh
# Utilisé uniquement par une image construite avec KILLBIT_WITH_BROWSER=1.
# Pas de gestionnaire de fenêtres : un terminal occupe l'écran, et firefox
# servira la page d'état locale de killbit le jour où elle existera.
xset s off -dpms          # pas de mise en veille pendant un effacement long
exec xterm -geometry 200x55 \
     -fa 'DejaVu Sans Mono' -fs 12 \
     -bg black -fg white \
     -title 'killbit' \
     -e /usr/local/sbin/killbit-session.sh
