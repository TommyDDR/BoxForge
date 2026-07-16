#include-once
#include "Project.au3"

; =============================================================================
; Selection.au3 — État de sélection et hit-test (niveau 2 : métier/interaction).
;
; Aucune GDI, aucune UI : ce module maintient un état (séparateur sélectionné,
; sous-zone survolée) et sait tester ce que touche un point monde. Le renderer
; LIT cet état pour dessiner différemment ; l'UI le mute via les clics.
;
; Règle des groupes : sélectionner un segment sélectionne TOUT son groupe
; (les segments liés se comportent comme un seul objet). L'état ne stocke que
; l'identifiant du segment cliqué ; l'appartenance au groupe est résolue à la
; lecture (Selection_IsRowSelected), jamais dupliquée.
;
; On stocke des IDENTIFIANTS, jamais des index de ligne : les index bougent
; lors des suppressions.
; =============================================================================

; --- État ---
Global $g_iSelSepId     = -1 ; identifiant du séparateur sélectionné (-1 = aucun)
Global $g_iSelHoverZone = -1 ; index de la sous-zone survolée (-1 = aucune)

; --- Sélection ----------------------------------------------------------------
Func Selection_GetId()
	Return $g_iSelSepId
EndFunc   ;==>Selection_GetId

Func Selection_HasSelection()
	Return $g_iSelSepId <> -1
EndFunc   ;==>Selection_HasSelection

; Sélectionne un séparateur par identifiant. Retourne True si l'état a changé.
Func Selection_Set($iId)
	If $g_iSelSepId = $iId Then Return False
	$g_iSelSepId = $iId
	Return True
EndFunc   ;==>Selection_Set

Func Selection_Clear()
	Return Selection_Set(-1)
EndFunc   ;==>Selection_Clear

; -----------------------------------------------------------------------------
; True si la ligne $iRow est sélectionnée, directement ou via son groupe.
; Utilisé par le renderer pour le dessin différencié.
; -----------------------------------------------------------------------------
Func Selection_IsRowSelected($iRow)
	If $g_iSelSepId = -1 Then Return False
	If Project_SepGet($iRow, $SEP_ID) = $g_iSelSepId Then Return True

	; Même groupe que le segment sélectionné ?
	Local $iSelRow = Project_SepFindById($g_iSelSepId)
	If $iSelRow = -1 Then Return False
	Local $iGroup = Project_SepGet($iSelRow, $SEP_GROUP)
	If $iGroup = $SEP_NO_GROUP Then Return False
	Return Project_SepGet($iRow, $SEP_GROUP) = $iGroup
EndFunc   ;==>Selection_IsRowSelected

; -----------------------------------------------------------------------------
; Hit-test : identifiant du séparateur touché par le point monde ($fWx, $fWy),
; ou -1. La cible est le rectangle réel du segment (épaisseur du layer) élargi
; d'une tolérance $fTolMm (la tolérance écran, convertie en mm par l'appelant,
; garde une visée confortable à tout zoom).
; Parcours à REBOURS : à recouvrement égal, le dernier créé — dessiné au-dessus
; — gagne, en cohérence avec ce que voit l'utilisateur.
; -----------------------------------------------------------------------------
Func Selection_HitTest($fWx, $fWy, $fTolMm)
	For $i = Project_SepCount() - 1 To 0 Step -1
		Local $fHalf = Project_LayerGet(Project_SepGet($i, $SEP_LAYER), $LAYER_THICKNESS) / 2
		If $fHalf < $fTolMm Then $fHalf = $fTolMm

		Local $fPos = Project_SepGet($i, $SEP_POS)
		Local $fS1 = Project_SepGet($i, $SEP_SPAN1) - $fTolMm
		Local $fS2 = Project_SepGet($i, $SEP_SPAN2) + $fTolMm

		If Project_SepGet($i, $SEP_ORIENT) = $SEP_ORIENT_V Then
			If Abs($fWx - $fPos) <= $fHalf And $fWy >= $fS1 And $fWy <= $fS2 Then Return Project_SepGet($i, $SEP_ID)
		Else
			If Abs($fWy - $fPos) <= $fHalf And $fWx >= $fS1 And $fWx <= $fS2 Then Return Project_SepGet($i, $SEP_ID)
		EndIf
	Next
	Return -1
EndFunc   ;==>Selection_HitTest

; --- Sous-zone survolée (retour visuel pour la création) -----------------------

; Retourne True si la sous-zone survolée a changé (l'appelant invalide la vue).
Func Selection_SetHoverZone($iZone)
	If $g_iSelHoverZone = $iZone Then Return False
	$g_iSelHoverZone = $iZone
	Return True
EndFunc   ;==>Selection_SetHoverZone

Func Selection_GetHoverZone()
	Return $g_iSelHoverZone
EndFunc   ;==>Selection_GetHoverZone
