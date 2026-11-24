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
| `root/.bash_profile` | Sur `tty1` uniquement, enchaîne sur le front : `killbit-guide.sh` s'il est présent, sinon `startx` en mode navigateur, sinon l'accueil en texte. Le choix se fait sur la **présence des fichiers**, pas sur un drapeau de construction, pour qu'un seul fichier serve à toutes les variantes. Les autres consoles donnent un shell normal, utile au dépannage. |
| `root/.bashrc` | Invite, réglages d'historique, alias `aide` et, dans l'image guidée, `guide` pour revenir au front. |
| `root/.bash_history` | **Généré par le script**, pas présent dans l'overlay : il dérive de `KILLBIT_REPORT_URL`, pour que l'écran d'accueil et l'historique ne puissent pas diverger. Dernière ligne = première flèche vers le haut. |
| `root/.xinitrc` | Mode navigateur uniquement, et **sans gestionnaire de fenêtres**. Retiré de l'image en mode console, pour que le chemin de démarrage reste sans ambiguïté. |
| `usr/local/sbin/killbit-session.sh` | Écran d'accueil en texte : identité de l'image, réseau, supports, commande à lancer. Puis un shell interactif. `--aide-seule` pour le réafficher. |
| `usr/local/sbin/killbit-guide.sh` | Front ncurses (`dialog`) de l'image guidée : saisie de l'identifiant, récapitulatif, `killbit --yes`, journal dans `/var/log/killbit/`. **Retiré du chroot** quand `KILLBIT_FRONT=shell`. |
| `etc/systemd/system/killbit-ready.service` | Émet `KILLBIT-IMAGE-READY` sur la console série. C'est ce que le test d'amorçage attend. |
| `etc/network/` | Dossier vide, voir le tableau des pièges. |

Le fichier `systemd-networkd` qui portait le DHCP a été retiré : killbit appelle
`nmcli dev wifi list`, NetworkManager doit donc tourner, et deux gestionnaires
réseau sur les mêmes interfaces se gênent. NetworkManager gère les interfaces,
`systemd-resolved` le DNS.

### Les deux fronts, et ce que chacun promet

`KILLBIT_FRONT` choisit ce qui s'affiche sur `tty1`. Les deux images sortent du
même script et ne diffèrent que par un paquet, `dialog`, et par la présence de
`killbit-guide.sh`.

| | `shell` (défaut) | `guide` |
|---|---|---|
| ISO | `killbit-live.iso` | `killbit-live-guide.iso` |
| Au démarrage | accueil en texte, puis un shell | front ncurses plein écran |
| Saisie | l'opérateur tape la commande, pré-remplie dans l'historique | l'identifiant du poste, et rien d'autre |
| Appel de killbit | sans `--yes` : killbit garde toutes ses confirmations | **avec `--yes`** : killbit ne demande plus rien |
| Confirmations avant écriture | celles de killbit | **une seule**, le récapitulatif du front |

Dans l'image `shell`, **rien ne s'efface tout seul** : `killbit` n'y est appelé
nulle part avec `--yes`.

Dans l'image `guide`, `--yes` est le but : enchaîner les postes sans répondre à
des questions. C'est précisément pour cela que le front en pose une, et une
seule, au récapitulatif — identifiant saisi, serveur, et **liste des disques qui
vont être effacés**, avec leur taille, modèle et numéro de série. Le bouton
sélectionné par défaut y est `Annuler`. Après ce « Effacer », plus rien
n'interrompt l'opération.

Le front se retire de son propre chemin dans deux cas : `dialog` absent de
l'image, ou pas de terminal de contrôle. Il bascule alors sur l'accueil en
texte, parce qu'un poste d'atelier qui démarre sur un écran noir serait pire
qu'un poste sans front.

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
| `KILLBIT_FRONT` | `shell` | `guide` construit l'image à front ncurses, qui lance `killbit --yes` |
| `KILLBIT_WITH_WIFI` | `1` | `0` retire micrologiciels Wi-Fi et `wpasupplicant` ; tous les rapports porteront alors « wifi non opérationnel » |
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

### Le front guidé

```bash
tests/front-test.sh killbit-live-guide.iso captures/
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
4. il s'arrête là. Le dernier « Effacer » lance un effacement réel : ce test
   n'en déclenche jamais, même sur disque virtuel.

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
2. **Les deux images en parallèle**, par une matrice `front: [shell, guide]`.
   Elles sortent du même script : les construire côte à côte coûte le temps
   d'une seule. `fail-fast` est désactivé — si l'une casse, on veut savoir si
   l'autre tient.
3. **Choix du disque de travail** : `/mnt`, le disque temporaire du runner, est
   bien plus grand que la racine. L'y mettre a remplacé l'étape qui supprimait
   dotnet, android et ghc pour faire de la place — elle coûtait **90 secondes**,
   soit 18 % du job, pour un besoin qui n'existe plus depuis que l'image est
   légère. Repli automatique sur `RUNNER_TEMP` si `/mnt` manque de place.
4. Construction.
5. **Contrôle El Torito** : une entrée BIOS *et* une entrée UEFI. Une ISO BIOS
   seul ne démarre pas sur du matériel post-2012 à CSM désactivé, et le défaut
   est invisible à l'œil nu.
6. **Contrôle de l'empreinte publiée** : format au nom nu, puis un
   `sha256sum -c` réel. Le `.sha256` a un temps porté le chemin du runner, ce
   qui rendait invérifiable la commande que la documentation donne pourtant.
7. **Contrôle du contenu**, en trois volets.
   Ce qui doit être là : killbit, ses outils, les trois bibliothèques, le front
   de l'opérateur, l'historique pré-rempli — la commande d'effacement y est
   cherchée littéralement — et de quoi faire aboutir le test Wi-Fi de killbit
   (`wpa_supplicant`, `regulatory.db`, micrologiciels `iwlwifi`).
   Ce qui doit avoir **disparu** : X, openbox, xterm, firefox, les outils de
   fabrication. Sans ce volet, la minimisation se déferait au premier ajout de
   paquet distrait, et personne ne le verrait.
   Et ce qui **distingue les deux images** : `dialog` et `killbit-guide.sh`
   présents dans l'image guidée, absents de l'autre, `front=` conforme dans
   `/etc/killbit-image-release`. Sans ce volet, les deux images pourraient être
   livrées identiques sans que rien n'alerte.
8. **Tests d'amorçage réels**, BIOS et UEFI menés **en parallèle**. Le runner
   n'a pas KVM, les deux amorçages tournent donc en émulation : les enchaîner
   coûtait le double pour rien, les deux processus QEMU ne se gênant qu'à la
   marge sur quatre vCPU.
9. **Test du front ncurses** sur l'image guidée seulement (voir § 6).
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
- **L'image guidée lance `killbit --yes`.** Elle ne pose qu'une question, le
  récapitulatif, et plus rien ensuite. C'est son intérêt en atelier et son
  risque : un identifiant saisi sur le mauvais poste efface le mauvais poste.
  L'image `shell` reste disponible pour qui préfère les confirmations de
  killbit.
- Le test Wi-Fi de killbit dépend du micrologiciel de la carte. Les familles
  Intel, Atheros, Broadcom, Marvell et Realtek sont embarquées ;
  `firmware-ti-connectivity` ne l'est pas. Une carte hors de ces familles sera
  rapportée comme non opérationnelle.
