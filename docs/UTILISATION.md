# Utiliser l'image killbit

Guide destiné aux bénévoles qui effacent les supports des PC reconditionnés.

---

## 1. L'image

Une seule image est publiée : **`killbit-live.iso`**. Au démarrage, elle ouvre
un front en texte plein écran qui ne demande **que l'identifiant du poste** ;
l'effacement part ensuite seul, après un décompte de 8 secondes.

> **Aucune confirmation.** L'image lance killbit avec `--yes`, donc killbit ne
> demande plus rien, et le front n'ajoute pas de question : la saisie de
> l'identifiant est le dernier geste. Un récapitulatif — identifiant, serveur,
> liste des disques qui vont être effacés — reste affiché **8 secondes** avec un
> décompte, puis l'effacement démarre seul. `Echap` pendant ces 8 secondes est
> la seule façon de l'arrêter.

Il y a eu deux images jusqu'à la `v0.2.0` : celle-ci, et une autre qui rendait
simplement un shell. La seconde a disparu parce que le shell est **dans** cette
image : `Ctrl+Alt+F2` à tout moment (voir §6).

## 2. Récupérer l'image

Deux sources, au choix :

- la release **`latest`** du dépôt, reconstruite à chaque modification ;
- une release versionnée `vX.Y.Z`, si vous voulez une version figée.

Chaque image est accompagnée de son empreinte :

| Fichier | Rôle |
|---|---|
| `killbit-live.iso` | l'image à écrire sur la clé |
| `killbit-live.iso.sha256` | l'empreinte, pour vérifier le téléchargement |

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
connecte sans mot de passe, puis enchaîne sur le front. Il n'y a ni bureau ni
fenêtres : l'image ne contient pas de serveur graphique, ce qui la rend beaucoup
plus légère et plus rapide à démarrer.

---

## 5. Le front : un identifiant, et c'est tout

Rien à taper au clavier sauf l'identifiant. Le poste démarre directement sur
l'écran de saisie.

**1. Identifiant du poste.** Saisissez l'identifiant qui figure sur
l'**étiquette QRcode** — 11 chiffres, sans aucune lettre, par exemple
`21062200075` —, puis `Valider`. L'écran
rappelle l'adresse de remontée et l'état du réseau.

Le clavier est en disposition **française** : les chiffres s'obtiennent avec
`Maj`, comme sur le clavier du portable que vous traitez.

Si l'identifiant ne ressemble pas au format attendu, le front le signale et
propose de corriger — il ne refuse pas, car d'autres formats existent, mais une
faute de frappe rattacherait le rapport au mauvais poste et ne se verrait
qu'après l'effacement.

Le bouton `Aide` réaffiche l'écran d'explication. `Echap` quitte le front et
donne la main en ligne de commande.

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
réafficher l'aide, d'éteindre ou de redémarrer.

Si aucun disque n'est détecté, le front le dit et ne propose pas d'effacer :
le contrôleur est probablement en mode RAID dans le firmware du poste, à
basculer en AHCI.

---

## 6. Reprendre la main en ligne de commande

**`Ctrl+Alt+F2`.** Vous arrivez sur une console déjà connectée en root, sans
mot de passe à chercher. Elle fonctionne **à tout moment**, y compris pendant
que killbit écrit sur les disques : elle ne dépend pas du front.
`Ctrl+Alt+F3` en donne une seconde, `Ctrl+Alt+F1` ramène au front — intact,
l'écran de chaque console est conservé.

Ce rappel est écrit en bas de chaque fenêtre du front, décompte compris.

Deux autres chemins, quand le front a la main : `Echap` sur l'écran de saisie,
et `Shell` dans le menu de fin de passage. Depuis n'importe quelle console, la
commande `guide` ramène au front.

La console rend un shell root, avec l'invite `killbit:~#`. La commande `aide` y
affiche l'écran d'accueil — identité de l'image, état réseau, supports détectés,
commande à lancer — recalculé au moment où on le demande, et non figé à
l'amorçage.

### Effacer à la main, avec les questions de killbit

**Appuyez deux fois sur la flèche HAUT.** La commande est dans l'historique du
shell, adresse de remontée comprise :

```
killbit -i <id_du_poste> -u https://actionnumeriquesolidaire.org
```

Remplacez `<id_du_poste>` par l'identifiant serveur de la machine, celui qui
figure sur son **étiquette QRcode** (11 chiffres, sans lettre, par exemple
`21062200075`), puis validez.
Vous n'avez donc jamais à retaper l'adresse, qui est la source d'erreur la plus
fréquente.

> La **première** flèche HAUT ramène `guide`, le retour au front : c'est le
> geste le plus courant. La commande d'effacement est juste derrière.

> Si vous validez **sans** remplacer `<id_du_poste>`, le shell refuse la ligne
> et rien ne s'exécute : les chevrons sont des caractères spéciaux. C'est un
> garde-fou volontaire, pas une panne. Corrigez et relancez.

**Lancée ainsi, la commande ne contient pas `--yes`** : killbit pose donc ses
propres questions, dont le choix de la méthode (*Purge* ou *Clear*, selon NIST
SP 800-88 Rev. 2 et IEEE Std 2883-2022). C'est le passage à utiliser quand on
veut relire chaque étape plutôt qu'enchaîner les postes.

### Autres commandes utiles

| Commande | Effet |
|---|---|
| `guide` | revient au front guidé |
| `aide` | réaffiche l'écran d'aide |
| `killbit --check` | contrôle et remonte l'état **sans rien effacer** |
| `killbit --help` | liste complète des options |
| `killbit -e <id>` | identifiant personnalisé au lieu de l'identifiant ANS |
| `killbit -u <url>` | pointer vers un autre serveur de collecte |

---

## 7. En cas de problème

| Symptôme | Piste |
|---|---|
| La clé n'apparaît pas au menu de démarrage | Secure Boot actif, ou clé écrite sur une partition au lieu du disque entier |
| L'écran reste noir après le choix de la clé | Matériel très ancien : essayez le mode BIOS hérité (CSM) dans le firmware |
| `AUCUNE adresse IP` | Câble Ethernet débranché, ou pas de DHCP. Pour le Wi-Fi : `nmcli dev wifi connect <SSID> password <mot_de_passe>` depuis un shell. **Tant qu'il n'y a pas de réseau, killbit refuse d'effacer** |
| `Impossible de contacter le serveur` | killbit joint son serveur avant d'écrire. Rien n'a été effacé : rétablissez le réseau et recommencez le poste. Pour savoir où ça coince, depuis `Ctrl+Alt+F2` : `ping 1.1.1.1` répond ⇒ le réseau est là, et c'est le DNS ; `nslookup actionnumeriquesolidaire.org` répond ⇒ le DNS est là, et c'est la sortie HTTPS |
| `Impossible de contacter le serveur` **sur un poste démarré par le réseau (PXE)** | Le poste a bien une adresse mais ne résout aucun nom. L'image le corrige d'elle-même depuis la `v0.3.1` (service `killbit-dns-netboot`). Sur une image plus ancienne : `Ctrl+Alt+F2`, puis `resolvectl dns <carte> <ip_du_serveur_dns>` (la carte et le DNS sont dans `/run/net-*.conf`), et reprendre le poste |
| Un disque n'apparaît pas dans la liste | Contrôleur en mode RAID dans le firmware : basculez-le en AHCI |
| killbit refuse d'effacer un disque | Lisez le message : un disque gelé par le firmware (`frozen`) demande un cycle de veille/réveil |
| killbit rapporte un Wi-Fi non opérationnel | Si le poste est un portable dont le Wi-Fi fonctionne, signalez-le : les micrologiciels Wi-Fi sont embarqués depuis la version `v0.2.0`, et un rapport faux sur ce point est un défaut de l'image |
| L'effacement est parti alors que vous relisiez l'écran | Le décompte de 8 secondes ne s'interrompt que par `Echap`. Les disques du poste sont perdus ; le rapport, lui, est juste si l'identifiant était bon |

Pour un diagnostic plus poussé, `Ctrl+Alt+F2` et `Ctrl+Alt+F3` donnent deux
consoles déjà connectées en root, et tous les outils habituels sont présents :
`lsblk`, `smartctl`, `hdparm`, `nvme`, `dmidecode`, `lshw`, et pour le réseau
`ip`, `nmcli`, et — depuis la `v0.3.1` — `ping`, `nslookup`, `dig` et `host`.
La commande `aide` réaffiche l'écran d'aide, `guide` ramène au front.

> Les consoles `F4` à `F6` existent aussi, mais elles demandent une connexion
> que personne ne peut franchir : le compte root de l'image n'a pas de mot de
> passe. Utilisez `F2` ou `F3`, qui sont préparées pour cela.

Le clavier est en disposition **française** par défaut.

Toutes les dépendances que killbit réclame sont déjà dans l'image : il ne doit
jamais vous proposer d'en installer. S'il le fait, signalez-le — l'image a un
défaut, et sur un poste hors ligne cette installation ne peut pas aboutir.
