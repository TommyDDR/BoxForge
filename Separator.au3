#include-once

; =============================================================================
; Separator.au3 — Structure de données d'un séparateur (niveau 1 : données).
;
; Aucune GDI, aucun DXF, aucune UI : uniquement la structure et ses helpers.
;
; Un séparateur est un SEGMENT axial dans l'intérieur de la boîte :
;   - vertical   → ligne X = Pos, s'étendant de Span1 à Span2 en Y
;   - horizontal → ligne Y = Pos, s'étendant de Span1 à Span2 en X
;
; Champs :
;   - Id     : identifiant unique et stable (référencé par la sélection,
;              les groupes n'en dépendent pas : voir Group).
;   - Group  : 0 = séparateur isolé ; sinon identifiant du groupe créé par
;              SHIFT+clic (création globale). Tous les segments d'un groupe
;              se comportent comme UN SEUL objet (sélection, déplacement).
;   - Orient : $SEP_ORIENT_V ou $SEP_ORIENT_H.
;   - Pos    : position de la ligne sur son axe (mm).
;   - Anchor : point d'ancrage LE LONG de la portée (mm). Il identifie la
;              sous-zone que ce séparateur découpe lors du recalcul des
;              sous-zones (cf. Zones.au3). Maintenu au milieu de la portée
;              après chaque recalcul : l'ancre suit les frontières quand
;              elles se déplacent.
;   - Layer  : index du layer (0..29) — matériau du séparateur.
;   - Span1/Span2 : portée du segment (mm). DONNÉE DÉRIVÉE, recalculée par
;              Zones_Rebuild : jamais modifiée directement ailleurs.
;   - Formula : formule de position optionnelle ("" = position libre).
;              Exemple : "s1.pos + 20" → ce séparateur est PILOTÉ : sa
;              position suit celle du séparateur d'identifiant 1, plus
;              20 mm. Évaluée par le métier (Zones.au3) après chaque
;              mutation ; un séparateur piloté ne se déplace plus à la
;              souris. Les segments d'un groupe partagent la formule.
;
; Toutes les valeurs sont en millimètres.
; =============================================================================

; --- Champs de la structure Séparateur ---
Global Enum $SEP_ID, _         ; identifiant unique (entier > 0)
		$SEP_GROUP, _          ; groupe SHIFT (0 = aucun)
		$SEP_ORIENT, _         ; orientation ($SEP_ORIENT_V / $SEP_ORIENT_H)
		$SEP_POS, _            ; position de la ligne sur son axe (mm)
		$SEP_ANCHOR, _         ; ancre le long de la portée (mm)
		$SEP_LAYER, _          ; index du layer (0..29)
		$SEP_SPAN1, _          ; début de portée (mm) — dérivé
		$SEP_SPAN2, _          ; fin de portée (mm) — dérivé
		$SEP_FORMULA, _        ; formule de position ("" = libre)
		$SEP_FIELD_COUNT       ; nombre de champs

; --- Orientations ---
Global Const $SEP_ORIENT_V = 0 ; vertical   (ligne X = Pos, portée en Y)
Global Const $SEP_ORIENT_H = 1 ; horizontal (ligne Y = Pos, portée en X)

; --- Absence de groupe ---
Global Const $SEP_NO_GROUP = 0

; Nom d'affichage d'une orientation.
Func Separator_OrientName($iOrient)
	Return ($iOrient = $SEP_ORIENT_V) ? "vertical" : "horizontal"
EndFunc   ;==>Separator_OrientName
