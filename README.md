# killbit-image

Construit une **ISO live amorçable** embarquant l'exécutable
[`killbit`](https://github.com/r3dge/ANS-public/raw/refs/heads/main/bin/killbit),
tous ses prérequis d'exécution et rien d'autre, pour l'écrire sur une clé USB et
effacer de façon sécurisée les supports des PC reconditionnés d'Action Numérique
Solidaire.

L'image est **console seule** : ni serveur graphique, ni gestionnaire de
fenêtres.

**Une seule image est publiée** : `killbit-live.iso`. Au démarrage, un front en
texte plein écran ne demande que l'identifiant du poste, puis lance killbit avec
`--yes`, sans attendre de confirmation.

Il y a eu deux images jusqu'à la `v0.2.0`, l'une guidée et l'autre rendant
simplement un shell. Elles ne différaient que par ce qui s'exécutait sur `tty1`,
pour deux ISO à télécharger et une question de plus à l'atelier. Le shell n'a
pas disparu : il est **dans** cette image, à `Ctrl+Alt+F2`.

## Documentation

| Document | Pour qui |
|---|---|
| [docs/UTILISATION.md](docs/UTILISATION.md) | Les bénévoles : graver la clé, démarrer, lancer un effacement, dépanner |
| [docs/CONSTRUCTION.md](docs/CONSTRUCTION.md) | Qui modifie la chaîne : étapes du build, décisions, pièges, CI |

## Récupérer l'ISO

Chaque construction est **publiée en release** :

- **[`latest`](../../releases/tag/latest)** — prerelease reconstruite à chaque
  push sur `main` ;
- une release versionnée pour chaque tag `v*`.

```bash
sudo dd if=killbit-live.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Vérifier l'empreinte avant de graver, depuis le dossier de téléchargement :

```bash
sha256sum -c killbit-live.iso.sha256
```

## Au démarrage

Le poste démarre directement sur un front en texte plein écran. L'opérateur
saisit l'identifiant qui figure sur l'étiquette QRcode, et c'est **le seul geste
demandé** : le front affiche alors un récapitulatif — identifiant, serveur de
remontée, adresse réseau, et **la liste des disques qui vont être effacés** —
pendant **8 secondes**, décompte à l'écran, puis l'effacement part de lui-même.

Aucune confirmation n'est attendue : killbit est appelé avec `--yes` et ne
demande plus rien, méthode d'effacement comprise (*Purge* par défaut). `Echap`
pendant le décompte annule ; `Entrée` le raccourcit. La sortie de killbit est
journalisée dans `/var/log/killbit/`.

Si aucun disque n'est visible, le front le dit et ne propose pas d'effacer.
Le menu de fin enchaîne sur le poste suivant, un shell, l'extinction ou le
redémarrage.

## Reprendre la main en ligne de commande

**`Ctrl+Alt+F2`** bascule sur une console déjà connectée en root. Elle est
démarrée dès l'amorçage et fonctionne **à tout moment**, y compris pendant que
killbit écrit sur les disques : elle ne passe pas par `dialog`, donc rien de ce
que fait le front ne peut la bloquer. `Ctrl+Alt+F3` en donne une seconde.
`Ctrl+Alt+F1` ramène au front, intact — le noyau conserve le contenu de chaque
console.

Ce rappel est écrit dans la bordure basse de **chaque** boîte du front, y
compris pendant le décompte : une sortie que personne ne connaît n'est pas une
sortie.

Deux autres chemins, qui supposent que le front a la main : `Echap` sur l'écran
de saisie, et « Shell » dans le menu de fin de passage. La commande `guide`
ramène au front depuis n'importe quelle console.

La console rend un shell root. La commande `aide` y affiche l'écran d'accueil —
identité de l'image, état réseau, supports détectés, commande à lancer —
recalculé au moment où on le demande :

```
killbit -i <id_du_poste> -u https://actionnumeriquesolidaire.org
```

**Cette commande est pré-chargée dans l'historique du shell**, à **deux**
flèches vers le haut : la première ramène `guide`, le retour au front, qui est
le geste le plus courant. Il ne reste qu'à remplacer `<id_du_poste>` ; l'adresse
de remontée n'a jamais à être retapée, c'était la principale source d'erreur de
saisie. `killbit --check` et `killbit --help` sont également dans l'historique.

Si l'opérateur valide sans remplacer `<id_du_poste>`, le shell refuse la ligne
et rien ne s'exécute : les chevrons sont des caractères spéciaux. C'est un
garde-fou volontaire.

**Lancé ainsi, à la main, killbit conserve ses propres confirmations** :
l'historique ne contient pas `--yes`, c'est l'opérateur qui répond. Le `--yes`
est au front, pas dans l'image.

Le clavier est en disposition française par défaut (`KILLBIT_KEYMAP`), parce que
saisir une URL sur un clavier AZERTY mal configuré est une épreuve.

## Construire localement

```bash
sudo ./build-iso.sh /chemin/killbit-live.iso
```

| Variable | Rôle |
|---|---|
| `KILLBIT_URL` | URL du binaire à embarquer |
| `KILLBIT_SHA256` | Empreinte attendue ; la construction échoue si elle diffère |
| `KILLBIT_REPORT_URL` | Adresse de remontée pré-remplie dans l'historique et l'écran d'accueil |
| `KILLBIT_KEYMAP` | Disposition clavier de la console (défaut `fr`) |
| `KILLBIT_STUB_BUILD_DEPS` | `0` réembarque la vraie chaîne de compilation que killbit réclame, au lieu des paquets vides (voir plus bas) |
| `KILLBIT_WITH_WIFI` | `0` retire micrologiciels Wi-Fi et `wpasupplicant` ; tous les rapports porteront alors « wifi non opérationnel » |
| `KILLBIT_WITH_BROWSER` | `1` réembarque X et firefox, **sans** gestionnaire de fenêtres |
| `KILLBIT_SQUASHFS_COMP` / `_LEVEL` / `_BLOCK` | Compression du squashfs (défaut `zstd`, niveau 22, blocs de 1 Mo) |
| `KILLBIT_ISO_WORK` | Répertoire de travail (défaut `/srv/killbit-iso-build`) |
| `KILLBIT_DISTRO` | Suite Debian (défaut `trixie`) |

Dépendances de l'hôte : `debootstrap`, `debian-archive-keyring`,
`squashfs-tools`, `xorriso`. Les chargeurs BIOS **et** UEFI sont construits dans
le chroot et leurs artefacts en sont extraits, donc l'hôte n'a besoin ni
d'`isolinux`, ni de `grub-efi-amd64-bin`, ni de `mtools`.

Sur un hôte Ubuntu, `debian-archive-keyring` est indispensable : sans lui
debootstrap refuse l'archive Debian sur une erreur GPG peu explicite. Le script
s'arrête tôt avec la commande qui corrige.

## Ce que contient l'image, et pourquoi

Les prérequis sont déduits du binaire lui-même, pas devinés :

- `readelf -d` → `libcurl.so.4`, `libsodium.so.23`, `libstdc++.so.6`,
  `libgcc_s.so.1` ;
- `strings` → killbit appelle `hdparm`, `nvme`, `smartctl`, `blkdiscard`,
  `lsblk` et `udevadm` ;
- il utilise libcurl vers des points de terminaison HTTPS, d'où le DHCP via
  `systemd-networkd` et `ca-certificates`.

S'y ajoutent l'identification matérielle (`dmidecode`, `pciutils`, `usbutils`,
`lshw`), le strict nécessaire du système live (`linux-image-amd64`,
`systemd-sysv`, `live-boot`, `live-config`) et le confort en console (`less`,
`nano`, `kbd`, `console-setup`).

### Les dépendances que killbit réclame lui-même

Le binaire porte sa propre liste `REQUIRED_PACKAGES`, la contrôle au démarrage
avec `dpkg-query -W -f='${Status}'` — donc **au niveau paquet, pas au niveau
binaire** — et propose sinon un `sudo apt install`. Sur une image live, cette
installation est au mieux lente, au pire impossible : les paquets sont donc
embarqués.

| Paquet | Ce que killbit en fait |
|---|---|
| `build-essential`, `g++`, `libsodium-dev`, `libcurl4-openssl-dev` | **rien, jamais** : ce sont ses dépendances de compilation, qu'il contrôle quand même au démarrage. Sans elles il sort en code 1 sans rien effacer. Fournies par des paquets vides, voir ci-dessous |
| `curl`, `hdparm`, `nvme-cli`, `util-linux`, `coreutils`, `smartmontools` | effacement et interrogation des supports |
| `inxi` + `libcpanel-json-xs-perl` | `inxi … --output json` : inventaire matériel du rapport |
| `lm-sensors` | `sensors -u` |
| `upower` | `upower -i` |
| `memtester` | test mémoire |
| `network-manager` | `nmcli dev wifi list` |
| `sudo` | killbit invoque littéralement `sudo apt update` / `sudo apt install` |

C'est aussi pourquoi **NetworkManager est le gestionnaire réseau de l'image** et
non `systemd-networkd` : deux gestionnaires sur les mêmes interfaces se gênent,
et `nmcli` a besoin du sien. `systemd-resolved` reste en place pour le DNS,
combinaison que NetworkManager utilise d'office.

Les quatre premières ont manqué jusqu'au 24 novembre 2026 : la liste avait été
lue dans les chaînes du binaire à partir de sa cinquième entrée. Conséquence
mesurée en VM, image hors ligne : killbit passe en installation automatique
sous `--yes`, l'`apt` échoue faute de dépôt joignable, et **il sort en code 1
sans effacer un seul disque**. Sur un réseau d'atelier, il téléchargeait 117 Mo
à chaque poste.

### Les quatre paquets vides

La vraie chaîne de compilation coûte 89 paquets, 439 Mo installés et 88 Mo
d'ISO. Or **killbit ne compile rien** : c'est un binaire déjà lié. Vérifié dans
ses chaînes plutôt que supposé — `g++` n'y figure qu'une fois, dans la liste
elle-même, `gcc` nulle part ailleurs que dans `.gcc_except_table`, aucun appel à
un compilateur, à `make` ou à un en-tête. Sa bibliothèque sodium est déjà là, en
version d'exécution.

L'image satisfait donc son critère **exactement** : quatre paquets dpkg **sans
aucun fichier**, qui portent ces noms et pour lesquels
`dpkg-query -W -f='${Status}'` répond `install ok installed`. Leur description
dit ce qu'ils sont, pour que personne ne découvre à l'atelier qu'un `g++` de
l'image ne compile pas. `KILLBIT_STUB_BUILD_DEPS=0` réembarque la vraie chaîne
le jour où killbit compilerait quelque chose.

La CI vérifie les deux côtés : le critère de killbit passe sur les seize
paquets, et `g++`, `cc`, `make` sont **absents** du système de fichiers.

La CI applique le même critère que killbit sur chacun de ces paquets : une
dépendance qui disparaîtrait ferait échouer la construction, pas l'atelier.

L'URL et l'empreinte du binaire embarqué sont écrites dans
`/etc/killbit-image-release`, pour savoir exactement ce qui a été gravé.

Les paquets sont installés **sans recommandations**.

## Résultat mesuré

| | Image d'origine | Après minimisation | + Wi-Fi | + chaîne de compilation (`v0.2.0`) | **Aujourd'hui (`v0.3.0`)** |
|---|---|---|---|---|---|
| ISO publiée | 522 Mo | 233 Mo | 338 Mo | 426 Mo | **320 Mo** |
| Système embarqué sur disque | — | 450 Mo | 690 Mo | 1 129 Mo | 690 Mo |
| Paquets installés dans l'image | — | 209 | 221 | 310 | 225 |
| Construction à froid | — | 184 s | 225 s | — | 212 s |
| Amorçage jusqu'au marqueur | — | ~6 s | ~5,5 s | — | ~5,5 s de temps noyau |

Les 106 Mo repris entre les deux dernières colonnes viennent de deux endroits,
chacun mesuré sur le même chroot :

- **88 Mo** : les quatre dépendances de compilation, remplacées par des paquets
  vides (voir plus haut). C'est l'essentiel du gain ;
- **18 Mo** : la taille de bloc du squashfs, passée de 128 Kio à 1 Mio.

| Réglage du squashfs | Taille | Durée |
|---|---|---|
| `zstd` 19, blocs de 128 Kio *(ancien réglage)* | 281,4 Mo | 59 s |
| `zstd` 22, blocs de 128 Kio | 281,4 Mo | 74 s |
| **`zstd` 22, blocs de 1 Mio** *(retenu)* | **263,3 Mo** | 57 s |
| `xz`, blocs de 1 Mio | 249,0 Mo | 50 s |

Le **niveau** de compression ne change rien ici — 16 Kio d'écart entre 19 et
22 — alors que la **taille de bloc** reprend 18 Mo, et sans coûter de temps :
moins de blocs à compresser. `xz` reprendrait encore 14 Mo, mais il décompresse
plusieurs fois plus lentement, à chaque démarrage de chaque poste : le réglage
reste `zstd`, `KILLBIT_SQUASHFS_COMP=xz` est à une variable d'environnement.

Ce qui reste dans l'image, par ordre de poids : les micrologiciels 266 Mo, les
modules du noyau 107 Mo, les bibliothèques 107 Mo, le noyau et l'initramfs
52 Mo. L'initramfs seul pèse 40 Mo dans l'ISO, dont 32 Mo de modules et 13 Mo
de base matérielle `udev` : c'est le prix d'un `MODULES=most` qui doit démarrer
sur un parc inconnu.

Les 105 Mo pris par le Wi-Fi ne sont pas un confort : killbit **mesure** le
Wi-Fi de chaque portable et remonte le résultat au serveur. Sans eux, tous les
rapports portaient une panne Wi-Fi qui n'existait pas.

Toutes ces tailles d'ISO sont mesurées sur les images elles-mêmes. Les 727 Mo
cités plus bas viennent d'une simulation d'installation (`apt-get install -s`)
dans une base Debian 13 : c'est ce qui a servi à décider quoi retirer, avant
toute construction.

## Ce que l'image ne contient délibérément pas

Chaque retrait est chiffré, et la CI vérifie qu'il ne revient pas par accident.

| Retiré | Gain | Pourquoi |
|---|---|---|
| X, `openbox`, `xterm`, `firefox-esr` | **727 Mo installés** | killbit ne sert aucune page d'état locale pour l'instant : c'étaient les deux tiers du poids de l'image pour une fonction qui n'avait rien à afficher. `KILLBIT_WITH_BROWSER=1` les réembarque, sans gestionnaire de fenêtres, le jour où cette page existera. |
| `isolinux`, `syslinux-common`, `grub-*`, `mtools`, `dosfstools` | **37 Mo** | Servent à fabriquer l'image ; leurs artefacts sont extraits du chroot, puis les paquets sont purgés avant le squashfs. |
| `/usr/share/doc`, `man`, `info`, locales hors français | ~50 Mo | Personne ne lit les pages de manuel d'un outil d'effacement hors ligne. |
| Micrologiciels GPU | des centaines de Mo | Outil sans interface 3D. |
| La chaîne de compilation que killbit réclame | **88 Mo d'ISO**, 439 Mo installés, 89 paquets | Quatre paquets dpkg vides satisfont son contrôle, et il ne compile rien. `KILLBIT_STUB_BUILD_DEPS=0` les remplace par les vrais. |

Les micrologiciels **Wi-Fi** ont fait partie de cette liste, et n'y sont plus.
Le raisonnement — « l'image ne sait pas saisir un SSID, donc le micrologiciel ne
peut servir à rien » — ignorait que killbit lance `nmcli dev wifi list` sur tout
poste où `upower` voit une batterie, et remonte le résultat sous `"Type":"Wifi"`.
Ce n'était pas un confort réseau mais une **mesure matérielle du poste traité**,
et elle était fausse à chaque passage. Coût du correctif : +105 Mo d'ISO.

## Pourquoi Debian 13, et pas Ubuntu

Deux raisons vérifiées, pas supposées :

1. **killbit exige `GLIBC_2.38`** (symboles versionnés du binaire). Debian 13
   fournit la 2.41. Une base Ubuntu 22.04, en 2.35, ne le lancerait pas.
2. Debian permet de choisir les micrologiciels un par un, au lieu d'un
   méta-paquet qui tire tout. C'est ce qui rend possible d'embarquer le réseau
   filaire et d'écarter le reste.

Accessoirement, en mode navigateur : sur **Ubuntu 24.04, firefox et chromium ne
sont que des paquets de transition vers des snaps**, inutilisables dans un
debootstrap sans snapd. Debian fournit de vrais `.deb`.

## Limites connues

- **Secure Boot doit être désactivé** dans le firmware : le chargeur UEFI n'est
  pas signé. Le support de `shim-signed` est possible mais non implémenté.
- **L'image lance `killbit --yes` sans confirmation.** Elle ne pose qu'une
  question, l'identifiant du poste ; le récapitulatif n'est qu'un décompte de
  8 secondes, annulable par `Echap`. C'est son intérêt en atelier et son risque :
  un identifiant saisi sur le mauvais poste efface le mauvais poste, et il n'y a
  plus de garde-fou à part ce décompte. Pour un passage avec les confirmations de
  killbit, `Ctrl+Alt+F2` puis la commande de l'historique, sans `--yes`.
- **Les quatre dépendances de compilation sont des paquets vides.** Le critère
  de killbit est satisfait, sa fonction ne l'est pas : rien dans l'image ne
  compile. C'est sans conséquence aujourd'hui — il n'appelle aucun compilateur —
  mais une version de killbit qui compilerait quelque chose échouerait là où un
  message d'absence de paquet n'apparaîtra pas. `KILLBIT_STUB_BUILD_DEPS=0`
  reconstruit avec la vraie chaîne, pour 88 Mo d'ISO.
- **Les micrologiciels Wi-Fi embarqués couvrent Intel, Atheros, Broadcom,
  Marvell et Realtek.** Une carte hors de ces familles sera rapportée comme non
  opérationnelle par killbit. `firmware-ti-connectivity` n'est pas embarqué :
  wl12xx équipe des cartes embarquées, pas les portables d'un parc de réemploi.
- La connexion Wi-Fi elle-même n'est pas automatisée : l'image obtient son
  adresse par DHCP sur le réseau filaire. Pour le Wi-Fi, `nmcli dev wifi connect
  <SSID> password <mot_de_passe>` depuis un shell.
- **Sans réseau, killbit n'efface rien.** Il contacte son serveur avant
  d'écrire : s'il ne l'atteint pas, il s'arrête sur « Impossible de contacter
  le serveur » et rend le code 1, sans toucher aux disques. Mesuré en VM
  isolée. Ce n'est pas un choix de l'image, c'est le comportement du binaire —
  mais l'écran d'accueil et le front le disent désormais au lieu d'annoncer
  seulement un rapport perdu.
- L'URL par défaut du binaire pointe sur `refs/heads/main`, donc il peut changer
  sans préavis. Renseigner `KILLBIT_SHA256` pour figer une version.

## Intégration continue

`.github/workflows/build-iso.yml` construit l'image sur `ubuntu-24.04` : à
chaque push sur `main`, sur chaque PR et à la demande. Avant publication, le
workflow vérifie que :

- le catalogue El Torito contient **une entrée BIOS et une entrée UEFI** ;
- le `.sha256` publié est au nom nu et se vérifie réellement ;
- le squashfs contient `killbit`, ses outils, les trois bibliothèques attendues,
  le front de l'opérateur, **l'historique pré-rempli avec la commande
  d'effacement**, et de quoi faire aboutir le test Wi-Fi de killbit ;
- les composants retirés sont bien **absents** — X, openbox, xterm, firefox et
  les outils de fabrication. Sans ce contrôle, la minimisation se déferait au
  premier ajout de paquet distrait ;
- **les sorties de secours existent** : `getty@tty2` et `getty@tty3` activées,
  autologin root dans leur réglage, et le rappel `Ctrl+Alt+F2` présent dans le
  front. Une console de secours qui demanderait un mot de passe serait
  infranchissable — root n'en a pas dans cette image ;
- **la chaîne de compilation n'est pas revenue** : `g++`, `cc` et `make` absents
  du système de fichiers, alors que le critère de killbit passe sur les seize
  paquets. Si un binaire de compilation réapparaît, c'est qu'un paquet vide a
  été remplacé par le vrai, et l'ISO a repris 88 Mo sans que personne l'ait
  demandé ;
- les images **démarrent réellement**, en BIOS et en UEFI, dans QEMU, les deux
  amorçages menés en parallèle ;
- le **front ncurses s'affiche, réagit, et part tout seul** : le test attend que
  l'écran devienne bleu — `dialog` peint le fond, une console en texte jamais —
  tape un identifiant au clavier du poste via le moniteur QEMU, vérifie que
  l'écran change, puis **ne frappe plus rien** et vérifie que le bleu quitte
  l'écran de lui-même : c'est le décompte qui arrive au bout. La machine
  virtuelle est coupée aussitôt, isolée du réseau (`restrict=on`) et n'a qu'un
  fichier creux temporaire comme disque ;
- la **sortie de secours fonctionne vraiment** : le test envoie `Ctrl+Alt+F2` au
  clavier du poste, vérifie que le bleu quitte l'écran, et que l'invite de
  l'image y est — elle écrit `killbit` en **rouge vif**, ce qui ne peut
  apparaître que si l'autologin a abouti et que `.bashrc` a été lu. Une invite
  de connexion serait blanche sur noir. Puis `Ctrl+Alt+F1` doit ramener le
  front. Tout cela sans OCR, en comptant des pixels.

Ces garde-fous existent parce qu'une ISO peut se construire sans erreur tout en
étant inutilisable : amorçable en BIOS seul, amputée d'une dépendance, ou prise
de panique au démarrage faute de `/sbin/init`.
