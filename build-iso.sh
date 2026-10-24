#!/usr/bin/env bash
# Construit une ISO live hybride BIOS (isolinux) + UEFI (GRUB) embarquant
# l'exécutable killbit et tous ses prérequis d'exécution.
#
# killbit est un binaire C++ construit sur Ubuntu 24.04 : il exige GLIBC_2.38,
# donc la base de l'image DOIT être noble ou plus récent. Ne pas rétrograder.
#
# Usage : sudo ./build-iso.sh [chemin-de-sortie.iso]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_SRC="$SCRIPT_DIR/overlay"

WORK_ROOT="${KILLBIT_ISO_WORK:-/srv/killbit-iso-build}"
CHROOT="$WORK_ROOT/chroot"
ISO_STAGE="$WORK_ROOT/iso"
DISTRO="${KILLBIT_DISTRO:-noble}"
MIRROR="${KILLBIT_MIRROR:-http://archive.ubuntu.com/ubuntu}"
OUTPUT_ISO="${1:-$WORK_ROOT/killbit-live.iso}"
VOLID="KILLBIT"

KILLBIT_URL="${KILLBIT_URL:-https://github.com/r3dge/ANS-public/raw/refs/heads/main/bin/killbit}"
# Empreinte attendue, optionnelle. Si elle est fournie et ne correspond pas, on
# s'arrête : l'URL pointe sur refs/heads/main, donc le binaire peut changer sans
# préavis et on ne grave pas une image dont on ignore le contenu.
KILLBIT_SHA256="${KILLBIT_SHA256:-}"

# Prérequis d'exécution de killbit, déduits du binaire lui-même :
#   readelf -d  -> libcurl.so.4, libsodium.so.23, libstdc++.so.6, libgcc_s.so.1
#   strings     -> hdparm, nvme-cli, smartctl, blkdiscard, lsblk, udevadm
#   libcurl + endpoints HTTPS -> réseau et autorités de certification requis
PACKAGES=(
  # bibliothèques dynamiques exigées par le binaire
  libcurl4t64 libsodium23 libstdc++6 libgcc-s1
  # outils que killbit appelle pour l'effacement et le diagnostic
  hdparm nvme-cli smartmontools util-linux udev
  # identification matérielle
  dmidecode pciutils usbutils lshw
  # réseau : killbit remonte ses rapports en HTTPS
  ca-certificates curl iproute2 netplan.io
  # confort opérateur
  less nano kbd console-setup
  # système live
  linux-image-generic
  live-boot live-config live-config-systemd
  isolinux syslinux-common
  grub-efi-amd64-bin grub-common mtools dosfstools
)

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERREUR : %b\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Ce script doit être exécuté avec sudo."
[[ -d "$OVERLAY_SRC" ]] || die "Introuvable : $OVERLAY_SRC"

for cmd in debootstrap mksquashfs xorriso curl; do
  command -v "$cmd" >/dev/null || die "Commande requise absente : $cmd"
done

mounted=()
cleanup() {
  local m
  for ((i=${#mounted[@]}-1; i>=0; i--)); do
    m="${mounted[i]}"
    mountpoint -q "$m" && umount "$m" 2>/dev/null || true
  done
}
trap cleanup EXIT

bind_mount() {
  local target="$1"; shift
  mount "$@" "$target"
  mounted+=("$target")
}

# --- 1. Récupérer et vérifier killbit AVANT de construire quoi que ce soit ----
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
  log "Empreinte killbit (non vérifiée, aucune attendue fournie) : $actual_sha"
fi
file "$WORK_ROOT/killbit" | grep -q 'ELF 64-bit' || die "killbit n'est pas un ELF 64 bits"

# --- 2. Chroot de base --------------------------------------------------------
if [[ -d "$CHROOT" ]]; then
  log "Chroot existant réutilisé : $CHROOT (supprimer $WORK_ROOT pour repartir de zéro)"
else
  log "Debootstrap de $DISTRO (plusieurs minutes)"
  debootstrap --arch=amd64 "$DISTRO" "$CHROOT" "$MIRROR"
fi

bind_mount "$CHROOT/dev" --bind /dev
bind_mount "$CHROOT/dev/pts" --bind /dev/pts
bind_mount "$CHROOT/proc" -t proc proc
bind_mount "$CHROOT/sys" -t sysfs sysfs
install -m 0644 /etc/resolv.conf "$CHROOT/etc/resolv.conf"

cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $DISTRO main restricted universe multiverse
deb $MIRROR $DISTRO-updates main restricted universe multiverse
deb $MIRROR $DISTRO-security main restricted universe multiverse
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
# dpkg s'auto-met-à-jour parfois de façon instable au milieu d'une grosse
# transaction en chroot : le traiter seul d'abord évite une course.
in_chroot apt-get install --only-upgrade -y dpkg
in_chroot apt-get upgrade -y
log "Installation des paquets : ${PACKAGES[*]}"
in_chroot apt-get install -y "${PACKAGES[@]}"

# live-boot doit être présent avant la génération de l'initramfs pour que ses
# hooks y soient inclus ; on régénère explicitement quel que soit l'ordre d'apt.
log "Régénération de l'initramfs avec le support live-boot"
in_chroot update-initramfs -u -k all

# --- 4. killbit et overlay ----------------------------------------------------
log "Installation de killbit et de l'overlay"
install -D -m 0755 -o root -g root "$WORK_ROOT/killbit" "$CHROOT/usr/local/bin/killbit"
printf '%s  killbit\n' "$actual_sha" > "$CHROOT/usr/local/share/killbit.sha256"
printf 'url=%s\nsha256=%s\nbuilt=%s\n' \
  "$KILLBIT_URL" "$actual_sha" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  > "$CHROOT/etc/killbit-image-release"

cp -a "$OVERLAY_SRC/." "$CHROOT/"
# cp -a conserve l'UID du dépôt (1000) : sans ce chown, des fichiers exécutés en
# root au démarrage appartiendraient à un utilisateur non privilégié dans l'image.
while IFS= read -r -d '' rel; do
  chown root:root "$CHROOT/$rel"
done < <(cd "$OVERLAY_SRC" && find . -mindepth 1 -printf '%P\0')
chmod 0755 "$CHROOT/usr/local/sbin/killbit-launcher.sh"
chmod 0600 "$CHROOT/etc/netplan/01-killbit-dhcp.yaml"

install -d -m 0755 "$CHROOT/etc/systemd/system/getty@tty1.service.d"
cat > "$CHROOT/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# live-config ne configure pas le réseau (aucun composant DHCP dans
# /lib/live/config) et /etc/netplan est vide dans un chroot debootstrap : sans
# networkd+resolved activés et sans le netplan DHCP de l'overlay, le live
# démarre sans adresse IP et killbit ne peut rien remonter.
in_chroot systemctl enable systemd-networkd.service systemd-resolved.service

echo "killbit-live" > "$CHROOT/etc/hostname"

# --- 5. Chargeur UEFI (GRUB), construit DANS le chroot ------------------------
# L'hôte n'a ainsi besoin que de xorriso.
log "Construction du chargeur UEFI (GRUB x86_64-efi)"
cat > "$CHROOT/tmp/grub-embed.cfg" <<EOF
search --no-floppy --set=root --label $VOLID
set prefix=(\$root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

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
  APPEND initrd=/live/initrd.img boot=live components quiet
EOF

install -m 0644 "$WORK_ROOT/efi.img" "$ISO_STAGE/boot/grub/efi.img"
cat > "$ISO_STAGE/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "killbit -- effacement securise" {
    linux /live/vmlinuz boot=live components quiet
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
