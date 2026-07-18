#include-once
#include "Separator.au3"

; =============================================================================
; Box.au3 — Structure de données de la boîte (niveau 1 : données).
;
; Aucune GDI, aucun DXF, aucune UI : uniquement la structure et ses règles
; de validité propres.
;
; Représentation : tableau à index nommés (Enum) — accès en ~0,35 µs, aucun
; coût d'abstraction, sérialisation triviale.
;
; Repère : vue de dessus du tiroir.
;   - Width  → dimension extérieure sur l'axe X (horizontal écran)
;   - Length → dimension extérieure sur l'axe Y (vertical écran)
;   - Origine monde (0, 0) = coin bas-gauche INTÉRIEUR de la boîte
;     (le coin extérieur est en (−épaisseur, −épaisseur)).
; Toutes les valeurs sont en millimètres.
; =============================================================================

; --- Champs de la structure Boîte ---
; $BOX_MAIN_SEP_ORIENT : orientation ($SEP_ORIENT_V/_H) qui reçoit l'encoche
; HAUTE aux croisements de séparateurs (cf. DXF.au3) — réglage "menu
; uniquement" (cf. UI.au3), absent du panneau Propriétés.
Global Enum $BOX_WIDTH, _          ; largeur extérieure (mm, axe X)
		$BOX_LENGTH, _             ; longueur extérieure (mm, axe Y)
		$BOX_HEIGHT, _             ; hauteur des parois (mm, axe Z)
		$BOX_THICKNESS, _          ; épaisseur du matériau des parois (mm)
		$BOX_FINGER_LEN, _         ; longueur des créneaux d'assemblage (mm)
		$BOX_FINGER_SPACING, _     ; espacement des créneaux (mm)
		$BOX_MAIN_SEP_ORIENT, _    ; orientation qui reçoit l'encoche haute
		$BOX_FIELD_COUNT           ; nombre de champs (taille du tableau)

; --- Valeurs par défaut d'un nouveau projet (cahier des charges) ---
Global Const $BOX_DEFAULT_WIDTH          = 400
Global Const $BOX_DEFAULT_LENGTH         = 600
Global Const $BOX_DEFAULT_HEIGHT         = 80
Global Const $BOX_DEFAULT_THICKNESS      = 8
Global Const $BOX_DEFAULT_FINGER_LEN     = 20
Global Const $BOX_DEFAULT_FINGER_SPACING = 40
Global Const $BOX_DEFAULT_MAIN_SEP_ORIENT = $SEP_ORIENT_H ; reproduit le comportement historique

; -----------------------------------------------------------------------------
; Crée une boîte avec les valeurs par défaut.
; -----------------------------------------------------------------------------
Func Box_CreateDefault()
	Local $aBox[$BOX_FIELD_COUNT]
	$aBox[$BOX_WIDTH] = $BOX_DEFAULT_WIDTH
	$aBox[$BOX_LENGTH] = $BOX_DEFAULT_LENGTH
	$aBox[$BOX_HEIGHT] = $BOX_DEFAULT_HEIGHT
	$aBox[$BOX_THICKNESS] = $BOX_DEFAULT_THICKNESS
	$aBox[$BOX_FINGER_LEN] = $BOX_DEFAULT_FINGER_LEN
	$aBox[$BOX_FINGER_SPACING] = $BOX_DEFAULT_FINGER_SPACING
	$aBox[$BOX_MAIN_SEP_ORIENT] = $BOX_DEFAULT_MAIN_SEP_ORIENT
	Return $aBox
EndFunc   ;==>Box_CreateDefault

; -----------------------------------------------------------------------------
; Validation métier : True si $fValue est acceptable pour le champ $iField,
; compte tenu des autres champs de la boîte.
; -----------------------------------------------------------------------------
Func Box_IsFieldValueValid(ByRef $aBox, $iField, $fValue)
	; Cas particulier : ce n'est pas une dimension — 0 ($SEP_ORIENT_V) est
	; une valeur légitime, donc traité AVANT le garde de positivité ci-dessous.
	If $iField = $BOX_MAIN_SEP_ORIENT Then
		Return $fValue = $SEP_ORIENT_V Or $fValue = $SEP_ORIENT_H
	EndIf

	; Règle commune : toute dimension est strictement positive.
	If $fValue <= 0 Then Return False

	Switch $iField
		Case $BOX_THICKNESS
			; Les deux parois opposées ne peuvent pas se rejoindre.
			Local $fMinDim = ($aBox[$BOX_WIDTH] < $aBox[$BOX_LENGTH]) ? $aBox[$BOX_WIDTH] : $aBox[$BOX_LENGTH]
			Return $fValue < $fMinDim / 2
		Case $BOX_WIDTH, $BOX_LENGTH
			; La dimension doit laisser un intérieur non vide.
			Return $fValue > 2 * $aBox[$BOX_THICKNESS]
	EndSwitch
	Return True
EndFunc   ;==>Box_IsFieldValueValid

; -----------------------------------------------------------------------------
; Zone intérieure de la boîte (délimitée par les parois), RELATIVE au coin
; extérieur. C'est dans cette zone que vivent les séparateurs et les
; sous-zones. (Pour les coordonnées monde, voir Project_BoxInterior.)
; -----------------------------------------------------------------------------
Func Box_InteriorX(ByRef $aBox)
	Return $aBox[$BOX_THICKNESS]
EndFunc   ;==>Box_InteriorX

Func Box_InteriorY(ByRef $aBox)
	Return $aBox[$BOX_THICKNESS]
EndFunc   ;==>Box_InteriorY

Func Box_InteriorW(ByRef $aBox)
	Return $aBox[$BOX_WIDTH] - 2 * $aBox[$BOX_THICKNESS]
EndFunc   ;==>Box_InteriorW

Func Box_InteriorH(ByRef $aBox)
	Return $aBox[$BOX_LENGTH] - 2 * $aBox[$BOX_THICKNESS]
EndFunc   ;==>Box_InteriorH
