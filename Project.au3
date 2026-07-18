#include-once
#include "Box.au3"
#include "Layers.au3"
#include "Separator.au3"

; =============================================================================
; Project.au3 — Projet courant (niveau 1 : instance des données).
;
; Ce module POSSÈDE l'instance du projet ouvert : boîte, layers, séparateurs.
; Il n'offre que des accès BRUTS (lecture, écriture validée, ajout/retrait) :
; la cohérence d'ensemble (sous-zones, contraintes d'écart, groupes) est la
; responsabilité du niveau 2 (Zones.au3) — toute mutation de séparateur doit
; passer par les fonctions Metier_* qui recalculent les données dérivées.
;
; Totalement indépendant de l'affichage : aucune GDI, aucune UI.
; Les mutations ne posent PAS le dirty flag de vue : c'est la responsabilité
; de l'appelant (UI) — le métier ignore qu'un affichage existe.
; =============================================================================

; --- Instance du projet courant ---
Global $g_aPrjBox[$BOX_FIELD_COUNT]
Global $g_aPrjLayers[$LAYERS_COUNT][$LAYER_FIELD_COUNT]
Global $g_aPrjSeps[0][$SEP_FIELD_COUNT]

; --- Origine de la boîte (coin bas-gauche INTÉRIEUR, monde) ---
; INVARIANT : (0,0) en dehors d'un drag de bord — l'origine monde est donc
; toujours le coin bas-gauche de l'intérieur de la boîte (le coin extérieur
; est en (−épaisseur, −épaisseur)). Pendant le drag d'un bord O/N, l'origine
; suit le curseur (coordonnées négatives permises) pour que le bord opposé
; reste visuellement fixe ; au relâchement, le métier recale tout en (0,0)
; (Metier_EndBoxResize). La persistance et l'export DXF ne voient JAMAIS
; d'origine non nulle.
Global $g_fPrjBoxOrgX = 0.0
Global $g_fPrjBoxOrgY = 0.0

; --- Compteurs d'identifiants (jamais réutilisés au sein d'un projet) ---
Global $g_iPrjSepNextId    = 1
Global $g_iPrjSepNextGroup = 1

; -----------------------------------------------------------------------------
; Nouveau projet : crée automatiquement la boîte et les 30 layers par défaut.
; -----------------------------------------------------------------------------
Func Project_New()
	$g_aPrjBox = Box_CreateDefault()
	Layers_CreateDefaults($g_aPrjLayers)
	Project_SepReset()
	$g_fPrjBoxOrgX = 0.0
	$g_fPrjBoxOrgY = 0.0
EndFunc   ;==>Project_New

; --- Origine et rectangles de la boîte -----------------------------------------
Func Project_BoxOrgX()
	Return $g_fPrjBoxOrgX
EndFunc   ;==>Project_BoxOrgX

Func Project_BoxOrgY()
	Return $g_fPrjBoxOrgY
EndFunc   ;==>Project_BoxOrgY

Func Project_BoxSetOrg($fX, $fY)
	$g_fPrjBoxOrgX = $fX
	$g_fPrjBoxOrgY = $fY
EndFunc   ;==>Project_BoxSetOrg

; Rectangle extérieur de la boîte (monde, mm) : l'origine étant le coin
; intérieur, l'extérieur déborde d'une épaisseur de chaque côté.
Func Project_BoxOuter(ByRef $fX1, ByRef $fY1, ByRef $fX2, ByRef $fY2)
	Local $fT = $g_aPrjBox[$BOX_THICKNESS]
	$fX1 = $g_fPrjBoxOrgX - $fT
	$fY1 = $g_fPrjBoxOrgY - $fT
	$fX2 = $fX1 + $g_aPrjBox[$BOX_WIDTH]
	$fY2 = $fY1 + $g_aPrjBox[$BOX_LENGTH]
EndFunc   ;==>Project_BoxOuter

; Rectangle intérieur de la boîte (monde, mm) : là où vivent les sous-zones.
; Son coin bas-gauche EST l'origine de la boîte (0,0 hors drag de bord).
Func Project_BoxInterior(ByRef $fX1, ByRef $fY1, ByRef $fX2, ByRef $fY2)
	$fX1 = $g_fPrjBoxOrgX
	$fY1 = $g_fPrjBoxOrgY
	$fX2 = $g_fPrjBoxOrgX + $g_aPrjBox[$BOX_WIDTH] - 2 * $g_aPrjBox[$BOX_THICKNESS]
	$fY2 = $g_fPrjBoxOrgY + $g_aPrjBox[$BOX_LENGTH] - 2 * $g_aPrjBox[$BOX_THICKNESS]
EndFunc   ;==>Project_BoxInterior

; --- Accès à la boîte ---------------------------------------------------------
Func Project_BoxGet($iField)
	Return $g_aPrjBox[$iField]
EndFunc   ;==>Project_BoxGet

; Modifie un champ de la boîte après validation métier.
; Retourne True si la valeur a été acceptée, False sinon (valeur inchangée).
Func Project_BoxSet($iField, $fValue)
	If Not Box_IsFieldValueValid($g_aPrjBox, $iField, $fValue) Then Return False
	$g_aPrjBox[$iField] = $fValue
	Return True
EndFunc   ;==>Project_BoxSet

; --- Accès aux layers ---------------------------------------------------------
Func Project_LayerGet($iLayer, $iField)
	Return $g_aPrjLayers[$iLayer][$iField]
EndFunc   ;==>Project_LayerGet

; Modifie un champ d'un layer après validation métier.
; Retourne True si la valeur a été acceptée, False sinon (valeur inchangée).
Func Project_LayerSet($iLayer, $iField, $fValue)
	If $iLayer < 0 Or $iLayer >= $LAYERS_COUNT Then Return False
	If Not Layers_IsFieldValueValid($iField, $fValue) Then Return False
	$g_aPrjLayers[$iLayer][$iField] = $fValue
	Return True
EndFunc   ;==>Project_LayerSet

; --- Accès aux séparateurs ----------------------------------------------------
; ATTENTION : accès BRUTS. Toute mutation doit passer par Metier_* (Zones.au3)
; qui recalcule sous-zones/portées/intersections et applique les contraintes.

; Vide la liste des séparateurs et réarme les compteurs d'identifiants.
Func Project_SepReset()
	ReDim $g_aPrjSeps[0][$SEP_FIELD_COUNT]
	$g_iPrjSepNextId = 1
	$g_iPrjSepNextGroup = 1
EndFunc   ;==>Project_SepReset

Func Project_SepCount()
	Return UBound($g_aPrjSeps)
EndFunc   ;==>Project_SepCount

Func Project_SepGet($iRow, $iField)
	Return $g_aPrjSeps[$iRow][$iField]
EndFunc   ;==>Project_SepGet

Func Project_SepSet($iRow, $iField, $vValue)
	$g_aPrjSeps[$iRow][$iField] = $vValue
EndFunc   ;==>Project_SepSet

; Longueur du segment (mm) — donnée dérivée maintenue par Zones_Rebuild.
Func Project_SepLength($iRow)
	Return $g_aPrjSeps[$iRow][$SEP_SPAN2] - $g_aPrjSeps[$iRow][$SEP_SPAN1]
EndFunc   ;==>Project_SepLength

; Index de ligne d'un séparateur par identifiant. -1 si absent.
; (Les index de ligne bougent lors des suppressions : ne JAMAIS conserver un
;  index entre deux mutations — conserver l'Id.)
Func Project_SepFindById($iId)
	For $i = 0 To UBound($g_aPrjSeps) - 1
		If $g_aPrjSeps[$i][$SEP_ID] = $iId Then Return $i
	Next
	Return -1
EndFunc   ;==>Project_SepFindById

; Ajoute un séparateur et retourne son identifiant.
; Les portées (Span1/Span2) seront calculées par le prochain Zones_Rebuild.
Func Project_SepAdd($iGroup, $iOrient, $fPos, $fAnchor, $iLayer)
	Local $iRow = UBound($g_aPrjSeps)
	ReDim $g_aPrjSeps[$iRow + 1][$SEP_FIELD_COUNT]
	$g_aPrjSeps[$iRow][$SEP_ID] = $g_iPrjSepNextId
	$g_aPrjSeps[$iRow][$SEP_GROUP] = $iGroup
	$g_aPrjSeps[$iRow][$SEP_ORIENT] = $iOrient
	$g_aPrjSeps[$iRow][$SEP_POS] = $fPos
	$g_aPrjSeps[$iRow][$SEP_ANCHOR] = $fAnchor
	$g_aPrjSeps[$iRow][$SEP_LAYER] = $iLayer
	$g_aPrjSeps[$iRow][$SEP_SPAN1] = $fPos
	$g_aPrjSeps[$iRow][$SEP_SPAN2] = $fPos
	$g_aPrjSeps[$iRow][$SEP_FORMULA] = "" ; position libre par défaut
	$g_iPrjSepNextId += 1
	Return $g_aPrjSeps[$iRow][$SEP_ID]
EndFunc   ;==>Project_SepAdd

; Supprime la ligne $iRow (décale les suivantes : l'ordre de création,
; porté par l'ordre des lignes, est préservé).
Func Project_SepDeleteRow($iRow)
	Local $iCount = UBound($g_aPrjSeps)
	If $iRow < 0 Or $iRow >= $iCount Then Return
	For $i = $iRow To $iCount - 2
		For $j = 0 To $SEP_FIELD_COUNT - 1
			$g_aPrjSeps[$i][$j] = $g_aPrjSeps[$i + 1][$j]
		Next
	Next
	ReDim $g_aPrjSeps[$iCount - 1][$SEP_FIELD_COUNT]
EndFunc   ;==>Project_SepDeleteRow

; Alloue un identifiant de groupe (création globale SHIFT).
Func Project_SepAllocGroupId()
	Local $iGroup = $g_iPrjSepNextGroup
	$g_iPrjSepNextGroup += 1
	Return $iGroup
EndFunc   ;==>Project_SepAllocGroupId

; Nombre de segments appartenant au groupe $iGroup.
Func Project_SepGroupSize($iGroup)
	If $iGroup = $SEP_NO_GROUP Then Return 0
	Local $iCount = 0
	For $i = 0 To UBound($g_aPrjSeps) - 1
		If $g_aPrjSeps[$i][$SEP_GROUP] = $iGroup Then $iCount += 1
	Next
	Return $iCount
EndFunc   ;==>Project_SepGroupSize
