#include-once
#include "Box.au3"
#include "Layers.au3"

; =============================================================================
; Project.au3 — Projet courant (niveaux 1-2 : données + gestion métier).
;
; Ce module POSSÈDE l'instance du projet ouvert : la boîte pour l'instant ;
; les séparateurs, layers et groupes s'y ajouteront aux étapes suivantes.
;
; Totalement indépendant de l'affichage : aucune GDI, aucune UI.
; Les mutations ne posent PAS le dirty flag de vue : c'est la responsabilité
; de l'appelant (UI) — le métier ignore qu'un affichage existe.
; =============================================================================

; --- Instance du projet courant ---
Global $g_aPrjBox[$BOX_FIELD_COUNT]
Global $g_aPrjLayers[$LAYERS_COUNT][$LAYER_FIELD_COUNT]

; -----------------------------------------------------------------------------
; Nouveau projet : crée automatiquement la boîte et les 30 layers par défaut.
; -----------------------------------------------------------------------------
Func Project_New()
	$g_aPrjBox = Box_CreateDefault()
	Layers_CreateDefaults($g_aPrjLayers)
EndFunc   ;==>Project_New

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
