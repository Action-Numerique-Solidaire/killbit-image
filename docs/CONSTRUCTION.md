# Comment l'ISO est construite

Document destiné à qui doit modifier, déboguer ou reprendre la chaîne de
construction.

---

## 1. Vue d'ensemble

Tout tient dans un seul script, [`build-iso.sh`](../build-iso.sh), appelé soit
à la main, soit par GitHub Actions. Il n'utilise **pas** `live-build` : l'outil
a été écarté après une série de blocages sur les archives actuelles, au profit
d'un enchaînement direct et lisible.

```
killbit (binaire distant)
        │  telechargement + verification SHA-256
        ▼
debootstrap trixie  ──►  chroot minimal
        │
        │  apt : bibliotheques, outils disque, confort console
        │  overlay : accueil operateur, historique pre-rempli, reseau, marqueur
        │  grub-mkstandalone : chargeur UEFI (dans le chroot)
        │  purge des paquets de fabrication + doc/man/locales
        ▼
    mksquashfs  ──►  filesystem.squashfs
        │
        │  + noyau + initrd + isolinux + menu GRUB
        ▼
      xorriso  ──►  killbit-live.iso  (hybride BIOS + UEFI, dd-able)
```

---

## 2. Les étapes, dans l'ordre

| # | Étape | Pourquoi |
|---|---|---|
| 1 | Télécharger killbit et vérifier son empreinte | Inutile de construire 500 Mo si le binaire n'est pas celui attendu. L'échec est immédiat. |
| 2 | `debootstrap --variant=minbase trixie` | Base Debian minimale. Réutilisée si le chroot existe déjà, ce qui ramène un rebuild à environ 90 secondes. |
| 3 | `apt-get install --no-install-recommends` | Garde l'image légère. Impose en contrepartie de lister explicitement ce que les recommandations auraient apporté. |
| 4 | `update-initramfs` | `live-boot` doit être présent **avant** la génération, pour que ses hooks y entrent. On régénère quel que soit l'ordre choisi par apt. |
| 5 | Installer killbit et l'overlay | Le binaire va dans `/usr/local/bin`, l'empreinte dans `/etc/killbit-image-release`. |
| 6 | `grub-mkstandalone` **dans le chroot** | Produit `BOOTX64.EFI` puis une image FAT `efi.img`. Fait dans le chroot, l'hôte n'a donc besoin ni de `grub-efi-amd64-bin` ni de `mtools`. |
| 6bis | Extraire `isolinux.bin`, `isohdpfx.bin` et les `*.c32` | Les sortir du chroot **maintenant** est ce qui permet de purger juste après les paquets qui les fournissent. Lus plus tard, ils auraient imposé de garder 37 Mo d'outils de fabrication dans l'image livrée. |
| 6ter | Purge des paquets de fabrication, de la doc, des pages de manuel et des locales non françaises | Une image d'effacement hors ligne n'a pas besoin de `mtools` ni de pages de manuel. |
| 7 | `mksquashfs` | `zstd` niveau 22, **blocs de 1 Mo**. zstd décompresse plusieurs fois plus vite que `xz`, ce qui raccourcit autant le démarrage chez l'opérateur que les tests d'amorçage ; le noyau Debian 13 déclare `CONFIG_SQUASHFS_ZSTD=y`. Le bloc compte bien plus que le niveau : voir le tableau de mesures plus bas. |
| 8 | Menus isolinux et GRUB | Un menu par mode d'amorçage. |
| 9 | `xorriso` | Assemble l'ISO avec **deux entrées El Torito**. |

---

## 2bis. Ce que chaque phase coûte

Construction à froid, mesurée sur un portable avec KVM (`KILLBIT_ISO_WORK` vidé
au préalable) :

| Phase | Durée |
|---|---|
| Téléchargement et vérification de killbit | 2 s |
| `debootstrap` trixie | 35 s |
| `apt-get update` + `upgrade` | 4 s |
| `apt-get install` (50 paquets demandés, 225 installés) | 87 s |
| Paquets vides pour les dépendances de compilation | < 1 s |
| `update-initramfs` | 11 s |
| Purge des paquets de fabrication | 14 s |
| `mksquashfs` (zstd 22, blocs de 1 Mio) | 57 s |
| `xorriso` | 2 s |
| **Total** | **212 s** |

### Le réglage du squashfs, mesuré

Même chroot, même contenu, quatre réglages :

| Réglage | Taille | Durée |
|---|---|---|
| `zstd` 19, blocs de 128 Kio *(ancien)* | 295 067 648 o | 59 s |
| `zstd` 22, blocs de 128 Kio | 295 051 264 o | 74 s |
| **`zstd` 22, blocs de 1 Mio** *(retenu)* | **276 103 168 o** | 57 s |
| `xz`, blocs de 1 Mio | 261 079 040 o | 50 s |

Le **niveau** ne change rien : 16 Kio d'écart entre 19 et 22, pour 15 s de plus.
C'est la **taille de bloc** qui compte — 18 Mo repris, et un peu plus vite, parce
qu'il y a moins de blocs à compresser. `xz` reprendrait encore 14 Mo et se
construit même plus vite ici, mais il décompresse plusieurs fois plus lentement,
à chaque démarrage de chaque poste : le défaut reste `zstd`.

Deux phases dominent : l'installation des paquets et le squashfs. Elles sont
toutes deux proportionnelles à la taille de l'image, ce qui fait de la
minimisation le principal levier sur le temps de construction — l'installation
est passée de 150 s à 71 s en retirant X et firefox.

Réutiliser le chroot existant supprime `debootstrap` et l'essentiel de
l'installation : un rebuild tombe sous la minute et demie.

---

## 3. Décisions structurantes

### Base Debian 13, pas Ubuntu

Deux raisons, toutes deux vérifiées plutôt que supposées :

1. **killbit exige `GLIBC_2.38`.** Les symboles versionnés du binaire le disent
   (`readelf -V`). Debian 13 fournit 2.41. Une base Ubuntu 22.04, en 2.35, ne
   le lancerait pas du tout.
2. Debian permet de **choisir les micrologiciels un par un**, au lieu d'un
   méta-paquet qui tire tout. C'est ce qui rend possible d'embarquer le réseau
   filaire et d'écarter le reste.

Accessoirement, si le mode navigateur est réactivé : sur **Ubuntu 24.04,
`firefox` et `chromium` ne sont que des paquets de transition vers des snaps**,
inutilisables dans un debootstrap sans snapd. Debian fournit de vrais `.deb`.

L'image embarque les micrologiciels du réseau filaire et **évite les blobs
GPU** : chez Ubuntu, `linux-firmware` tire 109 Mo de nvidia et 60 Mo de
qualcomm pour un outil sans interface 3D.

### Console seule, et ce que ça a fait gagner

L'image a d'abord embarqué X, `openbox`, `xterm` et `firefox-esr`, pour pouvoir
afficher plus tard la page d'état locale de killbit. Cette page n'existe pas, et
la mesure est sans appel — tailles installées dans une base trixie, obtenues en
simulant l'installation :

| Jeu de paquets | Paquets | Installé |
|---|---|---|
| Tout (X + openbox + xterm + firefox) | 307 | **1101 Mo** |
| sans firefox | 280 | 775 Mo |
| **sans firefox ni X** | **107** | **374 Mo** |

Les deux tiers du poids servaient une fonction qui n'avait rien à afficher.
L'image est donc console seule, et `KILLBIT_WITH_BROWSER=1` réembarque X et
firefox — **sans gestionnaire de fenêtres** — le jour où cette page existera.

### Le Wi-Fi : écarté, puis réintégré sur constat d'erreur

Le Wi-Fi a d'abord été retiré par raisonnement : l'image ne sait pas saisir un
SSID, sa configuration réseau ne couvrait que `en*` et `eth*`, donc le
micrologiciel ne pouvait servir à rien. Les 111 Mo installés de
`firmware-iwlwifi` ont été écartés sur cette base.

Le raisonnement ignorait ce que fait killbit. Les chaînes du binaire le disent,
dans `run_laptop_and_wifi_check` :

```
upower -e | grep battery            # pas de batterie -> "PC fixe, test wifi non realise"
nmcli dev wifi list 2>/dev/null     # sinon
"Le wifi de cette machine fonctionne."
"Le wifi de cette machine n'est pas operationnel."
```

Le résultat part au serveur sous `"Type":"Wifi"`. **Le Wi-Fi n'est donc pas un
moyen de connexion pour l'image, c'est une mesure matérielle du poste traité.**
Sans micrologiciel ni `wpasupplicant`, la carte ne s'initialise pas, `nmcli` ne
renvoie rien, et chaque portable passé en atelier est enregistré comme ayant un
Wi-Fi en panne. Le défaut a été constaté en atelier, pas déduit.

Les micrologiciels Wi-Fi sont donc embarqués, avec `wpasupplicant` — sans lui
NetworkManager ne pilote aucune carte — et `wireless-regdb`, sans quoi le
balayage est restreint ou refusé.

| Paquet | `.deb` | Installé | Couvre |
|---|---|---|---|
| `firmware-iwlwifi` | 15,9 Mo | 111 Mo | Intel, majoritaire sur le parc professionnel |
| `firmware-atheros` | 28,1 Mo | 95 Mo | ath10k, ath11k, ath12k (ath9k est dans le noyau) |
| `firmware-brcm80211` | 5,1 Mo | 18 Mo | Broadcom : Mac et grand public |
| `firmware-libertas` | 3,5 Mo | 11 Mo | Marvell |
| `wpasupplicant` + dépendances | 1,7 Mo | 4,6 Mo | pilotage des cartes par NetworkManager |
| `wireless-regdb` | 0,01 Mo | 0,04 Mo | base réglementaire |

`firmware-ti-connectivity` est écarté : wl12xx équipe des cartes embarquées, pas
les portables d'un parc de réemploi.

**Le coût réel est mesuré, pas calculé** : l'ISO passe de 233 à 338 Mo, soit
**+105 Mo**. La somme des `.deb` (54 Mo) aurait fait espérer moitié moins, mais
squashfs en zstd par blocs de 128 Kio ne retrouve pas la compression d'un `.deb`
en xz à dictionnaire large. Les 267 Mo de `/usr/lib/firmware` installés se
répartissent ainsi : `iwlwifi` 96 Mo, `ath11k` 63 Mo, `ath10k` 19 Mo,
`rtw89` 15 Mo, `brcm` 12 Mo, `mrvl` 9,3 Mo.

`KILLBIT_WITH_WIFI=0` reconstruit l'image sans rien de tout cela, en sachant que
tous les rapports porteront alors « wifi non opérationnel ».

### Les prérequis sont déduits du binaire

Rien n'a été deviné :

```bash
readelf -d killbit   # libcurl.so.4, libsodium.so.23, libstdc++.so.6, libgcc_s.so.1
readelf -V killbit   # GLIBC_2.38 au plus haut
strings  killbit     # hdparm, nvme, smartctl, blkdiscard, lsblk, udevadm
```

Les endpoints HTTPS trouvés dans les chaînes imposent le réseau et
`ca-certificates`. Le binaire n'a **jamais été exécuté** pour cette analyse.

### Pièges déjà rencontrés, et leur correctif

| Piège | Symptôme | Correctif dans le script |
|---|---|---|
| `systemd-sysv` absent | **Kernel panic : « Attempted to kill init »**. `minbase` + `--no-install-recommends` ne fournissent pas `/sbin/init`. | Paquet listé explicitement |
| Pilotes d'entrée X | Clavier et souris inertes sous X | `xserver-xorg-input-libinput` listé explicitement — ne concerne plus que `KILLBIT_WITH_BROWSER=1` |
| `xauth` absent | `startx` échoue | Idem, mode navigateur seulement |
| Disposition clavier US | Saisir `https://` et un identifiant au clavier AZERTY devient une épreuve | `/etc/default/keyboard` écrit par le script, `KILLBIT_KEYMAP` (défaut `fr`) |
| `/etc/resolv.conf` supprimé | Plus aucune résolution DNS, donc aucune remontée de rapport | Remplacé par un lien vers `stub-resolv.conf` |
| `/etc/netplan` vide, réseau non configuré | L'image démarre sans adresse IP | Fichier `systemd-networkd` dans l'overlay |
| `cp -a` de l'overlay | Fichiers exécutés en root appartenant à l'UID 1000 | Boucle `chown root:root` |
| `/etc/network` inexistant | `live-boot` affiche une erreur inquiétante au démarrage | Dossier vide dans l'overlay |
| Trousseau Debian absent sur hôte Ubuntu | debootstrap échoue sur une erreur GPG peu claire | Détection précoce, message avec la commande qui corrige |
| `set prefix` vers l'ISO dans le GRUB embarqué | **GRUB tombe sur son invite** : `configfile.mod not found`. L'ISO ne démarre pas en UEFI. | `search` seul ; `grub-mkstandalone` garde ses modules dans son memdisk |

---

## 4. L'overlay

Tout ce qui est propre à l'image vit dans `overlay/`, recopié tel quel à la
racine du chroot.

| Chemin | Rôle |
|---|---|
| `root/.bash_profile` | Charge d'abord `.bashrc` — bash ne le lit pas de lui-même pour un shell de connexion, et sans cela les consoles de secours n'auraient ni l'invite, ni `aide`, ni `guide`. Puis, sur `tty1` **uniquement**, enchaîne sur le front : `killbit-guide.sh` s'il est présent, sinon `startx` en mode navigateur, sinon l'accueil en texte. Le choix se fait sur la **présence des fichiers**, pas sur un drapeau de construction. Les autres consoles s'arrêtent avant et rendent un shell : c'est la sortie de secours. |
| `root/.bashrc` | Invite (`killbit` en rouge vif, ce que le test du front cherche à l'écran), réglages d'historique, alias `aide` et `guide`. |
| `root/.bash_history` | **Généré par le script**, pas présent dans l'overlay : il dérive de `KILLBIT_REPORT_URL`, pour que l'écran d'accueil et l'historique ne puissent pas diverger. Dernière ligne = première flèche vers le haut. |
| `root/.xinitrc` | Mode navigateur uniquement, et **sans gestionnaire de fenêtres**. Retiré de l'image en mode console, pour que le chemin de démarrage reste sans ambiguïté. |
| `usr/local/sbin/killbit-session.sh` | Écran d'accueil en texte : identité de l'image, réseau, supports, commande à lancer. Puis un shell interactif. `--aide-seule` pour le réafficher. |
| `usr/local/sbin/killbit-guide.sh` | Front ncurses (`dialog`) : saisie de l'identifiant, récapitulatif en décompte, `killbit --yes`, journal dans `/var/log/killbit/`. Rappelle `Ctrl+Alt+F2` dans la bordure basse de chaque boîte. |
| `etc/systemd/system/killbit-ready.service` | Émet `KILLBIT-IMAGE-READY` sur la console série. C'est ce que le test d'amorçage attend. |
| `usr/local/sbin/killbit-dns-netboot.sh` | Donne à `systemd-resolved` le DNS reçu en DHCP par l'initramfs quand le poste a démarré par le réseau. Sans lui, un poste en PXE/NFS ne résout plus aucun nom. |
| `etc/systemd/system/killbit-dns-netboot.service` | Lance le précédent, conditionné à la présence de `/run/net-*.conf`, avant le marqueur de disponibilité et avant les consoles. |
| `etc/network/` | Dossier vide, voir le tableau des pièges. |

Le fichier `systemd-networkd` qui portait le DHCP a été retiré : killbit appelle
`nmcli dev wifi list`, NetworkManager doit donc tourner, et deux gestionnaires
réseau sur les mêmes interfaces se gênent. NetworkManager gère les interfaces,
`systemd-resolved` le DNS.

### Le DNS d'un poste démarré par le réseau

Cette combinaison a un angle mort, et il ne se voit que par PXE. Constaté sur
matériel réel derrière un serveur BITS en mode passerelle : le live démarre,
monte sa racine NFS, obtient son adresse et sa route — et ne résout plus un
seul nom. `killbit` s'arrête sur « Impossible de contacter le serveur », sans
rien effacer, sans rien qui désigne le DNS.

La chaîne, dans l'ordre :

1. en netboot, c'est **l'initramfs** qui configure la carte (`ipconfig`,
   `ip=dhcp`) — il écrit tout ce qu'il a reçu dans `/run/net-<carte>.conf`,
   fichier que `/run` transporte tel quel jusqu'au système démarré ;
2. `live-boot` écrit ensuite `iface <carte> inet manual` dans
   `/etc/network/interfaces` (`9990-netbase.sh`), **volontairement** : si
   quelqu'un reconfigurait cette carte, le système perdrait la racine NFS qu'il
   est en train d'exécuter ;
3. le greffon `ifupdown` de NetworkManager est en `managed=false` : toute carte
   nommée dans `/etc/network/interfaces` est donc laissée de côté
   (`nmcli dev` → `unmanaged`) ;
4. NetworkManager étant la seule source de DNS de l'image, `resolved` n'a
   **aucun serveur amont**, et `/etc/resolv.conf` pointe sur son stub en
   `127.0.0.53` : la libc interroge donc un résolveur qui n'a personne à qui
   demander.

Rien de tout cela n'est un défaut de l'image prise séparément : chaque maillon
fait ce qu'il doit. `killbit-dns-netboot.service` relit `/run/net-*.conf` et
transmet le DNS à `resolved` (`resolvectl dns`, `default-route`, `domain`).
**Il ne touche ni la carte, ni ses adresses, ni ses routes** — rien qui puisse
couper la racine NFS. Hors netboot, il n'y a pas de `/run/net-*.conf` et le
service ne fait rien.

Mesuré en labo, poste en netboot NFS derrière un `dnsmasq` qui fait DHCP
complet et relais DNS :

| | Sans le service | Avec |
|---|---|---|
| `nmcli dev` | `ens3 unmanaged` | `ens3 unmanaged` (inchangé, et c'est voulu) |
| `resolvectl status` | aucun serveur, `-DefaultRoute` | `DNS Servers: 192.168.80.1`, `+DefaultRoute` |
| `getent hosts` | rien | l'adresse |
| `curl https://…` | « Could not resolve host » | `200` |
| Requête vue par le serveur | **aucune** | `query[A] … from 192.168.80.157` |

`tests/netboot-dns-test.sh <image.iso>` refait ce labo et rend un verdict. Il
demande `sudo`, `nfs-kernel-server`, `dnsmasq-base` et `qemu-system-x86` : il
monte l'ISO, en sort noyau, initrd et squashfs, les sert en NFS, crée un pont
avec un `dnsmasq` **hors ligne** (il résout lui-même un nom fabriqué), et
démarre le poste avec la ligne de commande du menu iPXE. Le poste pose son
propre diagnostic : `live-config.hooks=file://…` lui fait exécuter un script
déposé sur le média, qui écrit ses mesures sur le port série — l'image sous
test n'est pas modifiée, et le verdict porte sur du texte, pas sur une image
d'écran. Le test échoue bien sur une image sans le service.

Ce test ne tourne pas en CI : un serveur NFS et un pont sur le runner pour un
défaut qui se contrôle autrement. La CI vérifie que le script est présent et
exécutable, que l'unité est activée, et qu'elle est **toujours conditionnée** à
`/run/net-*.conf` — sans quoi elle irait réécrire le DNS d'un poste démarré sur
clé, où NetworkManager fait déjà le travail.

### Un seul front, et ce qu'il promet

Il y a eu deux images jusqu'à la `v0.2.0`, choisies par `KILLBIT_FRONT` : une
guidée, une qui rendait simplement un shell. Elles ne différaient que par un
paquet, `dialog`, et par la présence de `killbit-guide.sh`. Cela faisait deux
ISO à télécharger, deux constructions à tester et une question de plus à
l'atelier, pour un seul comportement réellement différent — et ce comportement
est maintenant **dans** l'image unique, à `Ctrl+Alt+F2`.

| | Front (`tty1`) | Consoles de secours (`tty2`, `tty3`) |
|---|---|---|
| Au démarrage | front ncurses plein écran | shell root, déjà connecté |
| Saisie | l'identifiant du poste, et rien d'autre | l'opérateur tape la commande, pré-remplie dans l'historique |
| Appel de killbit | **avec `--yes`** : killbit ne demande plus rien | sans `--yes` : killbit garde toutes ses confirmations |
| Confirmations avant écriture | **aucune** : un décompte de 8 s, annulable par `Echap` | celles de killbit |

`--yes` est le but du front : enchaîner les postes sans répondre à des
questions. Le front n'en rajoute donc aucune. La saisie de l'identifiant est
le dernier geste de l'opérateur ; le récapitulatif qui suit — identifiant saisi,
serveur, et **liste des disques qui vont être effacés**, avec leur taille, modèle
et numéro de série — est un `dialog --pause` de `DELAI_AVANT_EFFACEMENT`
secondes (8), pas une question.

`--pause` rend **0 quand le décompte arrive au bout**, comme sur `OK`, et un
code non nul sur `Echap` et `Annuler` : l'effacement part donc sans
intervention, et seul un geste explicite l'empêche. Vérifié, pas supposé :
expiration → 0, `Echap` au bout de 2 s sur un décompte de 25 → 255 immédiat.
Mettre `DELAI_AVANT_EFFACEMENT=0` supprime même le décompte.

Ce décompte est le dernier garde-fou de cette image, et il est volontairement
court : il laisse relire la liste des disques d'un poste démarré par mégarde
sans coûter un geste par poste à l'atelier.

Le front se retire de son propre chemin dans deux cas : `dialog` absent de
l'image, ou pas de terminal de contrôle. Il bascule alors sur l'accueil en
texte, parce qu'un poste d'atelier qui démarre sur un écran noir serait pire
qu'un poste sans front.

### Les sorties de secours

Depuis qu'il n'y a plus qu'une image, le shell doit être atteignable **depuis**
le front. Trois chemins, dont un seul est inconditionnel :

| Chemin | Disponible quand | Mécanisme |
|---|---|---|
| `Ctrl+Alt+F2`, `Ctrl+Alt+F3` | **toujours**, y compris pendant que killbit écrit | `getty@tty2` et `getty@tty3` activées, avec `agetty --autologin root` |
| `Echap` sur l'écran de saisie | le front a la main | `demander_id` rend 1, le front `exec` l'accueil en texte |
| `Shell` en fin de passage | le front a la main | bouton `--cancel-label` du menu |

L'autologin n'est pas un confort : le compte root de l'image **n'a pas de mot
de passe**, donc une console avec invite de connexion serait infranchissable.
C'est aussi pourquoi `tty4` à `tty6`, que logind ouvre sans ce réglage, ne
servent à rien.

Le front rappelle `Ctrl+Alt+F2` dans la **bordure basse de chaque boîte**
(`--hline`), décompte compris : une sortie que personne ne connaît n'est pas
une sortie.

`Ctrl+Alt+F1` ramène au front, dans l'état où il était — le noyau conserve
l'écran de chaque console, rien n'est redessiné. La commande `guide` y ramène
aussi, et c'est la dernière ligne de l'historique, donc la première flèche vers
le haut.

---

## 5. Construire localement

```bash
sudo ./build-iso.sh /chemin/killbit-live.iso
```

Hôte requis : `debootstrap`, `debian-archive-keyring`, `squashfs-tools`,
`xorriso`. Rien de plus : les chargeurs BIOS **et** UEFI sont construits dans le
chroot et leurs artefacts en sont extraits.

| Variable | Défaut | Rôle |
|---|---|---|
| `KILLBIT_URL` | dépôt ANS-public | Binaire à embarquer |
| `KILLBIT_SHA256` | vide | Empreinte attendue ; échec si différente |
| `KILLBIT_REPORT_URL` | `https://actionnumeriquesolidaire.org` | Adresse de remontée, pré-remplie dans l'historique du shell et affichée à l'accueil |
| `KILLBIT_KEYMAP` | `fr` | Disposition clavier de la console |
| `KILLBIT_STUB_BUILD_DEPS` | `1` | `0` réembarque la vraie chaîne de compilation que killbit réclame, à la place des quatre paquets vides : +88 Mo d'ISO |
| `KILLBIT_WITH_WIFI` | `1` | `0` retire micrologiciels Wi-Fi et `wpasupplicant` ; tous les rapports porteront alors « wifi non opérationnel » |
| `KILLBIT_WITH_BROWSER` | `0` | `1` réembarque X et firefox, sans gestionnaire de fenêtres |
| `KILLBIT_SQUASHFS_COMP` | `zstd` | Compression du squashfs (`xz` pour une vingtaine de Mo de moins, au prix du temps de construction et de décompression) |
| `KILLBIT_SQUASHFS_LEVEL` | `22` | Niveau de compression. Sans effet mesurable ici, voir le tableau |
| `KILLBIT_SQUASHFS_BLOCK` | `1M` | Taille de bloc. C'est **elle** qui compte |
| `KILLBIT_ISO_WORK` | `/srv/killbit-iso-build` | Répertoire de travail |
| `KILLBIT_DISTRO` | `trixie` | Suite Debian |

Supprimer le répertoire de travail force un debootstrap complet ; le conserver
rend les rebuilds très rapides.

---

## 6. Tester

```bash
tests/boot-test.sh killbit-live.iso bios
tests/boot-test.sh killbit-live.iso uefi
```

Le script démarre l'ISO dans QEMU et attend le marqueur `KILLBIT-IMAGE-READY`.
Il surveille aussi les motifs d'échec (`Kernel panic`, `emergency mode`…) pour
échouer tout de suite plutôt qu'au bout du délai. Il utilise KVM si disponible,
sinon l'émulation — environ deux minutes et demie dans ce cas.

### Le front guidé

```bash
tests/front-test.sh killbit-live.iso captures/
```

Un contrôle de contenu voit les fichiers, pas l'écran : un `.bash_profile` qui
n'enchaîne pas ou un `dialog` qui n'ouvre rien laisserait l'opérateur devant une
console noire sur un poste prêt à être effacé. Ce test regarde donc l'écran, et
le verdict est automatique **sans OCR** :

1. il attend le marqueur, puis **que l'écran devienne bleu** — `dialog` peint le
   fond sur toute la surface, ce qu'une console en texte ne fait jamais. Le
   seuil est de 40 % de pixels bleus ; l'écran de saisie en fait 78 % ;
2. il tape `R21062200075` au clavier du poste, via le moniteur QEMU. Les
   chiffres passent par `shift-<chiffre>` : la console est en AZERTY, où
   `sendkey 2` produit « é » — ce qui a au passage confirmé que la disposition
   `fr` est bien active ;
3. il valide et vérifie que **l'écran a changé**, ce qui distingue un front
   vivant d'une image figée ;
4. entre les deux, il éprouve la **sortie de secours** : `Ctrl+Alt+F2` envoyé
   au clavier du poste doit faire disparaître le bleu, et l'invite de l'image
   doit être là. Elle écrit `killbit` en **rouge vif** — une cinquantaine de
   pixels suffisent à la reconnaître, et rien d'autre dans cette image n'écrit
   en rouge sur une console en texte. Un simple écran noir ne prouverait rien,
   une invite de connexion non plus : c'est le rouge qui prouve que l'autologin
   a abouti **et** que `.bashrc` a été lu. Puis `Ctrl+Alt+F1` doit ramener le
   front, inchangé ;
5. puis il ne frappe plus rien, et vérifie que **le bleu quitte l'écran de
   lui-même** : c'est le décompte qui arrive au bout et killbit qui prend la
   console. Un écran resté bleu signifierait que quelque chose attend encore un
   opérateur — exactement ce que cette image ne doit plus faire. La machine
   virtuelle est coupée dès que l'écran a changé.

Ce dernier point laisse killbit démarrer pour de bon, le temps d'une seconde.
Deux précautions, parce qu'un test ne doit rien casser hors de lui : le seul
support branché est un fichier creux dans un dossier temporaire, effacé à la
sortie ; et le réseau de la machine virtuelle est en `restrict=on`, donc elle
obtient bien une adresse du DHCP interne de QEMU mais ne joint ni l'hôte ni
l'extérieur — **aucun rapport de poste fictif ne peut atteindre le serveur de
l'association**.

Cette isolation suffit d'ailleurs à garantir qu'aucun octet n'est écrit :
killbit contacte son serveur **avant** d'écrire et s'arrête en code 1 s'il ne
l'atteint pas. C'est aussi pourquoi l'image dit maintenant « killbit REFUSERA
d'effacer » quand il n'y a pas d'adresse IP, au lieu d'annoncer seulement un
rapport perdu : sans réseau, un poste passé en atelier repart intact.

Les captures sont déposées en PNG dans le dossier indiqué, y compris quand le
test échoue — c'est là qu'on veut voir l'écran.

Ce test existe parce que **la vérification de contenu ne suffit pas** : une ISO
a déjà contenu tous les bons fichiers tout en paniquant au démarrage.

---

## 7. L'intégration continue

[`.github/workflows/build-iso.yml`](../.github/workflows/build-iso.yml),
sur `ubuntu-24.04`.

1. `shellcheck` sur tous les scripts du dépôt. Il est **préinstallé** sur
   l'image des runners : l'installer coûtait un `apt-get update` pour rien.
   Attention, il est appelé sans seuil de sévérité, donc une remontée `info`
   suffit à faire échouer le job — c'est voulu, mais ça surprend.
2. **Choix du disque de travail** : `/mnt`, le disque temporaire du runner, est
   bien plus grand que la racine. L'y mettre a remplacé l'étape qui supprimait
   dotnet, android et ghc pour faire de la place — elle coûtait **90 secondes**,
   soit 18 % du job, pour un besoin qui n'existe plus depuis que l'image est
   légère. Repli automatique sur `RUNNER_TEMP` si `/mnt` manque de place.
3. Construction.
4. **Contrôle El Torito** : une entrée BIOS *et* une entrée UEFI. Une ISO BIOS
   seul ne démarre pas sur du matériel post-2012 à CSM désactivé, et le défaut
   est invisible à l'œil nu.
5. **Contrôle de l'empreinte publiée** : format au nom nu, puis un
   `sha256sum -c` réel. Le `.sha256` a un temps porté le chemin du runner, ce
   qui rendait invérifiable la commande que la documentation donne pourtant.
6. **Contrôle du contenu**, en trois volets.
   Ce qui doit être là : killbit, ses outils, les trois bibliothèques, le front
   de l'opérateur, l'historique pré-rempli — la commande d'effacement y est
   cherchée littéralement — et de quoi faire aboutir le test Wi-Fi de killbit
   (`wpa_supplicant`, `regulatory.db`, micrologiciels `iwlwifi`).
   Ce qui doit avoir **disparu** : X, openbox, xterm, firefox, les outils de
   fabrication. Sans ce volet, la minimisation se déferait au premier ajout de
   paquet distrait, et personne ne le verrait.
   Et les **sorties de secours** : `getty@tty2` et `getty@tty3` activées,
   `--autologin root` dans leur réglage, et le rappel `Ctrl+Alt+F2` présent dans
   le front. Une console de secours qui demanderait un mot de passe serait
   infranchissable, et une sortie que le front n'affiche pas n'existe pas pour
   l'opérateur.
   Au même endroit, le verrou sur la chaîne de compilation : `g++`, `cc` et
   `make` doivent être **absents** du système de fichiers alors que le critère
   de killbit passe sur les seize paquets. S'ils réapparaissent, c'est qu'un
   paquet vide a été remplacé par le vrai et que l'ISO a repris 88 Mo.
7. **Tests d'amorçage réels**, BIOS et UEFI menés **en parallèle**. Le runner
   n'a pas KVM, les deux amorçages tournent donc en émulation : les enchaîner
   coûtait le double pour rien, les deux processus QEMU ne se gênant qu'à la
   marge sur quatre vCPU.
8. **Test du front ncurses**, sortie de secours comprise (voir § 6).
10. Publication, dans un **job distinct** : une seule release porte les deux
    images, elle attend donc les deux constructions. Prerelease glissante
    `latest` à chaque push sur `main`, release versionnée sur tag `v*`.

---

## 8. Limites connues

- **Secure Boot** : le chargeur n'est pas signé, il faut le désactiver dans le
  firmware. `shim-signed` + `grub-efi-amd64-signed` lèveraient la limite, au
  prix d'une chaîne de signature à mettre en place.
- L'URL par défaut pointe sur `refs/heads/main` : le binaire peut changer sans
  préavis. `KILLBIT_SHA256` fige une version, et l'empreinte réellement
  embarquée est toujours lisible dans `/etc/killbit-image-release`.
- L'image démarre en root avec connexion automatique, sans mot de passe. C'est
  volontaire — un outil d'atelier doit être immédiatement utilisable — mais
  cela suppose un contrôle physique de la machine.
- **L'image lance `killbit --yes` sans confirmation.** Elle ne pose
  qu'une question, l'identifiant du poste ; le décompte de 8 secondes est tout
  ce qui sépare la saisie de l'écriture. C'est son intérêt en atelier et son
  risque : un identifiant saisi sur le mauvais poste efface le mauvais poste.
  Pour un passage avec les confirmations de killbit, `Ctrl+Alt+F2` puis la
  commande de l'historique, qui ne porte pas `--yes`.
- **Les quatre dépendances de compilation sont des paquets vides.** Le critère
  de killbit est satisfait, sa fonction ne l'est pas : rien dans l'image ne
  compile. Sans conséquence aujourd'hui — il n'appelle aucun compilateur,
  vérifié dans ses chaînes — mais une version de killbit qui compilerait
  échouerait là sans qu'aucun message d'absence de paquet n'apparaisse.
  `KILLBIT_STUB_BUILD_DEPS=0` reconstruit avec la vraie chaîne, pour 88 Mo.
- Le test Wi-Fi de killbit dépend du micrologiciel de la carte. Les familles
  Intel, Atheros, Broadcom, Marvell et Realtek sont embarquées ;
  `firmware-ti-connectivity` ne l'est pas. Une carte hors de ces familles sera
  rapportée comme non opérationnelle.
