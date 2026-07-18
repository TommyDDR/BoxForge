#include-once

; =============================================================================
; Layers.au3 — Structure de données des layers (niveau 1 : données).
;
; Un layer décrit un MATÉRIAU et ses paramètres d'usinage. Chaque séparateur
; référencera un layer par son index (0..29).
;
; La couleur sert UNIQUEMENT à l'affichage (cahier des charges) : elle ne
; participe jamais à la génération DXF.
;
; Représentation : tableau 2D [index layer][champ] à index nommés.
; Toutes les valeurs dimensionnelles sont en millimètres.
; =============================================================================

; --- Champs de la structure Layer ---
Global Enum $LAYER_COLOR, _        ; couleur d'affichage (0xRRGGBB)
		$LAYER_THICKNESS, _        ; épaisseur du matériau (mm)
		$LAYER_HEIGHT, _           ; hauteur du matériau (mm)
		$LAYER_FINGER_LEN, _       ; taille des créneaux (mm)
		$LAYER_FINGER_SPACING, _   ; espacement des créneaux (mm)
		$LAYER_FIELD_COUNT         ; nombre de champs

; --- Nombre de layers du projet (cahier des charges) ---
Global Const $LAYERS_COUNT = 30

; --- Valeurs par défaut d'un layer ---
Global Const $LAYER_DEFAULT_THICKNESS      = 3
Global Const $LAYER_DEFAULT_HEIGHT         = 60
Global Const $LAYER_DEFAULT_FINGER_LEN     = 20
Global Const $LAYER_DEFAULT_FINGER_SPACING = 40

; -----------------------------------------------------------------------------
; Nom d'affichage d'un layer : "Layer 00" .. "Layer 29".
; -----------------------------------------------------------------------------
Func Layers_Name($iIndex)
	Return StringFormat("Layer %02d", $iIndex)
EndFunc   ;==>Layers_Name

; -----------------------------------------------------------------------------
; Couleur par défaut d'un layer : palette de 30 couleurs distinctes
; (10 teintes × 3 niveaux de luminosité). Affichage uniquement.
; -----------------------------------------------------------------------------
Func Layers_DefaultColor($iIndex)
	Local Static $aPalette[30] = [ _
			0xE05252, 0xE0A052, 0xD8D852, 0x7ED852, 0x52D89A, _ ; vifs
			0x52C8D8, 0x5285E0, 0x8F52E0, 0xD852D0, 0xE05285, _
			0xF08C8C, 0xF0C48C, 0xE8E88C, 0xACE88C, 0x8CE8C2, _ ; clairs
			0x8CDCE8, 0x8CB0F0, 0xB88CF0, 0xE88CE4, 0xF08CB0, _
			0x9E3A3A, 0x9E713A, 0x97973A, 0x58973A, 0x3A976C, _ ; sombres
			0x3A8C97, 0x3A5D9E, 0x643A9E, 0x973A92, 0x9E3A5D]
	Return $aPalette[Mod($iIndex, 30)]
EndFunc   ;==>Layers_DefaultColor

; -----------------------------------------------------------------------------
; Initialise les 30 layers avec leurs valeurs par défaut.
; -----------------------------------------------------------------------------
Func Layers_CreateDefaults(ByRef $aLayers)
	For $i = 0 To $LAYERS_COUNT - 1
		$aLayers[$i][$LAYER_COLOR] = Layers_DefaultColor($i)
		$aLayers[$i][$LAYER_THICKNESS] = $LAYER_DEFAULT_THICKNESS
		$aLayers[$i][$LAYER_HEIGHT] = $LAYER_DEFAULT_HEIGHT
		$aLayers[$i][$LAYER_FINGER_LEN] = $LAYER_DEFAULT_FINGER_LEN
		$aLayers[$i][$LAYER_FINGER_SPACING] = $LAYER_DEFAULT_FINGER_SPACING
	Next
EndFunc   ;==>Layers_CreateDefaults

; -----------------------------------------------------------------------------
; Validation métier d'un champ de layer.
; -----------------------------------------------------------------------------
Func Layers_IsFieldValueValid($iField, $fValue)
	Switch $iField
		Case $LAYER_COLOR
			; Couleur : tout entier 0x000000..0xFFFFFF est acceptable.
			Return $fValue >= 0 And $fValue <= 0xFFFFFF
		Case Else
			; Toute dimension d'usinage est strictement positive.
			Return $fValue > 0
	EndSwitch
EndFunc   ;==>Layers_IsFieldValueValid
