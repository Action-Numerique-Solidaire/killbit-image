# Sur la console physique, présenter le menu opérateur. Les autres accès
# (ssh, autres tty) obtiennent un shell normal, utile pour le dépannage.
if [[ "$(tty)" == "/dev/tty1" ]]; then
  exec /usr/local/sbin/killbit-launcher.sh
fi
