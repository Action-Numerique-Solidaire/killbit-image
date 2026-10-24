# killbit-image

Construit une **ISO live amorçable** embarquant l'exécutable
[`killbit`](https://github.com/r3dge/ANS-public/raw/refs/heads/main/bin/killbit)
et tous ses prérequis d'exécution, pour l'écrire sur une clé USB et effacer de
façon sécurisée les supports des PC reconditionnés d'Action Numérique Solidaire.

## Démarrage rapide

Récupérer l'ISO depuis l'onglet **Actions** (artefact `killbit-live-iso`) ou
depuis une **release**, puis :

```bash
sudo dd if=killbit-live.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Au démarrage, la console présente un menu : état réseau, liste des supports
détectés, puis lancement de killbit. **Aucun effacement n'est déclenché
automatiquement** — killbit est appelé sans `--yes` et conserve ses propres
confirmations.

## Construire localement

```bash
sudo ./build-iso.sh /chemin/killbit-live.iso
```

Variables utiles :

| Variable | Rôle |
|---|---|
| `KILLBIT_URL` | URL du binaire à embarquer |
| `KILLBIT_SHA256` | Empreinte attendue ; la construction échoue si elle diffère |
| `KILLBIT_ISO_WORK` | Répertoire de travail (défaut `/srv/killbit-iso-build`) |

Dépendances de l'hôte : `debootstrap`, `squashfs-tools`, `xorriso`, `isolinux`,
`syslinux-common`. Le chargeur UEFI est construit **dans le chroot**, donc
l'hôte n'a besoin ni de `grub-efi-amd64-bin`, ni de `mtools`.

## Ce que contient l'image, et pourquoi

Les prérequis ont été déduits du binaire lui-même, pas devinés :

- `readelf -d` → `libcurl.so.4`, `libsodium.so.23`, `libstdc++.so.6`,
  `libgcc_s.so.1` ;
- les symboles versionnés exigent **GLIBC_2.38** → la base doit être
  **Ubuntu 24.04 (noble)** ou plus récent. Une base 22.04 (glibc 2.35) ne
  fonctionnerait pas ;
- `strings` → killbit appelle `hdparm`, `nvme`, `smartctl`, `blkdiscard`,
  `lsblk` et `udevadm` ;
- il utilise libcurl vers des points de terminaison HTTPS, d'où le réseau en
  DHCP et `ca-certificates`.

L'image enregistre l'URL et l'empreinte du binaire embarqué dans
`/etc/killbit-image-release`, pour savoir exactement ce qui a été gravé.

## Limites connues

- **Secure Boot doit être désactivé** dans le firmware : le chargeur UEFI n'est
  pas signé. Le support de `shim-signed` est possible mais non implémenté.
- L'URL par défaut pointe sur `refs/heads/main` : le binaire peut donc changer
  sans préavis. Renseigner `KILLBIT_SHA256` pour figer une version.
- Sans réseau, l'effacement local fonctionne mais la remontée de rapport échoue.

## Intégration continue

`.github/workflows/build-iso.yml` construit l'ISO sur `ubuntu-24.04` à chaque
push sur `main`, sur chaque PR et à la demande. Le workflow **vérifie que le
catalogue El Torito contient bien une entrée BIOS et une entrée UEFI** et échoue
sinon : une ISO BIOS seul ne démarre pas sur du matériel post-2012 à CSM
désactivé, et l'erreur est invisible à l'œil nu.

Un tag `v*` publie en plus une release avec l'ISO et son empreinte.
