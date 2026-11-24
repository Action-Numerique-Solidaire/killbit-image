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
# Front de l'operateur sur tty1. Deux valeurs :
#   shell  (defaut) : ecran d'accueil en texte, puis un shell. L'operateur tape
#                     lui-meme la commande, pre-remplie dans l'historique.
#   guide           : front ncurses (dialog) qui ne demande que l'identifiant du
#                     poste, puis lance killbit avec --yes. Aucune confirmation
#                     de killbit, donc une seule dans le front, au recapitulatif.
KILLBIT_FRONT="${KILLBIT_FRONT:-shell}"
case "$KILLBIT_FRONT" in
  shell|guide) ;;
  *) printf 'ERREUR : KILLBIT_FRONT doit valoir shell ou guide (recu : %s)\n' \
       "$KILLBIT_FRONT" >&2; exit 1 ;;
esac
# Les deux images coexistent dans la meme release : elles ne peuvent pas porter
# le meme nom de fichier par defaut.
DEFAULT_ISO_NAME="killbit-live.iso"
[[ "$KILLBIT_FRONT" == "guide" ]] && DEFAULT_ISO_NAME="killbit-live-guide.iso"
OUTPUT_ISO="${1:-$WORK_ROOT/$DEFAULT_ISO_NAME}"
VOLID="KILLBIT"

KILLBIT_URL="${KILLBIT_URL:-https://github.com/r3dge/ANS-public/raw/refs/heads/main/bin/killbit}"
# Empreinte attendue, optionnelle. L'URL pointe sur refs/heads/main : le binaire
# peut changer sans préavis, et on ne grave pas une image dont on ignore le
# contenu. Renseigner cette variable fige la version.
KILLBIT_SHA256="${KILLBIT_SHA256:-}"
# Environnement graphique : l'image est console seule par défaut. killbit ne
# sert aucune page d'état locale pour l'instant, et X + firefox pesaient 727 Mo
# sur les 1101 Mo installés de l'ancienne image — les deux tiers du poids pour
# une fonction qui n'a rien à afficher. Mettre cette variable à 1 réembarque X
# et firefox, SANS gestionnaire de fenêtres, le jour où cette page existera.
KILLBIT_WITH_BROWSER="${KILLBIT_WITH_BROWSER:-0}"

# Wi-Fi : micrologiciels et wpasupplicant. Actif par defaut, parce que killbit
# mesure le Wi-Fi de chaque portable et remonte le resultat au serveur ; sans
# cela il remonte une panne qui n'existe pas. Voir le bloc de paquets plus bas
# pour le detail et le cout. Mettre a 0 pour une image volontairement reduite,
# en sachant que tous les rapports porteront « wifi non operationnel ».
KILLBIT_WITH_WIFI="${KILLBIT_WITH_WIFI:-1}"

# Point de remontée des rapports. Une seule source : l'écran d'accueil et
# l'historique pré-rempli en sont tous deux dérivés, ils ne peuvent donc pas
# diverger.
KILLBIT_REPORT_URL="${KILLBIT_REPORT_URL:-https://actionnumeriquesolidaire.org}"

# Disposition clavier de la console. L'opérateur doit taper un identifiant de
# poste et une URL : sur un clavier AZERTY avec une disposition US, « / » et
# « : » ne sont pas là où il les cherche.
KILLBIT_KEYMAP="${KILLBIT_KEYMAP:-fr}"

# Compression du squashfs. zstd décompresse plusieurs fois plus vite que xz, ce
# qui raccourcit autant le démarrage chez l'opérateur que les tests d'amorçage,
# pour quelques Mo de plus. Le noyau Debian 13 déclare CONFIG_SQUASHFS_ZSTD=y,
# donc l'image reste montable (vérifié dans /boot/config-*).
SQUASHFS_COMP="${KILLBIT_SQUASHFS_COMP:-zstd}"
SQUASHFS_LEVEL="${KILLBIT_SQUASHFS_LEVEL:-19}"

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
  # micrologiciels : réseau filaire et divers. Pas de blobs GPU, qui pèsent des
  # centaines de Mo pour un outil sans interface 3D. Le Wi-Fi est plus bas,
  # conditionné à KILLBIT_WITH_WIFI.
  firmware-linux-free firmware-misc-nonfree firmware-realtek
  # Dependances declarees par killbit lui-meme. Elles ne sont pas optionnelles :
  # le binaire porte une liste REQUIRED_PACKAGES, la controle au demarrage avec
  # « dpkg-query -W -f='${Status}' » — donc au niveau paquet, pas binaire — et
  # propose sinon de l'installer avec « sudo apt install ». Sur une image live
  # sans depot a jour, cette installation est au mieux lente, au pire
  # impossible : il faut les embarquer.
  #
  # Chacune est reellement appelee a l'execution, verifie dans les chaines du
  # binaire : inxi -G -s -N -A -C -M -m -I --output json (inventaire materiel,
  # d'ou libcpanel-json-xs-perl pour la sortie JSON), sensors -u, upower -i,
  # memtester, nmcli dev wifi list.
  sudo inxi libcpanel-json-xs-perl memtester lm-sensors upower network-manager
  # zstd : sans ce binaire dans le chroot, initramfs-tools avertit « No zstd in
  # /usr/bin:/sbin:/bin, using gzip » et retombe sur gzip, alors que zstd est le
  # réglage par défaut de Debian 13. L'initramfs est alors plus gros et plus lent
  # à décompresser à chaque démarrage, pour 1 Mo économisé à la construction.
  zstd
  # confort opérateur en console. console-setup applique la disposition clavier :
  # sans elle, saisir « https:// » et un identifiant au clavier AZERTY est une
  # épreuve.
  less nano kbd console-setup
  # amorçage. Servent uniquement à FABRIQUER l'image, puis sont purgés du chroot
  # avant le squashfs (étape 6) : ils n'ont rien à faire dans l'image livrée.
  isolinux syslinux-common grub-efi-amd64-bin grub-common mtools dosfstools
)
BUILD_ONLY_PACKAGES=(isolinux syslinux-common grub-efi-amd64-bin grub-common mtools dosfstools)

# Wi-Fi. killbit teste le Wi-Fi de chaque portable — « nmcli dev wifi list »
# dans run_laptop_and_wifi_check, après avoir vu une batterie avec « upower -e »
# — et remonte le résultat au serveur sous "Type":"Wifi". Sans micrologiciel ni
# wpasupplicant, la carte ne s'initialise pas, nmcli ne renvoie rien, et le
# rapport porte « wifi non opérationnel » sur un poste dont la carte marche
# peut-être très bien. Ce n'était donc pas une limitation de confort mais une
# mesure fausse, enregistrée à chaque passage.
#
# Le coût sur l'ISO n'est pas la taille installée : squashfs recompresse ces
# blobs à peu près comme le fait le .deb. Mesuré dans le chroot (deb/installé) :
#   firmware-iwlwifi     15,9 / 111,4 Mo  Intel, majoritaire sur le parc pro
#   firmware-atheros     28,1 /  95,0 Mo  ath10k et ath11k (ath9k est dans le noyau)
#   firmware-brcm80211    5,1 /  17,9 Mo  Broadcom, Mac et grand public
#   firmware-libertas     3,5 /  11,1 Mo  Marvell
#   wpasupplicant + deps  1,7 /   4,6 Mo  sans lui NetworkManager ne pilote rien
#   wireless-regdb       0,01 /  0,04 Mo  base réglementaire ; sans elle le
#                                         balayage est restreint ou refusé
# firmware-ti-connectivity est écarté : wl12xx équipe des cartes embarquées,
# pas les portables d'un parc de réemploi.
if [[ "$KILLBIT_WITH_WIFI" == "1" ]]; then
  PACKAGES+=(
    wpasupplicant wireless-regdb
    firmware-iwlwifi firmware-atheros firmware-brcm80211 firmware-libertas
  )
fi

# Mode guide : le front ncurses. dialog plutot que whiptail parce qu'il
# s'appuie sur libncursesw6, deja tiree par nano, la ou whiptail ajouterait
# libnewt et libslang pour le meme service.
if [[ "$KILLBIT_FRONT" == "guide" ]]; then
  PACKAGES+=(dialog)
fi

# Mode navigateur : X minimal et firefox, sans gestionnaire de fenêtres.
if [[ "$KILLBIT_WITH_BROWSER" == "1" ]]; then
  PACKAGES+=(
    xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-all
    xinit xauth fonts-dejavu-core xterm firefox-esr
  )
fi

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
  local target="$1"
  shift
  mount "$@" "$target"
  # Détacher la propagation du montage. Sans cela, / étant monté en « shared »
  # sur une Ubuntu de bureau, un démontage côté chroot se propage à l'hôte :
  # une construction interrompue a ainsi cassé le /dev/pts d'une machine, qui a
  # dû être redémarrée. En rslave, le chroot reçoit les changements de l'hôte
  # mais ne lui en renvoie aucun.
  mount --make-rslave "$target" 2>/dev/null \
    || mount --make-slave "$target" 2>/dev/null \
    || echo "AVERTISSEMENT : propagation non détachée pour $target" >&2
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

# Documentation, pages de manuel et traductions : une cinquantaine de Mo dans
# une base minbase, davantage une fois la centaine de paquets installée, pour
# une image que personne ne lit hors ligne. Les règles ne s'appliquent qu'aux
# installations suivantes : ce que debootstrap a déjà posé est retiré à l'étape 6.
install -d -m 0755 "$CHROOT/etc/dpkg/dpkg.cfg.d"
cat > "$CHROOT/etc/dpkg/dpkg.cfg.d/01-killbit-minimal" <<'EOF'
path-exclude=/usr/share/doc/*
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/locale/*
# Le français est conservé : c'est la langue des opérateurs.
path-include=/usr/share/locale/fr/*
path-include=/usr/share/locale/fr_FR*/*
EOF

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
printf 'url=%s\nsha256=%s\nbase=debian-%s\nreport_url=%s\nfront=%s\nwifi=%s\nmode=%s\nbuilt=%s\n' \
  "$KILLBIT_URL" "$actual_sha" "$DISTRO" "$KILLBIT_REPORT_URL" "$KILLBIT_FRONT" \
  "$([[ "$KILLBIT_WITH_WIFI" == "1" ]] && echo oui || echo non)" \
  "$([[ "$KILLBIT_WITH_BROWSER" == "1" ]] && echo graphique || echo console)" \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  > "$CHROOT/etc/killbit-image-release"

cp -a "$OVERLAY_SRC/." "$CHROOT/"
# cp -a conserve l'UID du dépôt (1000) : sans ce chown, des fichiers exécutés en
# root au démarrage appartiendraient à un utilisateur non privilégié dans l'image.
while IFS= read -r -d '' rel; do
  chown root:root "$CHROOT/$rel"
done < <(cd "$OVERLAY_SRC" && find . -mindepth 1 -printf '%P\0')
chmod 0755 "$CHROOT/usr/local/sbin/killbit-session.sh"

# .bash_profile choisit le front sur la presence du script, pas sur un drapeau :
# le meme fichier sert donc aux deux images. En mode shell, le retirer est ce
# qui fait tomber le choix sur l'accueil en texte.
if [[ "$KILLBIT_FRONT" == "guide" ]]; then
  chmod 0755 "$CHROOT/usr/local/sbin/killbit-guide.sh"
else
  rm -f "$CHROOT/usr/local/sbin/killbit-guide.sh"
fi

# Historique pré-rempli : la commande d'effacement est alors accessible d'une
# seule flèche vers le haut, ce qui évite de la retaper — URL comprise — sur
# chaque poste. La dernière ligne est celle que renvoie la première flèche.
# Le marqueur <id_du_poste> est laissé tel quel volontairement : s'il n'est pas
# remplacé, le shell refuse la ligne (c'est une redirection invalide) et rien
# ne s'exécute.
cat > "$CHROOT/root/.bash_history" <<EOF
killbit --help
killbit --check
killbit -i <id_du_poste> -u $KILLBIT_REPORT_URL
EOF
# Dans l'image guidee, le shell n'est qu'un detour : la premiere fleche vers le
# haut doit ramener au front, pas a une commande d'effacement a completer.
if [[ "$KILLBIT_FRONT" == "guide" ]]; then
  echo "guide" >> "$CHROOT/root/.bash_history"
fi
chmod 0600 "$CHROOT/root/.bash_history"

# Hors mode navigateur, il n'y a pas de serveur X : laisser un .xinitrc
# rendrait le chemin de démarrage ambigu dans .bash_profile.
if [[ "$KILLBIT_WITH_BROWSER" != "1" ]]; then
  rm -f "$CHROOT/root/.xinitrc"
fi

# Connexion automatique en root sur tty1, qui enchaîne sur la session graphique.
install -d -m 0755 "$CHROOT/etc/systemd/system/getty@tty1.service.d"
cat > "$CHROOT/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

cat > "$CHROOT/etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$KILLBIT_KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# killbit appelle « nmcli dev wifi list » : NetworkManager doit tourner, et deux
# gestionnaires réseau concurrents sur les mêmes interfaces se gênent. On retient
# donc NetworkManager seul pour les interfaces, et systemd-resolved pour le DNS
# — c'est la combinaison que NetworkManager détecte et utilise d'office, et
# /etc/resolv.conf pointe sur son stub.
# Sans cela l'image démarre sans adresse IP et killbit ne remonte aucun rapport.
in_chroot systemctl enable NetworkManager.service systemd-resolved.service killbit-ready.service
in_chroot systemctl disable systemd-networkd.service 2>/dev/null || true

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

# Les artefacts d'amorçage BIOS sont sortis du chroot MAINTENANT, pour que les
# paquets qui les fournissent puissent être purgés avant le squashfs. Les lus
# plus tard depuis le chroot, ils y auraient obligé à garder 37 Mo d'outils de
# fabrication dans l'image livrée.
log "Extraction des artefacts isolinux"
install -d -m 0755 "$WORK_ROOT/bios"
install -m 0644 "$CHROOT/usr/lib/ISOLINUX/isolinux.bin" "$WORK_ROOT/bios/isolinux.bin"
install -m 0644 "$CHROOT/usr/lib/ISOLINUX/isohdpfx.bin" "$WORK_ROOT/bios/isohdpfx.bin"
cp -a "$CHROOT/usr/lib/syslinux/modules/bios/"*.c32 "$WORK_ROOT/bios/" 2>/dev/null || true

# --- 6. Nettoyage -------------------------------------------------------------
# Les outils de fabrication de l'amorçage ne servent plus : leurs artefacts sont
# déjà sortis du chroot. 37 Mo installés qui n'ont rien à faire dans une image
# dont le seul rôle est d'effacer des disques.
log "Purge des paquets de fabrication (${#BUILD_ONLY_PACKAGES[@]} paquets)"
in_chroot apt-get purge -y "${BUILD_ONLY_PACKAGES[@]}"
in_chroot apt-get autoremove --purge -y

# Ce que debootstrap a posé avant les règles dpkg d'exclusion.
log "Retrait de la documentation et des traductions déjà installées"
for d in usr/share/doc usr/share/man usr/share/info usr/share/groff; do
  if [[ -d "${CHROOT:?}/$d" ]]; then
    find "${CHROOT:?}/$d" -mindepth 1 -delete 2>/dev/null || true
  fi
done
if [[ -d "${CHROOT:?}/usr/share/locale" ]]; then
  find "${CHROOT:?}/usr/share/locale" -mindepth 1 -maxdepth 1 -type d \
    ! -name 'fr' ! -name 'fr_FR*' -exec rm -rf {} + 2>/dev/null || true
fi

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
  -comp "$SQUASHFS_COMP" -Xcompression-level "$SQUASHFS_LEVEL" \
  -noappend -wildcards -no-progress \
  -e "boot/vmlinuz-*" -e "boot/initrd.img-*"

# --- 8. Menus d'amorçage ------------------------------------------------------
log "Préparation des chargeurs"
install -m 0644 "$WORK_ROOT/bios/isolinux.bin" "$ISO_STAGE/isolinux/isolinux.bin"
cp -a "$WORK_ROOT/bios/"*.c32 "$ISO_STAGE/isolinux/" 2>/dev/null || true

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
  -isohybrid-mbr "$WORK_ROOT/bios/isohdpfx.bin" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o "$OUTPUT_ISO" "$ISO_STAGE"

# Empreinte au nom nu : le fichier doit rester verifiable par
# « sha256sum -c killbit-live.iso.sha256 » a cote de l'ISO telechargee,
# donc sans le chemin de la machine de construction.
( cd "$(dirname "$OUTPUT_ISO")" && sha256sum "$(basename "$OUTPUT_ISO")" ) \
  | tee "${OUTPUT_ISO}.sha256"
log "Terminé : $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
echo "killbit embarqué : sha256 $actual_sha"
echo "Pour écrire sur une clé USB :"
echo "  sudo dd if=\"$OUTPUT_ISO\" of=/dev/sdX bs=4M status=progress conv=fsync"
