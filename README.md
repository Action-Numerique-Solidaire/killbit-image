# killbit-image

Construit une **ISO live amorçable** embarquant l'exécutable
[`killbit`](https://github.com/r3dge/ANS-public/raw/refs/heads/main/bin/killbit),
tous ses prérequis d'exécution et un environnement graphique minimal, pour
l'écrire sur une clé USB et effacer de façon sécurisée les supports des PC
reconditionnés d'Action Numérique Solidaire.

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

La machine ouvre une session graphique minimale (openbox) avec un terminal en
plein écran, qui affiche l'identité de l'image, l'état réseau, les supports
détectés, puis l'instruction :

```
killbit -i <id_du_poste>
```

**Aucun effacement n'est déclenché automatiquement.** `killbit` n'est jamais
appelé avec `--yes` : c'est l'opérateur qui tape la commande, et killbit
conserve ses propres confirmations. `killbit --check` vérifie sans rien effacer.

L'environnement graphique est conservé pour pouvoir afficher plus tard la page
d'état locale de killbit dans le navigateur embarqué (`firefox-esr`).

## Construire localement

```bash
sudo ./build-iso.sh /chemin/killbit-live.iso
```

| Variable | Rôle |
|---|---|
| `KILLBIT_URL` | URL du binaire à embarquer |
| `KILLBIT_SHA256` | Empreinte attendue ; la construction échoue si elle diffère |
| `KILLBIT_WITH_BROWSER` | `0` retire firefox-esr et allège l'image d'environ 266 Mo |
| `KILLBIT_ISO_WORK` | Répertoire de travail (défaut `/srv/killbit-iso-build`) |
| `KILLBIT_DISTRO` | Suite Debian (défaut `trixie`) |

Dépendances de l'hôte : `debootstrap`, `debian-archive-keyring`,
`squashfs-tools`, `xorriso`, `isolinux`, `syslinux-common`. Le chargeur UEFI
est construit **dans le chroot**, donc l'hôte n'a besoin ni de
`grub-efi-amd64-bin` ni de `mtools`.

Sur un hôte Ubuntu, `debian-archive-keyring` est indispensable : sans lui
debootstrap refuse l'archive Debian sur une erreur GPG peu explicite. Le script
s'arrête tôt avec la commande qui corrige.

## Pourquoi Debian 13, et pas Ubuntu

Deux raisons vérifiées, pas supposées :

1. **killbit exige `GLIBC_2.38`** (symboles versionnés du binaire). Debian 13
   fournit la 2.41. Une base Ubuntu 22.04, en 2.35, ne le lancerait pas.
2. Sur **Ubuntu 24.04, firefox et chromium ne sont que des paquets de
   transition vers des snaps**, inutilisables dans un debootstrap sans snapd.
   Debian fournit de vrais `.deb`.

Debian permet en prime de choisir les micrologiciels un par un : l'image
embarque ceux du réseau (`firmware-realtek`, `firmware-iwlwifi`,
`firmware-misc-nonfree`) et **évite les blobs GPU**, qui pèsent à eux seuls
plus de 200 Mo chez Ubuntu pour un outil sans interface 3D.

## Ce que contient l'image, et pourquoi

Les prérequis sont déduits du binaire lui-même :

- `readelf -d` → `libcurl.so.4`, `libsodium.so.23`, `libstdc++.so.6`,
  `libgcc_s.so.1` ;
- `strings` → killbit appelle `hdparm`, `nvme`, `smartctl`, `blkdiscard`,
  `lsblk` et `udevadm` ;
- il utilise libcurl vers des points de terminaison HTTPS, d'où le DHCP via
  `systemd-networkd` et `ca-certificates`.

L'URL et l'empreinte du binaire embarqué sont écrites dans
`/etc/killbit-image-release`, pour savoir exactement ce qui a été gravé.

Les paquets sont installés **sans recommandations**, d'où la présence explicite
de `xserver-xorg-input-libinput` : sans lui, clavier et souris seraient inertes
sous X.

## Limites connues

- **Secure Boot doit être désactivé** dans le firmware : le chargeur UEFI n'est
  pas signé. Le support de `shim-signed` est possible mais non implémenté.
- L'URL par défaut pointe sur `refs/heads/main`, donc le binaire peut changer
  sans préavis. Renseigner `KILLBIT_SHA256` pour figer une version.
- Sans réseau, l'effacement local fonctionne mais la remontée de rapport échoue.

## Intégration continue

`.github/workflows/build-iso.yml` construit l'ISO sur `ubuntu-24.04` à chaque
push sur `main`, sur chaque PR et à la demande. Avant publication, le workflow
vérifie que :

- le catalogue El Torito contient **une entrée BIOS et une entrée UEFI** ;
- le squashfs contient réellement `killbit`, `hdparm`, `nvme`, `smartctl`,
  `xterm`, `openbox` et les trois bibliothèques attendues.

Ces deux garde-fous existent parce qu'une ISO peut se construire sans erreur
tout en étant inutilisable : amorçable en BIOS seul, ou amputée d'une
dépendance.
