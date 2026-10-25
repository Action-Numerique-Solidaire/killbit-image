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
        │  apt : bibliotheques, outils disque, X, navigateur
        │  overlay : session operateur, reseau, marqueur
        │  grub-mkstandalone : chargeur UEFI (dans le chroot)
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
| 7 | `mksquashfs` | Compression `xz`. C'est l'étape la plus longue, environ 50 secondes. |
| 8 | Menus isolinux et GRUB | Un menu par mode d'amorçage. |
| 9 | `xorriso` | Assemble l'ISO avec **deux entrées El Torito**. |

---

## 3. Décisions structurantes

### Base Debian 13, pas Ubuntu

Deux raisons, toutes deux vérifiées plutôt que supposées :

1. **killbit exige `GLIBC_2.38`.** Les symboles versionnés du binaire le disent
   (`readelf -V`). Debian 13 fournit 2.41. Une base Ubuntu 22.04, en 2.35, ne
   le lancerait pas du tout.
2. **Sur Ubuntu 24.04, `firefox` et `chromium` ne sont que des paquets de
   transition vers des snaps**, inutilisables dans un debootstrap sans snapd.
   Debian fournit de vrais `.deb`. C'était bloquant, l'image devant conserver
   un navigateur pour la future page d'état locale de killbit.

Debian permet en prime de choisir les micrologiciels un par un. L'image embarque
ceux du réseau et **évite les blobs GPU** : chez Ubuntu, `linux-firmware` tire
109 Mo de nvidia et 60 Mo de qualcomm pour un outil sans interface 3D.

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
| Pilotes d'entrée X | Clavier et souris inertes sous X | `xserver-xorg-input-libinput` listé explicitement |
| `xauth` absent | `startx` échoue | Paquet listé explicitement |
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
| `root/.bash_profile` | Sur `tty1` uniquement, enchaîne sur `startx`. Les autres consoles donnent un shell normal, utile au dépannage. |
| `root/.xinitrc` | Session graphique : `openbox` + un `xterm` plein écran. Désactive la mise en veille, un effacement pouvant être long. |
| `usr/local/sbin/killbit-session.sh` | Écran d'accueil : identité de l'image, réseau, supports, instruction. Puis un shell interactif. |
| `etc/systemd/network/10-dhcp.network` | DHCP sur `en*` et `eth*`. |
| `etc/systemd/system/killbit-ready.service` | Émet `KILLBIT-IMAGE-READY` sur la console série. C'est ce que le test d'amorçage attend. |
| `etc/network/` | Dossier vide, voir le tableau des pièges. |

**L'image n'efface jamais rien toute seule** : `killbit` n'est appelé nulle part
avec `--yes`. L'opérateur tape la commande, et killbit garde ses confirmations.

---

## 5. Construire localement

```bash
sudo ./build-iso.sh /chemin/killbit-live.iso
```

Hôte requis : `debootstrap`, `debian-archive-keyring`, `squashfs-tools`,
`xorriso`, `isolinux`, `syslinux-common`.

| Variable | Défaut | Rôle |
|---|---|---|
| `KILLBIT_URL` | dépôt ANS-public | Binaire à embarquer |
| `KILLBIT_SHA256` | vide | Empreinte attendue ; échec si différente |
| `KILLBIT_WITH_BROWSER` | `1` | `0` retire firefox-esr, environ 266 Mo de moins |
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

Ce test existe parce que **la vérification de contenu ne suffit pas** : une ISO
a déjà contenu tous les bons fichiers tout en paniquant au démarrage.

---

## 7. L'intégration continue

[`.github/workflows/build-iso.yml`](../.github/workflows/build-iso.yml),
sur `ubuntu-24.04`.

1. `shellcheck` sur les trois scripts.
2. Libération d'espace disque — l'image préinstallée du runner ne laisse pas
   assez de place pour un chroot, un squashfs et une ISO.
3. Construction.
4. **Contrôle El Torito** : une entrée BIOS *et* une entrée UEFI. Une ISO BIOS
   seul ne démarre pas sur du matériel post-2012 à CSM désactivé, et le défaut
   est invisible à l'œil nu.
5. **Contrôle du contenu** : montage du squashfs, présence de killbit, des
   outils disque, de `xterm`, d'`openbox` et des trois bibliothèques.
6. **Tests d'amorçage réels**, en BIOS puis en UEFI.
7. Publication : prerelease glissante `latest` à chaque push sur `main`,
   release versionnée sur tag `v*`.

Le runner n'a pas KVM : les deux tests d'amorçage tournent en émulation, d'où
les délais généreux.

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
