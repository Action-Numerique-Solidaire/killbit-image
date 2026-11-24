# Utiliser l'image killbit

Guide destiné aux bénévoles qui effacent les supports des PC reconditionnés.

---

## 1. Choisir l'image

Chaque release contient **deux images**, construites depuis le même script et
avec le même contenu à un paquet près. Elles ne diffèrent que par ce qui
s'affiche au démarrage.

| Image | Au démarrage | Pour qui |
|---|---|---|
| `killbit-live.iso` | écran d'accueil, puis un shell. La commande d'effacement est pré-remplie dans l'historique : flèche HAUT pour la rappeler, puis remplacer l'identifiant. | bénévole à l'aise en ligne de commande, ou dépannage |
| `killbit-live-guide.iso` | front en texte plein écran qui ne demande **que l'identifiant du poste** : l'effacement part ensuite seul, après un décompte de 8 secondes. | atelier, passages en série, bénévole occasionnel |

Les deux effacent de la même façon : c'est le même binaire killbit, avec les
mêmes options. La différence est l'écran, pas le traitement.

> **Aucune confirmation dans l'image guidée.** Elle lance killbit avec
> `--yes`, donc killbit ne demande plus rien, et le front n'ajoute pas de
> question : la saisie de l'identifiant est le dernier geste. Un récapitulatif
> — identifiant, serveur, liste des disques qui vont être effacés — reste
> affiché **8 secondes** avec un décompte, puis l'effacement démarre seul.
> `Echap` pendant ces 8 secondes est la seule façon de l'arrêter.

## 2. Récupérer l'image

Deux sources, au choix :

- la release **`latest`** du dépôt, reconstruite à chaque modification ;
- une release versionnée `vX.Y.Z`, si vous voulez une version figée.

Chaque image est accompagnée de son empreinte :

| Fichier | Rôle |
|---|---|
| `killbit-live.iso`, `killbit-live-guide.iso` | les images à écrire sur la clé |
| `…​.iso.sha256` | l'empreinte, pour vérifier le téléchargement |

### Vérifier l'image avant de graver

Depuis le dossier où se trouvent l'ISO et son empreinte :

```bash
sha256sum -c killbit-live.iso.sha256
```

La réponse doit être `killbit-live.iso: Réussi`. Si elle ne l'est pas, le
téléchargement est corrompu : recommencez, ne gravez pas.

---

## 3. Écrire sur une clé USB

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

## 4. Démarrer le PC à effacer

1. Branchez la clé et allumez la machine.
2. Ouvrez le menu de démarrage — souvent `F12`, parfois `F9`, `F11`, `Échap`
   ou `F2` selon le constructeur.
3. **Désactivez le Secure Boot** dans le firmware si la clé n'apparaît pas ou
   refuse de démarrer. Le chargeur de cette image n'est pas signé : c'est la
   cause la plus fréquente d'un échec de démarrage.
4. Choisissez la clé USB.

Au démarrage, la machine ouvre automatiquement une **console texte** et vous
connecte sans mot de passe. Il n'y a ni bureau ni fenêtres : l'image ne contient
pas de serveur graphique, ce qui la rend beaucoup plus légère et plus rapide à
démarrer.

---

## 5a. Image classique : l'écran d'accueil

Le terminal affiche :

- l'**identité de l'image** : l'URL et l'empreinte du binaire killbit embarqué,
  la base système et la date de construction ;
- l'**état réseau** : l'adresse IP obtenue. Si la ligne indique
  `AUCUNE adresse IP`, l'effacement local fonctionnera mais **la remontée du
  rapport échouera** — branchez un câble Ethernet avant de continuer ;
- les **supports détectés**, avec taille, modèle et numéro de série ;
- la **commande à lancer**, avec son adresse de remontée déjà renseignée.

---

## 5b. Image classique : lancer un effacement

**Appuyez sur la flèche HAUT.** La commande est déjà dans l'historique du
shell, adresse de remontée comprise :

```
killbit -i <id_du_poste> -u https://actionnumeriquesolidaire.org
```

Remplacez `<id_du_poste>` par l'identifiant serveur de la machine, celui qui
figure sur son **étiquette QRcode**, au format `R21062200075`, puis validez. Vous n'avez donc jamais à retaper
l'adresse, qui est la source d'erreur la plus fréquente.

> Si vous validez **sans** remplacer `<id_du_poste>`, le shell refuse la ligne
> et rien ne s'exécute : les chevrons sont des caractères spéciaux. C'est un
> garde-fou volontaire, pas une panne. Corrigez et relancez.

Deux autres flèches HAUT remontent à `killbit --check` puis `killbit --help`,
également pré-chargées.

killbit pose ensuite ses propres questions, dont le choix de la méthode
(*Purge* ou *Clear*, selon NIST SP 800-88 Rev. 2 et IEEE Std 2883-2022).

> **L'effacement est irréversible.** Dans cette image, rien ne se lance
> automatiquement : elle n'appelle jamais killbit avec `--yes`, et c'est killbit
> qui pose ses questions.

### Autres commandes utiles

| Commande | Effet |
|---|---|
| `killbit --check` | contrôle et remonte l'état **sans rien effacer** |
| `killbit --help` | liste complète des options |
| `killbit -e <id>` | identifiant personnalisé au lieu de l'identifiant ANS |
| `killbit -u <url>` | pointer vers un autre serveur de collecte |

---

## 6. Image guidée : le front en texte

Rien à taper au clavier sauf l'identifiant. Le poste démarre directement sur
l'écran de saisie.

**1. Identifiant du poste.** Saisissez l'identifiant qui figure sur
l'**étiquette QRcode**, au format `R21062200075`, puis `Valider`. L'écran
rappelle l'adresse de remontée et l'état du réseau.

Le clavier est en disposition **française** : les chiffres s'obtiennent avec
`Maj`, comme sur le clavier du portable que vous traitez.

Si l'identifiant ne ressemble pas au format attendu, le front le signale et
propose de corriger — il ne refuse pas, car d'autres formats existent, mais une
faute de frappe rattacherait le rapport au mauvais poste et ne se verrait
qu'après l'effacement.

Le bouton `Aide` réaffiche l'écran d'explication.

**2. Récapitulatif et décompte.** Le front affiche alors l'identifiant saisi,
le serveur de remontée, l'adresse réseau obtenue et **la liste des disques qui
vont être effacés**, avec taille, modèle et numéro de série, et un décompte de
**8 secondes**. Relisez cette liste pendant qu'il tourne.

> **Il n'y a rien à confirmer.** À la fin du décompte, l'effacement part de
> lui-même. `Echap` ou `Annuler` l'arrête — c'est la dernière occasion.
> `Entrée` (`Effacer maintenant`) n'attend pas la fin du décompte. killbit est
> lancé avec `--yes` : il ne redemandera rien, ni pour la méthode d'effacement
> — *Purge* par défaut — ni avant d'écrire.

**3. Effacement.** L'écran passe en texte brut : c'est killbit qui parle. Sa
sortie est journalisée dans `/var/log/killbit/<identifiant>-<date>.log`.

**4. Poste suivant.** À la fin, un menu propose de traiter un autre poste, de
réafficher l'aide, d'éteindre ou de redémarrer. `Shell` donne la main en ligne
de commande ; la commande `guide` y ramène au front.

Si aucun disque n'est détecté, le front le dit et ne propose pas d'effacer :
le contrôleur est probablement en mode RAID dans le firmware du poste, à
basculer en AHCI.

---

## 7. En cas de problème

| Symptôme | Piste |
|---|---|
| La clé n'apparaît pas au menu de démarrage | Secure Boot actif, ou clé écrite sur une partition au lieu du disque entier |
| L'écran reste noir après le choix de la clé | Matériel très ancien : essayez le mode BIOS hérité (CSM) dans le firmware |
| `AUCUNE adresse IP` | Câble Ethernet débranché, ou pas de DHCP. Pour le Wi-Fi : `nmcli dev wifi connect <SSID> password <mot_de_passe>` depuis un shell. **Tant qu'il n'y a pas de réseau, killbit refuse d'effacer** |
| `Impossible de contacter le serveur` | killbit joint son serveur avant d'écrire. Rien n'a été effacé : rétablissez le réseau et recommencez le poste |
| Un disque n'apparaît pas dans la liste | Contrôleur en mode RAID dans le firmware : basculez-le en AHCI |
| killbit refuse d'effacer un disque | Lisez le message : un disque gelé par le firmware (`frozen`) demande un cycle de veille/réveil |
| killbit rapporte un Wi-Fi non opérationnel | Si le poste est un portable dont le Wi-Fi fonctionne, signalez-le : les micrologiciels Wi-Fi sont embarqués depuis la version `v0.2.0`, et un rapport faux sur ce point est un défaut de l'image |
| L'effacement est parti alors que vous relisiez l'écran | Le décompte de 8 secondes ne s'interrompt que par `Echap`. Les disques du poste sont perdus ; le rapport, lui, est juste si l'identifiant était bon |

Pour un diagnostic plus poussé, les autres consoles texte restent accessibles
avec `Ctrl+Alt+F2` à `F6`, et tous les outils habituels sont présents :
`lsblk`, `smartctl`, `hdparm`, `nvme`, `dmidecode`, `lshw`. La commande `aide`
réaffiche l'écran d'accueil ou l'aide du front guidé, selon l'image.

Le clavier est en disposition **française** par défaut.

Toutes les dépendances que killbit réclame sont déjà dans l'image : il ne doit
jamais vous proposer d'en installer. S'il le fait, signalez-le — l'image a un
défaut, et sur un poste hors ligne cette installation ne peut pas aboutir.
