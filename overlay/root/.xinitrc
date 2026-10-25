#!/bin/sh
# Session graphique minimale : openbox pour la gestion de fenêtres, et un
# terminal plein écran. L'environnement graphique est conservé pour pouvoir
# afficher plus tard la page d'état locale de killbit dans un navigateur.
xset s off -dpms          # pas de mise en veille pendant un effacement long
openbox &
exec xterm -maximized \
     -fa 'DejaVu Sans Mono' -fs 12 \
     -bg black -fg white \
     -title 'killbit' \
     -e /usr/local/sbin/killbit-session.sh
