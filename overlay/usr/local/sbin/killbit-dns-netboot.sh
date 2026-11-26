#!/usr/bin/env bash
# Amorcage par le reseau (PXE/NFS) : donne a systemd-resolved le DNS recu en
# DHCP par l'initramfs.
#
# Pourquoi il faut le faire a la main. En netboot, c'est l'initramfs qui
# configure la carte (ipconfig, « ip=dhcp »), et live-boot ecrit ensuite
# « iface <carte> inet manual » dans /etc/network/interfaces pour que plus
# personne ne reconfigure la carte qui porte la racine NFS -- sinon le systeme
# perdrait son disque en pleine execution. Le greffon ifupdown de
# NetworkManager etant en « managed=false », NM laisse donc cette carte de
# cote : il ne transmet jamais a resolved le DNS recu en DHCP. resolv.conf
# pointe sur le stub de resolved, resolved n'a aucun serveur amont, et plus un
# seul nom ne se resout. killbit s'arrete alors sur « Impossible de contacter
# le serveur » -- sans rien effacer, et sans que rien n'indique que c'est le
# DNS qui manque.
#
# Mesure en labo (poste en netboot NFS derriere un dnsmasq qui fait DHCP
# complet, relais DNS et NAT) : sans ce service, « Link 2 (ens3) » n'a aucun
# serveur DNS, -DefaultRoute, aucune requete n'atteint le serveur et curl
# repond « Could not resolve host » ; avec, le nom se resout et HTTPS rend 200.
#
# Le DNS est pourtant la : l'initramfs l'a ecrit dans /run/net-<carte>.conf,
# que /run transporte tel quel jusqu'au systeme demarre. On ne touche NI la
# carte NI ses adresses NI ses routes -- rien qui puisse couper la racine
# NFS : on ne renseigne que le resolveur.
#
# Hors netboot il n'y a pas de /run/net-*.conf : le service ne fait rien et
# NetworkManager garde la main, comme avant.
set -uo pipefail

fichiers=(/run/net-*.conf)
[[ -e "${fichiers[0]}" ]] || { echo "pas de /run/net-*.conf : amorcage local, rien a faire"; exit 0; }

# resolved peut n'etre pas encore sur le bus quand ce service part : on attend,
# borne a 10 s, plutot que d'echouer sur une course au demarrage.
for _ in $(seq 1 20); do
  resolvectl status >/dev/null 2>&1 && break
  sleep 0.5
done

applique=0
for conf in "${fichiers[@]}"; do
  [[ -e "$conf" ]] || continue
  DEVICE='' IPV4DNS0='' IPV4DNS1='' DNSDOMAIN='' DOMAINSEARCH=''
  # shellcheck source=/dev/null
  . "$conf"
  [[ -n "$DEVICE" && -d "/sys/class/net/$DEVICE" ]] || continue

  # 0.0.0.0 est ce qu'ecrit ipconfig pour « pas de second serveur ».
  serveurs=()
  for s in $IPV4DNS0 $IPV4DNS1; do
    [[ -n "$s" && "$s" != 0.0.0.0 ]] && serveurs+=("$s")
  done
  [[ ${#serveurs[@]} -gt 0 ]] || continue

  # DOMAINSEARCH arrive avec un point final ; resolvectl l'accepte, mais le
  # journal est plus lisible sans.
  recherche="${DOMAINSEARCH:-$DNSDOMAIN}"
  recherche="${recherche%.}"

  resolvectl dns "$DEVICE" "${serveurs[@]}" || true
  # Sans route par defaut, resolved n'interroge ce serveur que pour les noms du
  # domaine de recherche : les autres restent sans reponse.
  resolvectl default-route "$DEVICE" yes || true
  [[ -n "$recherche" ]] && { resolvectl domain "$DEVICE" "$recherche" || true; }

  if resolvectl dns "$DEVICE" 2>/dev/null | grep -qF "${serveurs[0]}"; then
    echo "$DEVICE : DNS ${serveurs[*]}${recherche:+, recherche $recherche} transmis a resolved"
    applique=1
  else
    # resolved n'a pas pris : on court-circuite son stub et on ecrit un
    # resolv.conf ordinaire. L'image resout « hosts: files dns », donc la
    # libc lira ce fichier directement. Mieux vaut un resolveur sans resolved
    # qu'un poste qui refuse d'effacer faute de DNS.
    install -d -m 0755 /run/killbit-dns
    { [[ -n "$recherche" ]] && printf 'search %s\n' "$recherche"
      printf 'nameserver %s\n' "${serveurs[@]}"; } > /run/killbit-dns/resolv.conf
    ln -sfn /run/killbit-dns/resolv.conf /etc/resolv.conf
    echo "$DEVICE : resolved n'a pas pris le DNS, /etc/resolv.conf ecrit en direct" >&2
    applique=1
  fi
done

[[ "$applique" == 1 ]] || { echo "aucun DNS dans /run/net-*.conf : rien a transmettre" >&2; exit 0; }
