# Accueil de l'opérateur sur la console physique. Les autres accès (autres tty)
# obtiennent un shell normal, utile pour le dépannage.
#
# L'image est console seule : il n'y a ni gestionnaire de fenêtres ni serveur X,
# sauf si elle a été construite avec KILLBIT_WITH_BROWSER=1. On teste la
# présence de startx plutôt qu'un drapeau, pour que le même fichier serve dans
# les deux cas.
if [ "$(tty)" = "/dev/tty1" ] && [ -z "${DISPLAY:-}" ]; then
  if command -v startx >/dev/null 2>&1 && [ -r "$HOME/.xinitrc" ]; then
    exec startx
  fi
  exec /usr/local/sbin/killbit-session.sh
fi
