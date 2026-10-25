# Sur la console physique, démarrer la session graphique. Les autres accès
# (autres tty, ssh) obtiennent un shell normal, utile pour le dépannage.
if [ "$(tty)" = "/dev/tty1" ] && [ -z "${DISPLAY:-}" ]; then
  exec startx
fi
