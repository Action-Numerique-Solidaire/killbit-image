# Accueil de l'opérateur sur la console physique. Les autres accès (autres tty)
# obtiennent un shell normal, utile pour le dépannage.
#
# Le front est choisi sur la présence des fichiers, pas sur un drapeau de
# construction, pour que le même .bash_profile serve à toutes les variantes :
#   - killbit-guide.sh présent  -> image guidée (front ncurses, killbit --yes)
#   - startx + .xinitrc         -> image construite avec KILLBIT_WITH_BROWSER=1
#   - sinon                     -> accueil en texte, puis shell
if [ "$(tty)" = "/dev/tty1" ] && [ -z "${DISPLAY:-}" ]; then
  if [ -x /usr/local/sbin/killbit-guide.sh ]; then
    exec /usr/local/sbin/killbit-guide.sh
  fi
  if command -v startx >/dev/null 2>&1 && [ -r "$HOME/.xinitrc" ]; then
    exec startx
  fi
  exec /usr/local/sbin/killbit-session.sh
fi
