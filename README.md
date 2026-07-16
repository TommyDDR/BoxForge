# BoxForge

Concepteur de boîtes de rangement sur mesure (pour tiroirs), en AutoIt + GDI+.

L'application dessine le **modèle logique** d'une boîte (4 côtés, un fond,
séparateurs verticaux/horizontaux) ; les pièces découpables sont générées
automatiquement au format DXF. Toutes les dimensions sont en **millimètres**.

## Lancer

```
AutoIt3.exe Main.au3
```

## Architecture (niveaux)

| Niveau | Rôle | Fichiers |
|---|---|---|
| 1 | Structures de données pures (aucune GDI, aucun DXF) | `Box.au3`, `Layers.au3`, `Separator.au3` |
| 2 | Gestion métier : sous-zones, intersections, contraintes, ajout/déplacement/suppression | `Zones.au3`, `Selection.au3` |
| 3 | Rendu GDI+ (n'affiche que les données, aucune logique métier) | `Renderer.au3`, `Camera.au3` |
| 4 | Interface : fenêtre, panneaux, souris, menus | `UI.au3` |
| 5 | Persistance et export (indépendants du renderer) | `ProjectIO.au3`, `DXF.au3` |

`Util.au3` : helpers génériques (niveau 0). `Main.au3` : point d'entrée et boucle.

Le pipeline de rendu suit `pratiques-rendu-performant.md` (backbuffer DIB 32bpp,
un seul blit de présentation par frame, anti-scintillement WM_ERASEBKGND,
registre de disposers GDI+).

## Contrôles

- **Clic gauche** dans une sous-zone : créer un séparateur vertical (**CTRL** : horizontal, **SHIFT** : traversant/global)
- **Clic gauche / droit** sur un séparateur : sélection
- **Glisser** un séparateur : déplacement (clampé, écart minimal 10 mm)
- **Molette** : zoom (centré sur le curseur) — **Bouton du milieu** : déplacement de la vue
- **Suppr** : supprimer le séparateur sélectionné — **Échap** : désélectionner
