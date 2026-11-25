# Accueil de l'opérateur sur la console physique (tty1). Les autres consoles —
# tty2 et tty3, atteintes par Ctrl+Alt+F2 et Ctrl+Alt+F3, elles aussi
# connectées d'office en root — ne passent pas par ce test et rendent donc un
# shell : c'est la sortie de secours de l'image.
#
# Le front est choisi sur la présence des fichiers, pas sur un drapeau de
# construction :
#   - killbit-guide.sh présent  -> front ncurses, une seule question
#   - startx + .xinitrc         -> image construite avec KILLBIT_WITH_BROWSER=1
#   - sinon                     -> accueil en texte, puis shell
# bash ne lit .bashrc QUE pour un shell non-connecte : sans cette ligne, les
# consoles de secours n'auraient ni l'invite « killbit », ni la fonction
# « aide », ni l'alias « guide » qui ramene au front — les trois choses dont a
# besoin celui qui vient justement de quitter le front.
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"

if [ "$(tty)" = "/dev/tty1" ] && [ -z "${DISPLAY:-}" ]; then
  if [ -x /usr/local/sbin/killbit-guide.sh ]; then
    exec /usr/local/sbin/killbit-guide.sh
  fi
  if command -v startx >/dev/null 2>&1 && [ -r "$HOME/.xinitrc" ]; then
    exec startx
  fi
  exec /usr/local/sbin/killbit-session.sh
fi
