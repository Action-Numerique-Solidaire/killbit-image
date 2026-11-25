#!/usr/bin/env bash
# Front ncurses (dialog) de l'image « guidee ». L'operateur ne saisit qu'un
# identifiant de poste ; killbit est ensuite lance avec --yes, donc SANS aucune
# demande de confirmation de sa part, et ce front n'en ajoute aucune : un seul
# geste par poste, la saisie de l'identifiant.
#
# Reste un decompte : le recapitulatif (identifiant saisi, serveur, supports qui
# vont y passer) s'affiche DELAI_AVANT_EFFACEMENT secondes puis l'effacement
# part de lui-meme. Echap pendant ce decompte annule. Aucune touche n'est
# attendue : un poste demarre par megarde garde une sortie, le passage normal ne
# coute rien de plus.
#
# Avec --aide-seule, affiche l'ecran d'aide et rend la main (alias « aide »).
set -uo pipefail

RELEASE=/etc/killbit-image-release
LOGDIR=/var/log/killbit
BACKTITLE="killbit  --  Action Numerique Solidaire"
# Secondes d'affichage du recapitulatif avant le depart automatique. Mettre 0
# supprime le decompte : l'effacement part des la validation de l'identifiant.
DELAI_AVANT_EFFACEMENT=8
ACCUEIL_TEXTE=/usr/local/sbin/killbit-session.sh
# Rappel affiche dans la bordure basse de chaque boite de dialogue. Ctrl+Alt+F2
# bascule sur une console deja connectee en root : c'est la seule sortie qui
# fonctionne aussi pendant que killbit ecrit, puisqu'elle ne passe pas par
# dialog. « guide » y ramene ici.
RAPPEL_SORTIE="Ctrl+Alt+F2 : terminal (revenir : guide)"

report_url="https://actionnumeriquesolidaire.org"
if [[ -r "$RELEASE" ]]; then
  url_lue="$(awk -F= '$1=="report_url"{print $2; exit}' "$RELEASE")"
  [[ -n "$url_lue" ]] && report_url="$url_lue"
fi

# dialog dessine son interface sur la sortie STANDARD et renvoie la saisie sur
# la sortie d'ERREUR. Appele dans une substitution de commande, il dessinerait
# donc dans le tuyau de capture au lieu de l'ecran. Ce wrapper inverse les deux :
# interface sur le terminal, resultat sur la sortie standard, capturable.
# --hline ecrit dans la bordure basse de chaque boite : la sortie de secours
# est donc rappelee sur tous les ecrans, y compris pendant le decompte, et pas
# seulement dans l'aide que personne n'ouvre.
dlg() {
  dialog --backtitle "$BACKTITLE" --hline "$RAPPEL_SORTIE" "$@" \
    3>&1 1>/dev/tty 2>&3 3>&-
}

# -e 1,2,7,11 ecarte ram, disquette, loop et lecteur optique : sans ce filtre le
# squashfs de l'image live (loop0) et le media de demarrage (sr0) apparaissent
# dans la liste des supports a effacer, juste a cote des vrais disques.
disques() { lsblk -d -e 1,2,7,11 -o NAME,SIZE,ROTA,MODEL,SERIAL 2>/dev/null; }

reseau() {
  local ip
  ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2": "$4}' | paste -sd' ' -)"
  # killbit contacte son serveur avant d'ecrire, et s'arrete en code 1 s'il
  # ne l'atteint pas : sans reseau, rien n'est efface du tout.
  [[ -n "$ip" ]] || ip="AUCUNE adresse IP -- killbit refusera d'effacer"
  printf '%s' "$ip"
}

# La console physique fait 25 lignes, dont une prise par le backtitle : une
# boite plus haute que 24 ne tient pas a l'ecran. L'aide est donc serree, et
# le reste a l'ecrit (docs/UTILISATION.md).
aide() {
  dlg --title "Aide" --msgbox "\
Cette image efface les disques d'un poste et remonte un rapport.

Deroulement :
  1. saisir l'identifiant (etiquette QRcode, ex. R21062200075)
  2. relire le recapitulatif : identifiant, serveur, supports
  3. ne rien faire : l'effacement part seul apres $DELAI_AVANT_EFFACEMENT secondes
     et ne s'arrete plus. Echap pendant le decompte annule.

Un effacement est IRREVERSIBLE, y compris pour un laboratoire.

Sans adresse IP, rien ne sera efface : killbit contacte son
serveur avant d'ecrire. Brancher le cable, ou en Wi-Fi :
  nmcli dev wifi connect <SSID> password <mot_de_passe>

Terminal : Ctrl+Alt+F2, deja connecte en root, a tout moment,
meme pendant un effacement. Retour ici : Ctrl+Alt+F1, ou la
commande « guide ». Sinon Echap, ou « Shell » en fin de passage.

Serveur : $report_url
Journaux : $LOGDIR" 24 70
}

# Sorties de secours. Une image guidee qui demarre sur rien serait un poste
# inutilisable en atelier : dans les deux cas on retombe sur l'accueil en
# texte, qui ne depend ni de dialog ni d'un terminal de controle.
if [[ "${1:-}" != "--aide-seule" ]]; then
  if ! command -v dialog >/dev/null 2>&1; then
    echo "AVERTISSEMENT : dialog absent de l'image, bascule sur l'accueil texte." >&2
    exec "$ACCUEIL_TEXTE"
  fi
  if ! [[ -c /dev/tty ]]; then
    echo "AVERTISSEMENT : pas de terminal de controle, bascule sur l'accueil texte." >&2
    exec "$ACCUEIL_TEXTE"
  fi
fi

if [[ "${1:-}" == "--aide-seule" ]]; then
  command -v dialog >/dev/null 2>&1 || { "$ACCUEIL_TEXTE" --aide-seule; exit 0; }
  aide
  clear
  exit 0
fi

# Saisie de l'identifiant. Renseigne la variable globale ID ; renvoie 1 si
# l'operateur abandonne (Echap).
ID=""
demander_id() {
  local saisi rc
  while :; do
    saisi="$(dlg --title "Identifiant du poste" \
      --ok-label "Valider" --cancel-label "Aide" \
      --inputbox "\
Saisir l'identifiant du poste, puis valider.

Il figure sur l'etiquette QRcode, au format R21062200075.

Reseau  : $(reseau)
Serveur : $report_url" 14 72)"
    rc=$?
    case $rc in
      0) ;;
      1) aide; continue ;;            # bouton Aide
      *) return 1 ;;                  # Echap
    esac

    saisi="${saisi//[[:space:]]/}"
    if [[ -z "$saisi" ]]; then
      dlg --title "Identifiant vide" \
        --msgbox "Aucun identifiant saisi. killbit en exige un." 7 60
      continue
    fi

    # Format canonique : une lettre suivie de 11 chiffres. Un identifiant qui
    # s'en ecarte n'est pas refuse — killbit accepte aussi les identifiants
    # Killbit.fr — mais il est signale : une faute de frappe rattache le rapport
    # au mauvais poste, et cela ne se decouvre qu'apres l'effacement.
    if ! [[ "$saisi" =~ ^[A-Za-z][0-9]{11}$ ]]; then
      dlg --title "Format inhabituel" --defaultno \
        --yes-label "Utiliser quand meme" --no-label "Corriger" \
        --yesno "\
L'identifiant saisi :

    $saisi

ne ressemble pas au format attendu R21062200075 (une lettre
suivie de 11 chiffres).

L'utiliser quand meme ?" 14 68 || continue
    fi

    ID="$saisi"
    return 0
  done
}

effacer() {
  local id="$1" rc horodatage journal
  horodatage="$(date -u '+%Y%m%dT%H%M%SZ')"
  journal="$LOGDIR/$id-$horodatage.log"
  mkdir -p "$LOGDIR"

  # killbit ecrit en texte brut et affiche sa propre progression : on quitte
  # dialog avant de l'appeler plutot que de tenter de l'habiller.
  #
  # « script » (util-linux, deja dans l'image) lui donne un pseudo-terminal, de
  # sorte qu'il se comporte comme sur une console tout en etant journalise. Un
  # simple « | tee » lui presenterait un tuyau a la place d'un terminal.
  clear
  printf '== killbit -i %s -u %s --yes\n' "$id" "$report_url"
  printf '== journal : %s\n\n' "$journal"
  script -q -e -c "killbit -i '$id' -u '$report_url' --yes" "$journal"
  rc=$?
  printf '\n== killbit a rendu le code %s\n' "$rc"
  printf '== Appuyer sur Entree pour revenir au menu.\n'
  read -r _
  return "$rc"
}

while :; do
  demander_id || { clear; exec "$ACCUEIL_TEXTE"; }

  liste="$(disques)"
  if [[ "$(printf '%s\n' "$liste" | wc -l)" -le 1 ]]; then
    dlg --title "Aucun support detecte" --msgbox "\
Aucun disque n'est visible.

Le controleur est peut-etre en mode RAID dans le firmware
du poste : le basculer en AHCI, puis redemarrer." 11 70
    continue
  fi

  # --pause rend 0 quand le decompte arrive au bout, comme sur « Effacer
  # maintenant », et non nul sur Echap et « Annuler » : l'effacement part donc
  # sans intervention, et seul un geste explicite l'empeche.
  if [[ "$DELAI_AVANT_EFFACEMENT" -gt 0 ]]; then
    dlg --title "ATTENTION -- effacement irreversible" \
      --ok-label "Effacer maintenant" --cancel-label "Annuler" \
      --pause "\
Poste   : $ID
Serveur : $report_url
Reseau  : $(reseau)

Supports qui vont etre EFFACES :
$(printf '%s\n' "$liste" | sed 's/^/  /')

Cette operation est IRREVERSIBLE. Echap ou « Annuler » l'arrete
pendant le decompte ; ensuite plus rien ne l'interrompt." 24 74 \
      "$DELAI_AVANT_EFFACEMENT" || continue
  fi

  effacer "$ID" || true

  choix="$(dlg --title "Passage termine" \
    --ok-label "Choisir" --cancel-label "Shell" \
    --menu "Que faire maintenant ?" 13 62 4 \
      suivant "Traiter un autre poste" \
      aide    "Reafficher l'aide" \
      arret   "Eteindre le poste" \
      relance "Redemarrer le poste")" || { clear; exec bash -i; }
  case "$choix" in
    arret)   clear; systemctl poweroff ;;
    relance) clear; systemctl reboot ;;
    aide)    aide ;;
    *)       : ;;
  esac
done
