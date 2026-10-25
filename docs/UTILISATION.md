# Utiliser l'image killbit

Guide destiné aux bénévoles qui effacent les supports des PC reconditionnés.

---

## 1. Récupérer l'image

Deux sources, au choix :

- la release **`latest`** du dépôt, reconstruite à chaque modification ;
- une release versionnée `vX.Y.Z`, si vous voulez une version figée.

Chaque release contient deux fichiers :

| Fichier | Rôle |
|---|---|
| `killbit-live.iso` | l'image à écrire sur la clé |
| `killbit-live.iso.sha256` | l'empreinte, pour vérifier le téléchargement |

### Vérifier l'image avant de graver

```bash
sha256sum -c killbit-live.iso.sha256
```

La réponse doit être `killbit-live.iso: Réussi`. Si elle ne l'est pas, le
téléchargement est corrompu : recommencez, ne gravez pas.

---

## 2. Écrire sur une clé USB

> **Attention** : `dd` écrase la cible sans rien demander. Vérifiez deux fois le
> nom du périphérique — une erreur ici efface votre propre disque.

Identifier la clé :

```bash
lsblk -d -o NAME,SIZE,MODEL,TRAN
```

La clé est typiquement `/dev/sdb` avec `TRAN=usb`. Écrire :

```bash
sudo dd if=killbit-live.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Remplacez `/dev/sdX` par le périphérique **entier** (`/dev/sdb`), jamais une
partition (`/dev/sdb1`).

L'image est hybride : la même clé démarre en BIOS hérité comme en UEFI.

---

## 3. Démarrer le PC à effacer

1. Branchez la clé et allumez la machine.
2. Ouvrez le menu de démarrage — souvent `F12`, parfois `F9`, `F11`, `Échap`
   ou `F2` selon le constructeur.
3. **Désactivez le Secure Boot** dans le firmware si la clé n'apparaît pas ou
   refuse de démarrer. Le chargeur de cette image n'est pas signé : c'est la
   cause la plus fréquente d'un échec de démarrage.
4. Choisissez la clé USB.

Au démarrage, la machine ouvre automatiquement une session graphique avec un
terminal en plein écran. Aucun mot de passe n'est demandé.

---

## 4. L'écran d'accueil

Le terminal affiche :

- l'**identité de l'image** : l'URL et l'empreinte du binaire killbit embarqué,
  la base système et la date de construction ;
- l'**état réseau** : l'adresse IP obtenue. Si la ligne indique
  `AUCUNE adresse IP`, l'effacement local fonctionnera mais **la remontée du
  rapport échouera** — branchez un câble Ethernet avant de continuer ;
- les **supports détectés**, avec taille, modèle et numéro de série ;
- l'instruction à taper.

---

## 5. Lancer un effacement

```
killbit -i <id_du_poste>
```

`<id_du_poste>` est l'identifiant serveur de la machine, celui qui figure sur
son étiquette.

killbit pose ensuite ses propres questions, dont le choix de la méthode
(*Purge* ou *Clear*, selon NIST SP 800-88 Rev. 2 et IEEE Std 2883-2022).

> **L'effacement est irréversible.** Rien ne se lance automatiquement : l'image
> n'appelle jamais killbit avec `--yes`.

### Autres commandes utiles

| Commande | Effet |
|---|---|
| `killbit --check` | contrôle et remonte l'état **sans rien effacer** |
| `killbit --help` | liste complète des options |
| `killbit -e <id>` | identifiant personnalisé au lieu de l'identifiant ANS |
| `killbit -u <url>` | pointer vers un autre serveur de collecte |

---

## 6. En cas de problème

| Symptôme | Piste |
|---|---|
| La clé n'apparaît pas au menu de démarrage | Secure Boot actif, ou clé écrite sur une partition au lieu du disque entier |
| L'écran reste noir après le choix de la clé | Matériel très ancien : essayez le mode BIOS hérité (CSM) dans le firmware |
| `AUCUNE adresse IP` | Câble Ethernet débranché, ou pas de DHCP sur le réseau |
| Un disque n'apparaît pas dans la liste | Contrôleur en mode RAID dans le firmware : basculez-le en AHCI |
| killbit refuse d'effacer un disque | Lisez le message : un disque gelé par le firmware (`frozen`) demande un cycle de veille/réveil |

Pour un diagnostic plus poussé, les autres consoles texte restent accessibles
avec `Ctrl+Alt+F2` à `F6`, et tous les outils habituels sont présents :
`lsblk`, `smartctl`, `hdparm`, `nvme`, `dmidecode`, `lshw`.
