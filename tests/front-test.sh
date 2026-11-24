#!/usr/bin/env bash
# Vérifie que l'image guidée affiche réellement son front ncurses sur tty1 et
# qu'il réagit à la saisie d'un identifiant.
#
# Un contrôle de contenu ne peut pas voir ce défaut : les fichiers peuvent tous
# être là et la console rester noire — .bash_profile qui n'enchaîne pas, dialog
# qui ne s'ouvre pas, front qui sort aussitôt. On regarde donc l'écran.
#
# Le verdict est automatique, sans OCR : dialog peint le fond de l'écran en
# bleu VGA sur toute sa surface, ce qu'une console en texte ne fait jamais. On
# compte donc les pixels bleus, puis on vérifie que l'écran CHANGE après la
# saisie — c'est ce qui distingue un front vivant d'une image figée.
#
# Usage : tests/front-test.sh <image.iso> [dossier_de_sortie] [timeout_s]
set -Eeuo pipefail

ISO="${1:?Usage: front-test.sh <image.iso> [dossier_de_sortie] [timeout_s]}"
OUTDIR="${2:-$PWD/front-test-out}"
TIMEOUT="${3:-600}"
MARKER="KILLBIT-IMAGE-READY"
ID_TEST="R21062200075"
# Part minimale de l'écran peinte en bleu pour conclure qu'un front dialog est
# affiché. Calibré sur l'image réelle : ~0,78 pour l'écran de saisie.
SEUIL_BLEU="${SEUIL_BLEU:-0.40}"
# Part de pixels qui doivent différer entre deux captures pour conclure que
# l'écran a changé.
SEUIL_DIFF="${SEUIL_DIFF:-0.02}"

[[ -f "$ISO" ]] || { echo "ERREUR : introuvable : $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "ERREUR : qemu-system-x86_64 absent" >&2; exit 1; }
command -v socat >/dev/null || { echo "ERREUR : socat absent" >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "ERREUR : qemu-img absent" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERREUR : python3 absent" >&2; exit 1; }

mkdir -p "$OUTDIR"
workdir="$(mktemp -d)"
log="$workdir/serie.log"
sock="$workdir/mon.sock"

# Un disque vierge, pour que le front ait quelque chose a proposer d'effacer :
# sans lui, il affiche « aucun support detecte » et le recapitulatif — l'ecran
# le plus important a verifier — n'est jamais atteint. Rien ne sera ecrit
# dessus : le test s'arrete avant la confirmation.
qemu-img create -f qcow2 "$workdir/disque.qcow2" 8G >/dev/null

qemu_args=(
  -m 2048 -smp 2
  -cdrom "$ISO"
  -drive "file=$workdir/disque.qcow2,if=virtio,format=qcow2"
  -display none
  -serial "file:$log"
  -monitor "unix:$sock,server,nowait"
  -no-reboot
  # NIC en mode utilisateur : le front affiche l'adresse obtenue, et une image
  # sans réseau du tout ne ressemblerait pas à un poste d'atelier.
  -nic "user,model=virtio-net-pci"
)
if [[ -w /dev/kvm ]]; then
  qemu_args+=(-enable-kvm -cpu host)
  echo "[front-test] KVM disponible"
else
  echo "[front-test] pas de KVM, emulation logicielle (plus lent)"
fi

qemu-system-x86_64 "${qemu_args[@]}" &
qemu_pid=$!
# shellcheck disable=SC2064
trap "kill $qemu_pid 2>/dev/null || true; rm -rf '$workdir'" EXIT

hmp() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1; }

# Frappe un texte au clavier du poste. La console de l'image est en AZERTY :
# « sendkey 2 » y produit « é ». Les chiffres passent donc par shift-<chiffre>,
# ce qui est aussi ce que fait l'opérateur sur le clavier du portable.
taper() {
  local texte="$1" i c
  for (( i=0; i<${#texte}; i++ )); do
    c="${texte:i:1}"
    case "$c" in
      [0-9])    hmp "sendkey shift-$c" ;;
      [A-Z])    hmp "sendkey shift-${c,,}" ;;
      [a-z])    hmp "sendkey $c" ;;
      *) echo "[front-test] caractere non gere : $c" >&2; return 1 ;;
    esac
    sleep 0.15
  done
}

capture() {
  local nom="$1"
  local ppm="$workdir/$nom.ppm"
  rm -f "$ppm"
  hmp "screendump $ppm"
  for _ in $(seq 1 20); do
    [[ -s "$ppm" ]] && { sleep 0.3; printf '%s' "$ppm"; return 0; }
    sleep 0.3
  done
  echo "[front-test] capture $nom impossible" >&2
  return 1
}

analyse() {
  python3 - "$@" <<'PY'
import sys

def lire(p):
    with open(p, 'rb') as f:
        data = f.read()
    # En-tête PPM binaire : P6, largeur, hauteur, valeur max, séparés par des
    # blancs, avec d'éventuels commentaires.
    champs, i = [], 2
    while len(champs) < 3:
        while i < len(data) and data[i:i+1].isspace():
            i += 1
        if data[i:i+1] == b'#':
            while data[i:i+1] not in (b'\n', b''):
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j+1].isspace():
            j += 1
        champs.append(int(data[i:j]))
        i = j
    i += 1
    w, h, _ = champs
    return w, h, data[i:i + w * h * 3]

mode = sys.argv[1]
if mode == 'bleu':
    w, h, px = lire(sys.argv[2])
    bleus = total = 0
    for k in range(0, len(px), 3):
        r, g, b = px[k], px[k+1], px[k+2]
        total += 1
        if b >= 110 and r <= 90 and g <= 90:
            bleus += 1
    print(f'{bleus/total:.4f} {w}x{h}')
elif mode == 'diff':
    w1, h1, a = lire(sys.argv[2])
    w2, h2, b = lire(sys.argv[3])
    if (w1, h1) != (w2, h2):
        print('1.0000 dimensions differentes')
        sys.exit(0)
    n = min(len(a), len(b))
    diff = sum(1 for k in range(0, n, 3) if a[k:k+3] != b[k:k+3])
    print(f'{diff/(n//3):.4f} {w1}x{h1}')
elif mode == 'png':
    # Les captures ne servent qu'a l'oeil humain : si PIL n'est pas la, on
    # recopie le PPM plutot que de faire echouer un test par ailleurs concluant.
    w, h, px = lire(sys.argv[2])
    try:
        from PIL import Image
    except ImportError:
        import shutil
        cible = sys.argv[3].rsplit('.', 1)[0] + '.ppm'
        shutil.copyfile(sys.argv[2], cible)
        print(cible)
    else:
        Image.frombytes('RGB', (w, h), px[:w*h*3]).save(sys.argv[3])
        print(sys.argv[3])
PY
}

# Comparaison de deux flottants, sans bc : il n'est pas garanti present.
sup() { python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)" "$1" "$2"; }

echo "[front-test] attente du marqueur (timeout ${TIMEOUT}s)"
deadline=$(( SECONDS + TIMEOUT ))
pret=0
while (( SECONDS < deadline )); do
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo "[front-test] QEMU s'est arrete avant le marqueur"; break
  fi
  if grep -qa "$MARKER" "$log" 2>/dev/null; then pret=1; break; fi
  sleep 3
done
(( pret == 1 )) || { echo "[front-test] ECHEC : marqueur absent"; tail -30 "$log"; exit 1; }
echo "[front-test] marqueur vu : $(grep -ha "$MARKER" "$log" | head -1)"

# Le marqueur vient de multi-user.target ; l'autologin puis dialog arrivent
# juste apres. On ATTEND que l'ecran devienne bleu au lieu de dormir un temps
# fixe : sous emulation, et surtout a plusieurs machines virtuelles en
# parallele sur un runner, un delai en dur est soit trop court, soit du temps
# perdu a chaque execution.
saisie_ppm=""
part_bleu="0"
deadline=$(( SECONDS + 180 ))
while (( SECONDS < deadline )); do
  saisie_ppm="$(capture 1-saisie)" || break
  part_bleu="$(analyse bleu "$saisie_ppm" | cut -d' ' -f1)"
  sup "$part_bleu" "$SEUIL_BLEU" && break
  sleep 5
done
echo "[front-test] ecran de saisie : $part_bleu de surface bleue (seuil $SEUIL_BLEU)"
[[ -n "$saisie_ppm" ]] || { echo "[front-test] ECHEC : aucune capture"; exit 1; }
analyse png "$saisie_ppm" "$OUTDIR/1-saisie.png" >/dev/null

echo "[front-test] saisie de l'identifiant $ID_TEST"
taper "$ID_TEST"
sleep 1
frappe_ppm="$(capture 2-frappe)"
analyse png "$frappe_ppm" "$OUTDIR/2-frappe.png" >/dev/null

hmp "sendkey ret"
sleep 3
recap_ppm="$(capture 3-recap)"
analyse png "$recap_ppm" "$OUTDIR/3-recap.png" >/dev/null
part_diff="$(analyse diff "$saisie_ppm" "$recap_ppm" | cut -d' ' -f1)"
echo "[front-test] apres validation : $part_diff de pixels modifies (seuil $SEUIL_DIFF)"

# On s'arrete avant de confirmer : le dernier « Effacer » lance un effacement
# reel, et ce test ne doit jamais en declencher un, meme sur disque virtuel.
hmp "sendkey esc"

echo "[front-test] captures dans $OUTDIR"
rc=0
sup "$part_bleu" "$SEUIL_BLEU" || { echo "[front-test] ECHEC : pas de front dialog a l'ecran"; rc=1; }
sup "$part_diff" "$SEUIL_DIFF" || { echo "[front-test] ECHEC : l'ecran n'a pas reagi a la saisie"; rc=1; }
(( rc == 0 )) && echo "[front-test] OK : front affiche et reactif"
exit "$rc"
