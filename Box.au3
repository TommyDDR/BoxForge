#include-once

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
;   - Origine monde (0, 0) = coin haut-gauche EXTÉRIEUR de la boîte.
; Toutes les valeurs sont en millimètres.
; =============================================================================

; --- Champs de la structure Boîte ---
Global Enum $BOX_WIDTH, _          ; largeur extérieure (mm, axe X)
		$BOX_LENGTH, _             ; longueur extérieure (mm, axe Y)
		$BOX_HEIGHT, _             ; hauteur des parois (mm, axe Z)
		$BOX_THICKNESS, _          ; épaisseur du matériau des parois (mm)
		$BOX_FINGER_LEN, _         ; longueur des créneaux d'assemblage (mm)
		$BOX_FINGER_SPACING, _     ; espacement des créneaux (mm)
		$BOX_FIELD_COUNT           ; nombre de champs (taille du tableau)

; --- Valeurs par défaut d'un nouveau projet (cahier des charges) ---
Global Const $BOX_DEFAULT_WIDTH          = 400
Global Const $BOX_DEFAULT_LENGTH         = 600
Global Const $BOX_DEFAULT_HEIGHT         = 80
Global Const $BOX_DEFAULT_THICKNESS      = 8
Global Const $BOX_DEFAULT_FINGER_LEN     = 20
Global Const $BOX_DEFAULT_FINGER_SPACING = 40

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
	Return $aBox
EndFunc   ;==>Box_CreateDefault

; -----------------------------------------------------------------------------
; Validation métier : True si $fValue est acceptable pour le champ $iField,
; compte tenu des autres champs de la boîte.
; -----------------------------------------------------------------------------
Func Box_IsFieldValueValid(ByRef $aBox, $iField, $fValue)
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
; Zone intérieure de la boîte (délimitée par les parois).
; C'est dans cette zone que vivent les séparateurs et les sous-zones.
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
