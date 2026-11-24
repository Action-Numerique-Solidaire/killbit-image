# killbit-image

Construit une **ISO live amorçable** embarquant l'exécutable
[`killbit`](https://github.com/r3dge/ANS-public/raw/refs/heads/main/bin/killbit),
tous ses prérequis d'exécution et rien d'autre, pour l'écrire sur une clé USB et
effacer de façon sécurisée les supports des PC reconditionnés d'Action Numérique
Solidaire.

L'image est **console seule** : ni serveur graphique, ni gestionnaire de
fenêtres.

Deux images sont publiées à chaque construction, issues du même script et
différant d'un seul paquet :

| Image | Au démarrage | Pour qui |
|---|---|---|
| `killbit-live.iso` | écran d'accueil, puis un shell ; la commande d'effacement attend dans l'historique, à une flèche HAUT | bénévole à l'aise en ligne de commande, dépannage |
| `killbit-live-guide.iso` | front ncurses plein écran qui ne demande **que l'identifiant du poste**, affiche un récapitulatif, puis lance killbit avec `--yes` | atelier, passages en série |

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

## Au démarrage — image guidée

Le poste démarre directement sur un front en texte plein écran. L'opérateur
saisit l'identifiant qui figure sur l'étiquette QRcode, relit un récapitulatif —
identifiant, serveur de remontée, adresse réseau, et **la liste des disques qui
vont être effacés** — puis confirme.

C'est la **seule** confirmation : killbit est appelé avec `--yes` et ne demande
plus rien, méthode d'effacement comprise (*Purge* par défaut). Le bouton
sélectionné d'office au récapitulatif est `Annuler`. La sortie de killbit est
journalisée dans `/var/log/killbit/`.

Si aucun disque n'est visible, le front le dit et ne propose pas d'effacer.
Le menu de fin enchaîne sur le poste suivant, un shell, l'extinction ou le
redémarrage ; depuis le shell, la commande `guide` ramène au front.

## Au démarrage — image classique

La machine ouvre une **console texte** et connecte l'opérateur sans mot de passe.
L'écran d'accueil affiche l'identité de l'image, l'état réseau, les supports
détectés, puis la commande à lancer :

```
killbit -i <id_du_poste> -u https://actionnumeriquesolidaire.org
```

**Cette commande est pré-chargée dans l'historique du shell** : une flèche vers
le haut la rappelle, il ne reste qu'à remplacer `<id_du_poste>`. L'adresse de
remontée n'a donc jamais à être retapée — c'était la principale source d'erreur
de saisie. `killbit --check` et `killbit --help` sont également dans
l'historique, et la commande `aide` réaffiche l'écran d'accueil.

Si l'opérateur valide sans remplacer `<id_du_poste>`, le shell refuse la ligne
et rien ne s'exécute : les chevrons sont des caractères spéciaux. C'est un
garde-fou volontaire.

**Dans cette image, aucun effacement n'est déclenché automatiquement.**
`killbit` n'y est jamais appelé avec `--yes` : c'est l'opérateur qui valide, et
killbit conserve ses propres confirmations.

Le clavier est en disposition française par défaut (`KILLBIT_KEYMAP`), parce que
saisir une URL sur un clavier AZERTY mal configuré est une épreuve.

## Construire localement

```bash
sudo ./build-iso.sh /chemin/killbit-live.iso
sudo KILLBIT_FRONT=guide ./build-iso.sh /chemin/killbit-live-guide.iso
```

| Variable | Rôle |
|---|---|
| `KILLBIT_URL` | URL du binaire à embarquer |
| `KILLBIT_SHA256` | Empreinte attendue ; la construction échoue si elle diffère |
| `KILLBIT_REPORT_URL` | Adresse de remontée pré-remplie dans l'historique et l'écran d'accueil |
| `KILLBIT_KEYMAP` | Disposition clavier de la console (défaut `fr`) |
| `KILLBIT_FRONT` | `shell` (défaut) ou `guide`, le front ncurses qui lance `killbit --yes` |
| `KILLBIT_WITH_WIFI` | `0` retire micrologiciels Wi-Fi et `wpasupplicant` ; tous les rapports porteront alors « wifi non opérationnel » |
| `KILLBIT_WITH_BROWSER` | `1` réembarque X et firefox, **sans** gestionnaire de fenêtres |
| `KILLBIT_SQUASHFS_COMP` / `_LEVEL` | Compression du squashfs (défaut `zstd` niveau 19) |
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

La CI applique le même critère que killbit sur chacun de ces paquets : une
dépendance qui disparaîtrait ferait échouer la construction, pas l'atelier.

L'URL et l'empreinte du binaire embarqué sont écrites dans
`/etc/killbit-image-release`, pour savoir exactement ce qui a été gravé.

Les paquets sont installés **sans recommandations**.

## Résultat mesuré

| | Image d'origine | Après minimisation | Aujourd'hui, Wi-Fi compris |
|---|---|---|---|
| ISO publiée | 522 Mo | 233 Mo | **338 Mo** |
| Système embarqué sur disque | — | 450 Mo | 690 Mo |
| Paquets installés dans l'image | — | 209 | 219 (221 pour l'image guidée) |
| Construction à froid | — | 184 s | 225 s |
| Amorçage jusqu'au marqueur | — | ~6 s | ~5,5 s de temps noyau |

Les deux images font la même taille à l'octet près : `dialog` et le script du
front pèsent moins que l'arrondi.

Les 105 Mo repris entre les deux dernières colonnes sont les micrologiciels
Wi-Fi et `wpasupplicant`. Ils ne sont pas un confort : killbit **mesure** le
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
- **L'image guidée lance `killbit --yes`.** Elle ne pose qu'une question, le
  récapitulatif, et plus rien ensuite. C'est son intérêt en atelier et son
  risque : un identifiant saisi sur le mauvais poste efface le mauvais poste.
  L'image classique reste publiée pour qui préfère les confirmations de killbit.
- **Les micrologiciels Wi-Fi embarqués couvrent Intel, Atheros, Broadcom,
  Marvell et Realtek.** Une carte hors de ces familles sera rapportée comme non
  opérationnelle par killbit. `firmware-ti-connectivity` n'est pas embarqué :
  wl12xx équipe des cartes embarquées, pas les portables d'un parc de réemploi.
- La connexion Wi-Fi elle-même n'est pas automatisée : l'image obtient son
  adresse par DHCP sur le réseau filaire. Pour le Wi-Fi, `nmcli dev wifi connect
  <SSID> password <mot_de_passe>` depuis un shell. L'effacement local, lui,
  fonctionne sans réseau.
- L'URL par défaut du binaire pointe sur `refs/heads/main`, donc il peut changer
  sans préavis. Renseigner `KILLBIT_SHA256` pour figer une version.

## Intégration continue

`.github/workflows/build-iso.yml` construit **les deux images en parallèle**,
par une matrice, sur `ubuntu-24.04` : à chaque push sur `main`, sur chaque PR et
à la demande. Les deux sortant du même script, les construire côte à côte coûte
le temps d'une seule. Avant publication, le workflow vérifie que :

- le catalogue El Torito contient **une entrée BIOS et une entrée UEFI** ;
- le `.sha256` publié est au nom nu et se vérifie réellement ;
- le squashfs contient `killbit`, ses outils, les trois bibliothèques attendues,
  le front de l'opérateur, **l'historique pré-rempli avec la commande
  d'effacement**, et de quoi faire aboutir le test Wi-Fi de killbit ;
- les composants retirés sont bien **absents** — X, openbox, xterm, firefox et
  les outils de fabrication. Sans ce contrôle, la minimisation se déferait au
  premier ajout de paquet distrait ;
- **les deux images diffèrent réellement** : `dialog` et le front guidé présents
  dans l'une, absents de l'autre, `front=` conforme dans le fichier de release.
  Sans cela, elles pourraient être livrées identiques sans que rien n'alerte ;
- les images **démarrent réellement**, en BIOS et en UEFI, dans QEMU, les deux
  amorçages menés en parallèle ;
- le **front ncurses s'affiche et réagit** : le test attend que l'écran devienne
  bleu — `dialog` peint le fond, une console en texte jamais — tape un
  identifiant au clavier du poste via le moniteur QEMU, et vérifie que l'écran
  change. Il s'arrête avant la confirmation : aucun effacement n'est déclenché.

Ces garde-fous existent parce qu'une ISO peut se construire sans erreur tout en
étant inutilisable : amorçable en BIOS seul, amputée d'une dépendance, ou prise
de panique au démarrage faute de `/sbin/init`.
