#!/usr/bin/env bash
# Démarre l'ISO dans QEMU et vérifie qu'elle atteint réellement un système
# utilisable, en attendant le marqueur émis par killbit-ready.service.
#
# Ce test existe parce qu'une ISO peut contenir tous les bons fichiers et
# paniquer au démarrage : c'est arrivé, faute de systemd-sysv donc de /sbin/init,
# et aucune vérification de contenu ne pouvait le voir.
#
# Usage : tests/boot-test.sh <image.iso> [bios|uefi] [timeout_s]
set -Eeuo pipefail

ISO="${1:?Usage: boot-test.sh <image.iso> [bios|uefi] [timeout_s]}"
MODE="${2:-bios}"
TIMEOUT="${3:-600}"
MARKER="KILLBIT-IMAGE-READY"
# Motifs d'échec : sans eux, un noyau qui panique ne se distingue pas d'un
# démarrage lent, et le test attendrait son délai entier pour rien.
FAILURES='Kernel panic|Attempted to kill init|No init found|Failed to mount|Entering emergency mode|You are in emergency mode'

[[ -f "$ISO" ]] || { echo "ERREUR : introuvable : $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "ERREUR : qemu-system-x86_64 absent" >&2; exit 1; }

workdir="$(mktemp -d)"
log="$workdir/boot.log"
trap 'rm -rf "$workdir"' EXIT

qemu_args=(
  -m 2048 -smp 2
  -cdrom "$ISO"
  -display none
  -serial "file:$log"
  -no-reboot
  -net none
)

# L'accélération KVM n'est pas disponible sur un runner GitHub : on retombe sur
# l'émulation, plus lente mais suffisante pour un test d'amorçage.
if [[ -w /dev/kvm ]]; then
  qemu_args+=(-enable-kvm -cpu host)
  echo "[boot-test] KVM disponible"
else
  echo "[boot-test] pas de KVM, emulation logicielle (plus lent)"
fi

if [[ "$MODE" == "uefi" ]]; then
  ovmf_code=""
  for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
           /usr/share/ovmf/OVMF.fd; do
    [[ -f "$c" ]] && { ovmf_code="$c"; break; }
  done
  [[ -n "$ovmf_code" ]] || { echo "ERREUR : firmware OVMF introuvable" >&2; exit 1; }
  ovmf_vars_src=""
  for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -f "$v" ]] && { ovmf_vars_src="$v"; break; }
  done
  [[ -n "$ovmf_vars_src" ]] || { echo "ERREUR : variables OVMF introuvables" >&2; exit 1; }
  cp "$ovmf_vars_src" "$workdir/vars.fd"
  qemu_args+=(
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code"
    -drive "if=pflash,format=raw,unit=1,file=$workdir/vars.fd"
  )
fi

echo "[boot-test] mode=$MODE timeout=${TIMEOUT}s iso=$ISO"
qemu-system-x86_64 "${qemu_args[@]}" &
qemu_pid=$!
# shellcheck disable=SC2064
trap "kill $qemu_pid 2>/dev/null || true; rm -rf '$workdir'" EXIT

deadline=$(( SECONDS + TIMEOUT ))
status=1
while (( SECONDS < deadline )); do
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo "[boot-test] QEMU s'est arrete avant le marqueur"
    break
  fi
  if grep -qa "$MARKER" "$log" 2>/dev/null; then
    echo "[boot-test] MARQUEUR TROUVE : $(grep -ha "$MARKER" "$log" | head -1)"
    status=0
    break
  fi
  if grep -qaE "$FAILURES" "$log" 2>/dev/null; then
    echo "[boot-test] ECHEC detecte dans la console serie :"
    grep -haE "$FAILURES" "$log" | head -5
    status=2
    break
  fi
  sleep 3
done

kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true

if (( status == 1 )); then
  echo "[boot-test] DELAI DEPASSE sans marqueur ni panique"
fi
echo "----- 40 dernieres lignes de la console serie -----"
tail -40 "$log" 2>/dev/null || echo "(console vide)"
echo "---------------------------------------------------"
exit "$status"
