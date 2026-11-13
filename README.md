# killbit-image

Construit une **ISO live amorçable** embarquant l'exécutable
[`killbit`](https://github.com/r3dge/ANS-public/raw/refs/heads/main/bin/killbit),
tous ses prérequis d'exécution et rien d'autre, pour l'écrire sur une clé USB et
effacer de façon sécurisée les supports des PC reconditionnés d'Action Numérique
Solidaire.

L'image est **console seule** : ni serveur graphique, ni gestionnaire de
fenêtres. Au démarrage, un écran d'accueil liste les disques détectés et l'état
réseau, et la commande d'effacement attend déjà dans l'historique du shell.

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

Vérifier l'empreinte avec le fichier `.sha256` joint avant de graver.

## Au démarrage

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

**Aucun effacement n'est déclenché automatiquement.** `killbit` n'est jamais
appelé avec `--yes` : c'est l'opérateur qui valide, et killbit conserve ses
propres confirmations.

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

L'URL et l'empreinte du binaire embarqué sont écrites dans
`/etc/killbit-image-release`, pour savoir exactement ce qui a été gravé.

Les paquets sont installés **sans recommandations**.

## Résultat mesuré

| | Avant | Après |
|---|---|---|
| ISO publiée | 522 Mo | **215 Mo** |
| Système embarqué sur disque | — | 371 Mo |
| Paquets installés dans l'image | — | 171 |
| Construction à froid | — | 186 s |
| Amorçage jusqu'au marqueur | — | ~6 s de temps noyau |

Les tailles d'ISO sont mesurées sur les images elles-mêmes. Les 727 Mo et 111 Mo
cités plus bas viennent d'une simulation d'installation (`apt-get install -s`)
dans une base Debian 13 : c'est ce qui a servi à décider quoi retirer, avant
toute construction.

## Ce que l'image ne contient délibérément pas

Chaque retrait est chiffré, et la CI vérifie qu'il ne revient pas par accident.

| Retiré | Gain | Pourquoi |
|---|---|---|
| X, `openbox`, `xterm`, `firefox-esr` | **727 Mo installés** | killbit ne sert aucune page d'état locale pour l'instant : c'étaient les deux tiers du poids de l'image pour une fonction qui n'avait rien à afficher. `KILLBIT_WITH_BROWSER=1` les réembarque, sans gestionnaire de fenêtres, le jour où cette page existera. |
| `firmware-iwlwifi` | **111 Mo** | L'image n'embarque ni `wpasupplicant` ni aucun moyen de saisir un SSID, et sa configuration réseau ne s'applique qu'à `en*`/`eth*`. Le Wi-Fi était inutilisable par construction. |
| `isolinux`, `syslinux-common`, `grub-*`, `mtools`, `dosfstools` | **37 Mo** | Servent à fabriquer l'image ; leurs artefacts sont extraits du chroot, puis les paquets sont purgés avant le squashfs. |
| `/usr/share/doc`, `man`, `info`, locales hors français | ~50 Mo | Personne ne lit les pages de manuel d'un outil d'effacement hors ligne. |
| Micrologiciels GPU | des centaines de Mo | Outil sans interface 3D. |

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
- **Pas de Wi-Fi.** Il faut un câble Ethernet pour que le rapport remonte.
  L'effacement local fonctionne sans réseau.
- L'URL par défaut du binaire pointe sur `refs/heads/main`, donc il peut changer
  sans préavis. Renseigner `KILLBIT_SHA256` pour figer une version.

## Intégration continue

`.github/workflows/build-iso.yml` construit l'ISO sur `ubuntu-24.04` à chaque
push sur `main`, sur chaque PR et à la demande. Avant publication, le workflow
vérifie que :

- le catalogue El Torito contient **une entrée BIOS et une entrée UEFI** ;
- le squashfs contient réellement `killbit`, ses outils, les trois
  bibliothèques attendues, l'écran d'accueil et **l'historique pré-rempli avec
  la commande d'effacement** ;
- les composants retirés sont bien **absents** — X, openbox, xterm, firefox, les
  outils de fabrication et les micrologiciels Wi-Fi. Sans ce second contrôle, la
  minimisation se déferait au premier ajout de paquet distrait ;
- l'image **démarre réellement**, en BIOS et en UEFI, dans QEMU. Les deux
  amorçages sont menés en parallèle.

Ces garde-fous existent parce qu'une ISO peut se construire sans erreur tout en
étant inutilisable : amorçable en BIOS seul, amputée d'une dépendance, ou prise
de panique au démarrage faute de `/sbin/init`.
