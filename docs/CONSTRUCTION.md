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
| 7 | `mksquashfs` | Compression `zstd` niveau 19 par défaut. zstd décompresse plusieurs fois plus vite que `xz`, ce qui raccourcit autant le démarrage chez l'opérateur que les tests d'amorçage ; le noyau Debian 13 déclare `CONFIG_SQUASHFS_ZSTD=y`. `KILLBIT_SQUASHFS_COMP=xz` revient à l'ancien réglage, pour quelques Mo de moins et un démarrage plus lent. |
| 8 | Menus isolinux et GRUB | Un menu par mode d'amorçage. |
| 9 | `xorriso` | Assemble l'ISO avec **deux entrées El Torito**. |

---

## 2bis. Ce que chaque phase coûte

Construction à froid, mesurée sur un portable avec KVM (`KILLBIT_ISO_WORK` vidé
au préalable) :

| Phase | Durée |
|---|---|
| Téléchargement et vérification de killbit | 2 s |
| `debootstrap` trixie | 44 s |
| `apt-get update` + `upgrade` | 7 s |
| `apt-get install` (36 paquets) | 71 s |
| `update-initramfs` | 13 s |
| Purge des paquets de fabrication | 15 s |
| `mksquashfs` (zstd niveau 19) | 32 s |
| `xorriso` | 2 s |
| **Total** | **186 s** |

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

### Pas de Wi-Fi, donc pas de micrologiciel Wi-Fi

`firmware-iwlwifi` pesait 111 Mo. Or l'image n'embarque ni `wpasupplicant`, ni
`iwd`, ni aucun moyen de saisir un SSID, et `10-dhcp.network` ne s'applique
qu'à `en*` et `eth*`. Le Wi-Fi était inutilisable **par construction** : ces
111 Mo ne pouvaient servir à rien. Le jour où le Wi-Fi est voulu, il faudra
bien plus que le micrologiciel, et ce sera une décision à part entière.

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
| `root/.bash_profile` | Sur `tty1` uniquement, enchaîne sur l'accueil opérateur — ou sur `startx` si l'image a été construite en mode navigateur. Les autres consoles donnent un shell normal, utile au dépannage. |
| `root/.bashrc` | Invite, réglages d'historique, alias `aide`. |
| `root/.bash_history` | **Généré par le script**, pas présent dans l'overlay : il dérive de `KILLBIT_REPORT_URL`, pour que l'écran d'accueil et l'historique ne puissent pas diverger. Dernière ligne = première flèche vers le haut. |
| `root/.xinitrc` | Mode navigateur uniquement, et **sans gestionnaire de fenêtres**. Retiré de l'image en mode console, pour que le chemin de démarrage reste sans ambiguïté. |
| `usr/local/sbin/killbit-session.sh` | Écran d'accueil : identité de l'image, réseau, supports, commande à lancer. Puis un shell interactif. `--aide-seule` pour le réafficher. |
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
`xorriso`. Rien de plus : les chargeurs BIOS **et** UEFI sont construits dans le
chroot et leurs artefacts en sont extraits.

| Variable | Défaut | Rôle |
|---|---|---|
| `KILLBIT_URL` | dépôt ANS-public | Binaire à embarquer |
| `KILLBIT_SHA256` | vide | Empreinte attendue ; échec si différente |
| `KILLBIT_REPORT_URL` | `https://actionnumeriquesolidaire.org` | Adresse de remontée, pré-remplie dans l'historique du shell et affichée à l'accueil |
| `KILLBIT_KEYMAP` | `fr` | Disposition clavier de la console |
| `KILLBIT_WITH_BROWSER` | `0` | `1` réembarque X et firefox, sans gestionnaire de fenêtres |
| `KILLBIT_SQUASHFS_COMP` | `zstd` | Compression du squashfs (`xz` pour quelques Mo de moins, au prix du temps) |
| `KILLBIT_SQUASHFS_LEVEL` | `19` | Niveau de compression |
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

1. `shellcheck` sur les trois scripts. Il est **préinstallé** sur l'image des
   runners : l'installer coûtait un `apt-get update` pour rien. Attention, il
   est appelé sans seuil de sévérité, donc une remontée `info` suffit à faire
   échouer le job — c'est voulu, mais ça surprend.
2. **Choix du disque de travail** : `/mnt`, le disque temporaire du runner, est
   bien plus grand que la racine. L'y mettre a remplacé l'étape qui supprimait
   dotnet, android et ghc pour faire de la place — elle coûtait **90 secondes**,
   soit 18 % du job, pour un besoin qui n'existe plus depuis que l'image est
   légère. Repli automatique sur `RUNNER_TEMP` si `/mnt` manque de place.
3. Construction.
4. **Contrôle El Torito** : une entrée BIOS *et* une entrée UEFI. Une ISO BIOS
   seul ne démarre pas sur du matériel post-2012 à CSM désactivé, et le défaut
   est invisible à l'œil nu.
5. **Contrôle du contenu**, en deux volets. Ce qui doit être là : killbit, ses
   outils, les trois bibliothèques, l'accueil opérateur, et l'historique
   pré-rempli — la commande d'effacement y est cherchée littéralement. Et ce qui
   doit avoir **disparu** : X, openbox, xterm, firefox, les outils de
   fabrication, les micrologiciels Wi-Fi. Sans ce second volet, la minimisation
   se déferait au premier ajout de paquet distrait, et personne ne le verrait.
6. **Tests d'amorçage réels**, BIOS et UEFI menés **en parallèle**. Le runner
   n'a pas KVM, les deux amorçages tournent donc en émulation : les enchaîner
   coûtait le double pour rien, les deux processus QEMU ne se gênant qu'à la
   marge sur quatre vCPU.
7. Publication : prerelease glissante `latest` à chaque push sur `main`,
   release versionnée sur tag `v*`.

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
