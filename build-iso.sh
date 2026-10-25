#!/usr/bin/env bash
# Construit une ISO live hybride BIOS + UEFI embarquant killbit, ses prérequis
# d'exécution et un environnement graphique minimal.
#
# Base : Debian 13 (trixie). Deux raisons, toutes deux vérifiées :
#   - killbit exige GLIBC_2.38 ; trixie fournit 2.41. Une base Ubuntu 22.04
#     (2.35) ne conviendrait pas.
#   - sur Ubuntu 24.04, firefox et chromium ne sont que des paquets de
#     transition vers des snaps, inutilisables dans un debootstrap. Debian
#     fournit de vrais .deb.
#
# Usage : sudo ./build-iso.sh [chemin-de-sortie.iso]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_SRC="$SCRIPT_DIR/overlay"

WORK_ROOT="${KILLBIT_ISO_WORK:-/srv/killbit-iso-build}"
CHROOT="$WORK_ROOT/chroot"
ISO_STAGE="$WORK_ROOT/iso"
DISTRO="${KILLBIT_DISTRO:-trixie}"
MIRROR="${KILLBIT_MIRROR:-http://deb.debian.org/debian}"
OUTPUT_ISO="${1:-$WORK_ROOT/killbit-live.iso}"
VOLID="KILLBIT"

KILLBIT_URL="${KILLBIT_URL:-https://github.com/r3dge/ANS-public/raw/refs/heads/main/bin/killbit}"
# Empreinte attendue, optionnelle. L'URL pointe sur refs/heads/main : le binaire
# peut changer sans préavis, et on ne grave pas une image dont on ignore le
# contenu. Renseigner cette variable fige la version.
KILLBIT_SHA256="${KILLBIT_SHA256:-}"
# Navigateur embarqué pour la future page d'état locale de killbit.
# 0 pour alléger l'ISO d'environ 266 Mo installés.
KILLBIT_WITH_BROWSER="${KILLBIT_WITH_BROWSER:-1}"

# Prérequis déduits du binaire, pas devinés :
#   readelf -d : libcurl.so.4, libsodium.so.23, libstdc++.so.6, libgcc_s.so.1
#   strings    : hdparm, nvme, smartctl, blkdiscard, lsblk, udevadm
#   libcurl vers des endpoints HTTPS : réseau + autorités de certification
PACKAGES=(
  # bibliothèques dynamiques exigées par killbit
  libcurl4t64 libsodium23 libstdc++6 libgcc-s1
  # outils appelés par killbit
  hdparm nvme-cli smartmontools util-linux udev
  # identification matérielle
  dmidecode pciutils usbutils lshw
  # réseau
  ca-certificates curl iproute2 systemd-resolved
  # système live
  # systemd-sysv est INDISPENSABLE : il fournit /sbin/init. Avec --variant=minbase
  # et --no-install-recommends il n'est pas tiré, et le noyau panique au
  # démarrage sur « Attempted to kill init ». Vérifié en VM.
  linux-image-amd64 systemd-sysv live-boot live-config live-config-systemd
  # micrologiciels ciblés : réseau et divers. On évite volontairement les gros
  # blobs GPU, qui pèsent des centaines de Mo pour un outil sans interface 3D.
  firmware-linux-free firmware-misc-nonfree firmware-realtek firmware-iwlwifi
  # environnement graphique minimal (openbox + xterm, pas de bureau complet)
  xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-all
  xinit xauth x11-xserver-utils openbox xterm fonts-dejavu-core dbus-x11
  # confort opérateur
  less nano kbd console-setup
  # amorçage
  isolinux syslinux-common grub-efi-amd64-bin grub-common mtools dosfstools
)
[[ "$KILLBIT_WITH_BROWSER" == "1" ]] && PACKAGES+=(firefox-esr)

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERREUR : %b\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Ce script doit être exécuté avec sudo."
[[ -d "$OVERLAY_SRC" ]] || die "Introuvable : $OVERLAY_SRC"

for cmd in debootstrap mksquashfs xorriso curl; do
  command -v "$cmd" >/dev/null || die "Commande requise absente : $cmd"
done

# debootstrap vérifie la signature de l'archive. Sur un hôte Ubuntu, seul le
# trousseau Ubuntu est présent et l'amorçage d'une base Debian échoue sur une
# erreur GPG peu explicite. On échoue tôt, avec la commande qui corrige.
DEBIAN_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
DEBOOTSTRAP_OPTS=(--arch=amd64 --variant=minbase)
if [[ -f "$DEBIAN_KEYRING" ]]; then
  DEBOOTSTRAP_OPTS+=(--keyring "$DEBIAN_KEYRING")
elif ! [[ -f /etc/debian_version ]] || ! grep -qi debian /etc/os-release; then
  die "Trousseau Debian absent : $DEBIAN_KEYRING\n  Corriger avec : sudo apt-get install -y debian-archive-keyring"
fi

mounted=()
cleanup() {
  local m
  for ((i=${#mounted[@]}-1; i>=0; i--)); do
    m="${mounted[i]}"
    if mountpoint -q "$m"; then
      umount "$m" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

bind_mount() {
  local target="$1"; shift
  mount "$@" "$target"
  mounted+=("$target")
}

# --- 1. killbit d'abord : inutile de construire si le binaire est inattendu ---
log "Téléchargement de killbit depuis $KILLBIT_URL"
install -d -m 0755 "$WORK_ROOT"
curl -fsSL --retry 3 --retry-delay 2 -o "$WORK_ROOT/killbit" "$KILLBIT_URL" \
  || die "Téléchargement de killbit impossible"
actual_sha="$(sha256sum "$WORK_ROOT/killbit" | cut -d' ' -f1)"
if [[ -n "$KILLBIT_SHA256" ]]; then
  [[ "$actual_sha" == "$KILLBIT_SHA256" ]] \
    || die "Empreinte killbit inattendue.\n  attendue : $KILLBIT_SHA256\n  obtenue  : $actual_sha"
  log "Empreinte killbit vérifiée : $actual_sha"
else
  log "Empreinte killbit (aucune attendue fournie) : $actual_sha"
fi
file "$WORK_ROOT/killbit" | grep -q 'ELF 64-bit' || die "killbit n'est pas un ELF 64 bits"

# --- 2. Chroot de base --------------------------------------------------------
if [[ -d "$CHROOT" ]]; then
  log "Chroot existant réutilisé : $CHROOT (supprimer $WORK_ROOT pour repartir de zéro)"
else
  log "Debootstrap de $DISTRO (plusieurs minutes)"
  debootstrap "${DEBOOTSTRAP_OPTS[@]}" "$DISTRO" "$CHROOT" "$MIRROR"
fi

bind_mount "$CHROOT/dev" --bind /dev
bind_mount "$CHROOT/dev/pts" --bind /dev/pts
bind_mount "$CHROOT/proc" -t proc proc
bind_mount "$CHROOT/sys" -t sysfs sysfs
install -m 0644 /etc/resolv.conf "$CHROOT/etc/resolv.conf"

# non-free-firmware est une composante distincte depuis Debian 12 : sans elle,
# les micrologiciels réseau sont introuvables et beaucoup de portables anciens
# démarrent sans carte Wi-Fi ni Ethernet fonctionnelle.
cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $DISTRO main non-free-firmware
deb $MIRROR $DISTRO-updates main non-free-firmware
deb http://security.debian.org/debian-security $DISTRO-security main non-free-firmware
EOF

cat > "$CHROOT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$CHROOT/usr/sbin/policy-rc.d"

in_chroot() { chroot "$CHROOT" /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"; }

# --- 3. Paquets ---------------------------------------------------------------
log "apt-get update"
in_chroot apt-get update
in_chroot apt-get upgrade -y
log "Installation des paquets (${#PACKAGES[@]} paquets, sans recommandations)"
# --no-install-recommends garde l'image légère ; c'est pour cela que les pilotes
# d'entrée X (xserver-xorg-input-libinput) sont listés explicitement, sans quoi
# le clavier et la souris ne fonctionneraient pas sous X.
in_chroot apt-get install -y --no-install-recommends "${PACKAGES[@]}"

# live-boot doit être présent avant la génération de l'initramfs pour que ses
# hooks y soient inclus ; on régénère quel que soit l'ordre choisi par apt.
log "Régénération de l'initramfs avec le support live-boot"
in_chroot update-initramfs -u -k all

# --- 4. killbit et overlay ----------------------------------------------------
log "Installation de killbit et de l'overlay"
install -D -m 0755 -o root -g root "$WORK_ROOT/killbit" "$CHROOT/usr/local/bin/killbit"
printf 'url=%s\nsha256=%s\nbase=debian-%s\nbuilt=%s\n' \
  "$KILLBIT_URL" "$actual_sha" "$DISTRO" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  > "$CHROOT/etc/killbit-image-release"

cp -a "$OVERLAY_SRC/." "$CHROOT/"
# cp -a conserve l'UID du dépôt (1000) : sans ce chown, des fichiers exécutés en
# root au démarrage appartiendraient à un utilisateur non privilégié dans l'image.
while IFS= read -r -d '' rel; do
  chown root:root "$CHROOT/$rel"
done < <(cd "$OVERLAY_SRC" && find . -mindepth 1 -printf '%P\0')
chmod 0755 "$CHROOT/usr/local/sbin/killbit-session.sh"
chmod 0644 "$CHROOT/etc/systemd/network/10-dhcp.network"

# Connexion automatique en root sur tty1, qui enchaîne sur la session graphique.
install -d -m 0755 "$CHROOT/etc/systemd/system/getty@tty1.service.d"
cat > "$CHROOT/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# Sans networkd activé et sans fichier .network, l'image démarre sans adresse IP
# et killbit ne peut remonter aucun rapport.
in_chroot systemctl enable systemd-networkd.service systemd-resolved.service killbit-ready.service

echo "killbit-live" > "$CHROOT/etc/hostname"

# --- 5. Chargeur UEFI (GRUB), construit DANS le chroot ------------------------
log "Construction du chargeur UEFI (GRUB x86_64-efi)"
# NE PAS redefinir prefix ici. grub-mkstandalone embarque ses modules dans un
# memdisk et prefix pointe dessus ; le faire pointer vers l'ISO fait chercher
# les modules dans /boot/grub/x86_64-efi/ qui n'existe pas sur le media, et
# GRUB tombe sur son invite avec « configfile.mod not found ». Verifie en VM.
# search suffit : il positionne $root sur l'ISO pour la lecture du menu.
cat > "$CHROOT/tmp/grub-embed.cfg" <<EOF
search --no-floppy --set=root --label $VOLID
configfile /boot/grub/grub.cfg
EOF

# shellcheck disable=SC2016  # quotes simples voulues : ce script s'evalue
# dans le chroot, pas sur l'hote. Une expansion ici casserait grub-mkstandalone.
in_chroot /bin/bash -c '
  set -Eeuo pipefail
  grub-mkstandalone -O x86_64-efi -o /tmp/BOOTX64.EFI \
    --locales= --themes= --fonts= \
    "boot/grub/grub.cfg=/tmp/grub-embed.cfg"
  kb=$(( ($(stat -c %s /tmp/BOOTX64.EFI) / 1024) + 512 ))
  mkfs.vfat -n KILLBITEFI -C /tmp/efi.img "$kb" >/dev/null
  mmd   -i /tmp/efi.img ::/EFI ::/EFI/BOOT
  mcopy -i /tmp/efi.img /tmp/BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI
'
install -m 0644 "$CHROOT/tmp/efi.img" "$WORK_ROOT/efi.img"
rm -f "$CHROOT/tmp/efi.img" "$CHROOT/tmp/BOOTX64.EFI" "$CHROOT/tmp/grub-embed.cfg"

# --- 6. Nettoyage -------------------------------------------------------------
in_chroot apt-get clean
rm -f "$CHROOT/usr/sbin/policy-rc.d"
rm -rf "$CHROOT/var/lib/apt/lists/"*
# Supprimer resolv.conf sans rien mettre à la place laisse le live sans aucune
# résolution DNS, donc sans remontée de rapport possible.
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"

cleanup
trap - EXIT

# --- 7. Noyau, initrd, squashfs -----------------------------------------------
log "Extraction du noyau et de l'initrd"
install -d -m 0755 "$ISO_STAGE/live" "$ISO_STAGE/isolinux" "$ISO_STAGE/boot/grub"
kernel="$(find "$CHROOT/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -n1)"
initrd="$(find "$CHROOT/boot" -maxdepth 1 -name 'initrd.img-*' | sort -V | tail -n1)"
[[ -n "$kernel" && -n "$initrd" ]] || die "Noyau ou initrd introuvable dans $CHROOT/boot"
install -m 0644 "$kernel" "$ISO_STAGE/live/vmlinuz"
install -m 0644 "$initrd" "$ISO_STAGE/live/initrd.img"

log "Construction de filesystem.squashfs"
rm -f "$ISO_STAGE/live/filesystem.squashfs"
mksquashfs "$CHROOT" "$ISO_STAGE/live/filesystem.squashfs" \
  -comp xz -noappend -wildcards \
  -e "boot/vmlinuz-*" -e "boot/initrd.img-*"

# --- 8. Menus d'amorçage ------------------------------------------------------
log "Préparation des chargeurs"
install -m 0644 "$CHROOT/usr/lib/ISOLINUX/isolinux.bin" "$ISO_STAGE/isolinux/isolinux.bin"
cp -a "$CHROOT/usr/lib/syslinux/modules/bios/"*.c32 "$ISO_STAGE/isolinux/" 2>/dev/null || true

cat > "$ISO_STAGE/isolinux/isolinux.cfg" <<EOF
DEFAULT killbit
PROMPT 0
TIMEOUT 50

LABEL killbit
  MENU LABEL killbit -- effacement securise
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components quiet console=tty0 console=ttyS0,115200n8
EOF

install -m 0644 "$WORK_ROOT/efi.img" "$ISO_STAGE/boot/grub/efi.img"
cat > "$ISO_STAGE/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "killbit -- effacement securise" {
    linux /live/vmlinuz boot=live components quiet console=tty0 console=ttyS0,115200n8
    initrd /live/initrd.img
}
EOF

# --- 9. Assemblage ------------------------------------------------------------
log "Construction de l'ISO"
install -d -m 0755 "$(dirname "$OUTPUT_ISO")"
rm -f "$OUTPUT_ISO"
# Deux entrées El Torito : BIOS (isolinux) puis UEFI (efi.img). -isohybrid-mbr et
# -isohybrid-gpt-basdat rendent l'ISO dd-able sur clé USB dans les deux modes.
xorriso -as mkisofs \
  -r -V "$VOLID" -J -l \
  -isohybrid-mbr "$CHROOT/usr/lib/ISOLINUX/isohdpfx.bin" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o "$OUTPUT_ISO" "$ISO_STAGE"

sha256sum "$OUTPUT_ISO" | tee "${OUTPUT_ISO}.sha256"
log "Terminé : $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
echo "killbit embarqué : sha256 $actual_sha"
echo "Pour écrire sur une clé USB :"
echo "  sudo dd if=\"$OUTPUT_ISO\" of=/dev/sdX bs=4M status=progress conv=fsync"
