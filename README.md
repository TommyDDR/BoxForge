# BoxForge

Concepteur de boîtes de rangement sur mesure (pour tiroirs), en AutoIt + GDI+.

L'application édite le **modèle logique** d'une boîte (4 côtés, un fond,
séparateurs verticaux/horizontaux organisés en sous-zones) ; les pièces
découpables sont générées automatiquement au format **DXF**. Toutes les
dimensions sont en **millimètres**.

## Lancer

```
AutoIt3.exe Main.au3
```

## Architecture (niveaux)

| Niveau | Rôle | Fichiers |
|---|---|---|
| 1 | Structures de données pures (aucune GDI, aucun DXF) | `Box.au3`, `Layers.au3`, `Separator.au3`, `Project.au3` (instance) |
| 2 | Gestion métier : sous-zones, intersections, contraintes, création/déplacement/suppression, sélection | `Zones.au3`, `Selection.au3` |
| 3 | Rendu GDI+ (n'affiche que les données, aucune logique métier) | `Renderer.au3`, `Camera.au3` |
| 4 | Interface : fenêtre, panneaux, menus, souris/clavier | `UI.au3`, `Input.au3` |
| 5 | Persistance et export (indépendants du renderer) | `ProjectIO.au3`, `DXF.au3` |

`App.au3` : état transversal (dirty flags). `Main.au3` : point d'entrée et boucle.

Le pipeline de rendu suit `pratiques-rendu-performant.md` : backbuffer DIB 32bpp
+ memory DC, un seul BitBlt de présentation, anti-scintillement WM_ERASEBKGND,
objets GDI+ partagés (jamais créés par frame), registre de disposers, rendu
uniquement sur dirty flag.

## Contrôles

L'affichage utilise un repère mathématique : l'origine monde (0,0) est **en
bas à gauche** (axe Y vers le haut), sur le coin **intérieur** de la boîte —
les positions des séparateurs se lisent donc directement depuis l'intérieur
des parois (le coin extérieur est en (−épaisseur, −épaisseur)).

- **Clic gauche** dans une sous-zone : créer un séparateur vertical
  (**CTRL** : horizontal, **SHIFT** : global — traverse toutes les sous-zones,
  segments liés en groupe se comportant comme un seul objet)
- **Clic gauche / droit** sur un séparateur : sélection (le groupe entier suit)
- **Glisser** un séparateur : déplacement temps réel, clampé (écart minimal
  10 mm avec parois et séparateurs, jamais hors de sa sous-zone)
- **Glisser un bord de la boîte** : redimensionnement — le bord suit le
  curseur (coordonnées négatives permises pendant la manipulation), le bord
  opposé et le contenu restent fixes ; au relâchement, la boîte est recalée
  en (0,0) et la caméra compensée : visuellement c'est la grille qui se
  recale, pas la boîte. **Glisser un coin** : largeur et longueur à la fois.
- **Molette** : zoom centré sur le curseur — **Bouton du milieu** : pan
- **Suppr** : supprimer la sélection — **Échap** : désélectionner
- Panneau droit : propriétés de la boîte, du layer actif et du séparateur
  sélectionné (position saisissable, layer, longueur, groupe)
- Panneau bas : les 30 layers (couleur, épaisseur, hauteur, créneaux) ;
  la ligne sélectionnée est le layer des nouveaux séparateurs

### Formules de position

Le champ **Position** d'un séparateur accepte un nombre… ou une **formule**
référençant d'autres séparateurs par identifiant : `s1.pos + 20`. Le
séparateur devient alors **piloté** : il suit ses références à chaque
déplacement (drag du pilote, redimensionnement de la boîte…) et ne se
déplace plus directement — effacer la formule (saisir un nombre) le libère.

- Opérateurs : `+ - * / ( )`, nombres décimaux, jetons `sN.pos`.
- Variables boîte (dimensions **intérieures**) : `w`/`b.w` (largeur − 2×ép.),
  `l`/`b.l` (longueur − 2×ép.), `h`/`b.h` (hauteur − fond), `t`/`b.t`
  (épaisseur). Les positions étant relatives au coin intérieur, `w / 2`
  place un séparateur vertical au milieu de l'intérieur.
- Les chaînes de dépendances sont propagées en ordre topologique ; les
  références circulaires sont refusées à la saisie.
- Les contraintes restent souveraines : une formule ne peut ni violer
  l'écart minimal de 10 mm, ni faire traverser un autre séparateur — la
  position est clampée au plus proche possible.
- Les segments d'un groupe SHIFT partagent la formule (objet unique).

Toutes les valeurs (positions, dimensions) sont arrondies au centième de
millimètre.

## Format de projet (.bfp)

Fichier texte à sections, versionné. Seules les données sources sont écrites
(boîte, layers, séparateurs, groupes, positions) ; les dérivées (sous-zones,
portées, intersections) sont recalculées au chargement, qui recrée exactement
le projet. Chargement défensif : un fichier invalide ne touche pas au projet
courant.

## Génération DXF (menu Génération)

DXF R12 ASCII, polylignes fermées, unités mm, pièces étiquetées (layer
`LABELS`), structure sur `STRUCTURE`, séparateurs sur `SEP_Lxx` par matière.

- **Fond** : plaque W×L, encoches de pourtour pour les tenons des côtés,
  trous au droit de chaque créneau de séparateur.
- **Côtés** : coins à queues droites (N/S entaillés, E/O languettes),
  tenons inférieurs traversant le fond, encoche supérieure au droit de chaque
  séparateur (profondeur : `H ≤ h ? H/2 : H − h/2`).
- **Séparateurs** : les segments alignés d'un groupe SHIFT sont fusionnés en
  une pièce continue ; encoches mi-bois aux croisements (haute sur
  l'horizontal, basse sur le vertical — `min(h,v)/2`), une seule encoche sur
  la pièce traversée aux contacts en T ; créneaux inférieurs traversants
  (période = longueur + espacement du layer, motif centré) ; extrémités contre
  une paroi prolongées avec encoche de fixation basse (profondeur = hauteur/2).
