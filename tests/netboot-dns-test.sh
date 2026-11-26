#!/usr/bin/env bash
# Vérifie qu'un poste démarré PAR LE RÉSEAU (PXE/NFS) résout les noms.
#
# C'est le défaut qu'aucun autre test ne pouvait voir : l'image démarrée depuis
# un CD ou une clé a son DNS, parce que NetworkManager configure la carte. En
# netboot, c'est l'initramfs qui la configure, et live-boot la déclare
# « manual » dans /etc/network/interfaces pour que personne ne coupe la racine
# NFS sous le système. NetworkManager (greffon ifupdown en « managed=false »)
# laisse donc cette carte de côté et ne transmet jamais à systemd-resolved le
# DNS reçu en DHCP : plus un nom ne se résout, et killbit s'arrête sur
# « Impossible de contacter le serveur » sans rien effacer. Constaté sur
# matériel réel derrière un serveur BITS en mode passerelle.
#
# Le labo reproduit ce serveur : dnsmasq fait DHCP complet (routeur, DNS,
# domaine de recherche) et répond aux requêtes DNS ; la racine est servie en
# NFS par l'hôte ; le poste démarre avec la ligne de commande du menu iPXE.
#
# Il est HORS LIGNE : dnsmasq résout lui-même un nom fabriqué vers une adresse
# de documentation. Le test ne dépend donc d'aucun réseau, et aucun rapport de
# poste fictif ne peut atteindre le serveur de l'association.
#
# Le diagnostic est posé par le poste lui-même : « live-config.hooks= » fait
# exécuter au démarrage un script déposé sur le média, qui écrit ses mesures
# sur le port série. L'image sous test n'est pas modifiée, et le verdict porte
# sur du texte, pas sur une image d'écran.
#
# Usage : sudo tests/netboot-dns-test.sh <image.iso> [dossier_de_sortie] [timeout_s]
set -Eeuo pipefail

ISO="${1:?Usage: sudo netboot-dns-test.sh <image.iso> [dossier_de_sortie] [timeout_s]}"
OUTDIR="${2:-$PWD/netboot-dns-out}"
TIMEOUT="${3:-300}"

SUBNET="${NETBOOT_SUBNET:-192.168.80}"
BR=br-kbdns
TAP=tap-kbdns
# Nom résolu par le dnsmasq du labo, vers une adresse de documentation
# (RFC 5737) qui ne mène nulle part. Sous « .test » et non « .invalid » :
# systemd-resolved refuse d'émettre la moindre requête pour « .invalid », et le
# test mesurerait alors son propre nom plutôt que la résolution du poste.
NOM_TEST=rapport.atelier.test
IP_TEST=203.0.113.9
EXPORTS=/etc/exports.d/killbit-netboot-test.exports

log() { printf '\n[netboot-dns] %s\n' "$*"; }
die() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "à lancer avec sudo : le test monte l'ISO, exporte en NFS et crée un pont."
[[ -f "$ISO" ]] || die "introuvable : $ISO"
for cmd in qemu-system-x86_64 dnsmasq exportfs ip; do
  command -v "$cmd" >/dev/null || die "commande requise absente : $cmd (paquets : qemu-system-x86 dnsmasq-base nfs-kernel-server iproute2)"
done

mkdir -p "$OUTDIR"
WORK="$(mktemp -d)"
MEDIA="$WORK/media"
ISOMNT="$WORK/iso"
qemu_pid=""

nettoyer() {
  if [[ -n "$qemu_pid" ]]; then kill "$qemu_pid" 2>/dev/null || true; fi
  if [[ -f "$WORK/dnsmasq.pid" ]]; then kill "$(cat "$WORK/dnsmasq.pid")" 2>/dev/null || true; fi
  rm -f "$EXPORTS"; exportfs -ra 2>/dev/null || true
  ip link del "$TAP" 2>/dev/null || true
  ip link del "$BR" 2>/dev/null || true
  if mountpoint -q "$ISOMNT"; then umount "$ISOMNT" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap nettoyer EXIT

# --- Média NFS ----------------------------------------------------------------
# Les trois fichiers sont sortis de l'ISO : c'est bien l'image publiée qui est
# mise à l'épreuve, pas un répertoire de construction.
log "extraction de l'image"
mkdir -p "$ISOMNT" "$MEDIA/killbit/live/config-hooks"
mount -o loop,ro "$ISO" "$ISOMNT"
for f in vmlinuz initrd.img filesystem.squashfs; do
  [[ -f "$ISOMNT/live/$f" ]] || die "absent de l'ISO : live/$f"
  cp "$ISOMNT/live/$f" "$MEDIA/killbit/live/$f"
done
umount "$ISOMNT"

# Le poste mesure, il ne corrige rien : tout ce qui marche ici doit venir de
# l'image. On attend d'abord que le service de l'image ait rendu la main.
cat > "$MEDIA/killbit/live/config-hooks/010-mesures" <<HOOK
#!/bin/sh
cat > /tmp/mesures.sh <<'MES'
#!/bin/sh
exec 2>&1
i=0
while [ \$i -lt 60 ]; do
  systemctl is-active --quiet killbit-dns-netboot.service && break
  i=\$((i + 1)); sleep 1
done
echo "===== MESURES DEBUT ====="
echo "SERVICE=\$(systemctl is-active killbit-dns-netboot.service)"
echo "--- journal du service ---"
journalctl -u killbit-dns-netboot.service --no-pager -o cat
echo "--- /run/net-*.conf ---"; cat /run/net-*.conf
echo "--- /etc/network/interfaces ---"; cat /etc/network/interfaces
echo "--- nmcli dev ---"; nmcli dev
echo "--- resolvectl status ---"; resolvectl status
echo "--- getent hosts ---"
getent hosts $NOM_TEST || echo "RESOLUTION-KO"
echo "===== MESURES FIN ====="
MES
chmod 0755 /tmp/mesures.sh
setsid sh -c '/tmp/mesures.sh > /dev/ttyS0 2>&1' </dev/null >/dev/null 2>&1 &
HOOK
chmod 0755 "$MEDIA/killbit/live/config-hooks/010-mesures"

log "export NFS de $MEDIA vers $SUBNET.0/24"
mkdir -p /etc/exports.d
echo "$MEDIA $SUBNET.0/24(ro,insecure,no_subtree_check,no_root_squash)" > "$EXPORTS"
systemctl start nfs-server 2>/dev/null || die "nfs-server ne démarre pas (paquet nfs-kernel-server installé ?)"
exportfs -ra
exportfs -v | grep -q "$MEDIA" || die "l'export NFS n'est pas pris en compte"

# --- Réseau du labo -----------------------------------------------------------
log "pont $BR ($SUBNET.1) et dnsmasq (DHCP complet, DNS autoritaire, hors ligne)"
ip link add "$BR" type bridge 2>/dev/null || true
ip addr replace "$SUBNET.1/24" dev "$BR"
ip link set "$BR" up
ip tuntap add "$TAP" mode tap 2>/dev/null || true
ip link set "$TAP" master "$BR" up

dnsmasq --conf-file=/dev/null \
  --interface="$BR" --bind-interfaces --except-interface=lo \
  --dhcp-range="$SUBNET.100,$SUBNET.200,12h" \
  --dhcp-option=option:router,"$SUBNET.1" \
  --dhcp-option=option:dns-server,"$SUBNET.1" \
  --domain=atelier.test --dhcp-option=option:domain-search,atelier.test \
  --no-resolv --address="/$NOM_TEST/$IP_TEST" \
  --log-queries --log-facility="$WORK/dnsmasq.log" --pid-file="$WORK/dnsmasq.pid" \
  || die "dnsmasq n'a pas démarré (un autre service occupe-t-il le port 53 du pont ?)"

# --- Poste virtuel ------------------------------------------------------------
# Aucun disque : le front affiche « aucun support détecté » et killbit n'est
# jamais lancé. Le test porte sur la résolution de noms, pas sur l'effacement.
#
# La ligne de commande est celle du menu iPXE de BITS, aux deux ajouts près qui
# servent la mesure : le crochet live-config et la console série.
log "amorçage par le réseau (NFS) du poste virtuel"
diag="$WORK/diag.log"; boot="$WORK/boot.log"
qemu_args=(
  -m 2048 -smp 2
  -kernel "$MEDIA/killbit/live/vmlinuz"
  -initrd "$MEDIA/killbit/live/initrd.img"
  -append "boot=live components netboot=nfs nfsroot=$SUBNET.1:$MEDIA/killbit ip=dhcp live-config.hooks=file:///run/live/medium/live/config-hooks/010-mesures console=tty0 console=ttyS1,115200"
  -display none
  -serial "file:$diag"
  -serial "file:$boot"
  -no-reboot
  -netdev "tap,id=n0,ifname=$TAP,script=no,downscript=no"
  -device "virtio-net-pci,netdev=n0"
)
if [[ -w /dev/kvm ]]; then
  qemu_args+=(-enable-kvm -cpu host)
  echo "[netboot-dns] KVM disponible"
else
  echo "[netboot-dns] pas de KVM, émulation logicielle (plus lent)"
fi
qemu-system-x86_64 "${qemu_args[@]}" &
qemu_pid=$!

for ((i=0; i<TIMEOUT; i++)); do
  grep -qa 'MESURES FIN' "$diag" 2>/dev/null && break
  kill -0 "$qemu_pid" 2>/dev/null || break
  sleep 1
done
kill "$qemu_pid" 2>/dev/null || true

# Le port série rend des fins de ligne CR-LF, et nmcli colore sa sortie : sans
# ce nettoyage, « unmanaged » arrive entouré de codes d'échappement et aucun
# motif ne colle.
nettoyer_texte() { tr -d '\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }
nettoyer_texte < "$diag" > "$OUTDIR/mesures.log" 2>/dev/null || true
nettoyer_texte < "$boot" > "$OUTDIR/boot.log" 2>/dev/null || true
cp "$WORK/dnsmasq.log" "$OUTDIR/dnsmasq.log" 2>/dev/null || true
m="$OUTDIR/mesures.log"

echo
echo "----- mesures du poste ---------------------------------------------------"
cat "$m"
echo "----- requêtes vues par le serveur --------------------------------------"
grep -E 'DHCPACK|query\[A\]' "$OUTDIR/dnsmasq.log" | tail -8 || echo "(aucune)"
echo "-------------------------------------------------------------------------"
echo

# --- Verdict ------------------------------------------------------------------
grep -qa 'MESURES FIN' "$m" || die "le poste n'a pas rendu ses mesures (voir $OUTDIR/boot.log)"
grep -qa 'KILLBIT-IMAGE-READY' "$OUTDIR/boot.log" || die "l'image n'a pas démarré jusqu'au bout"

carte="$(sed -n "s/^DEVICE='\\(.*\\)'$/\\1/p" "$m" | head -1)"
[[ -n "$carte" ]] || die "aucun /run/net-<carte>.conf : le poste n'a pas été configuré par l'initramfs, ce n'est pas un netboot"
echo "[netboot-dns] carte d'amorçage : $carte"

# Le piège est toujours là : la carte reste volontairement hors de
# NetworkManager. Si ce n'était plus le cas, ce test ne prouverait plus rien et
# il faudrait revoir le service.
grep -qE "^$carte .*unmanaged" "$m" \
  || echo "[netboot-dns] AVERTISSEMENT : $carte n'est plus « unmanaged » — vérifier que le service est encore utile"

grep -q '^SERVICE=active' "$m" || die "killbit-dns-netboot.service n'est pas actif"
grep -q 'DNS Servers: *'"$SUBNET"'\.1' "$m" \
  || die "resolved n'a pas le DNS reçu en DHCP : c'est le défaut que ce test traque"
grep -q "^$IP_TEST  *$NOM_TEST" "$m" \
  || die "le nom ne se résout pas depuis le poste"
grep -q "query\[A\] $NOM_TEST from $SUBNET\." "$OUTDIR/dnsmasq.log" \
  || die "aucune requête DNS du poste n'est arrivée au serveur"

echo "[netboot-dns] OK : service actif, DNS du DHCP transmis a resolved, nom resolu, requete vue par le serveur"
