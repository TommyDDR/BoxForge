#include-once
#include "Project.au3"
#include "Zones.au3"
#include "Selection.au3"

; =============================================================================
; Undo.au3 — Historique Annuler/Rétablir (Ctrl+Z / Ctrl+Y), par instantanés
; complets du projet (niveau 2 : s'appuie sur Project.au3/Zones.au3, aucune UI).
;
; Approche : plutôt que de modéliser l'inverse de chaque opération métier
; (déplacement, création, formule, redimensionnement de boîte…), chaque
; action utilisateur pousse un INSTANTANÉ COMPLET du projet — PRIS AVANT LA
; MODIFICATION — sur une pile ; Annuler restaure ce sommet et bascule l'état
; courant vers la pile Rétablir (et réciproquement). Les tableaux AutoIt sont
; copiés PAR VALEUR, y compris imbriqués (un tableau stocké comme élément d'un
; autre tableau est une copie indépendante) : chaque instantané est isolé des
; mutations ultérieures du modèle.
;
; Granularité : UNE action utilisateur = UN instantané, jamais un par pas
; intermédiaire (frappe clavier, pas de glisser) :
;   - saisie dans un champ suivi (Box/Layer/Position) → Undo_Arm() à la prise
;     de focus (Input.au3), puis Undo_CaptureIfArmed() juste avant CHAQUE
;     écriture effective du modèle (aperçu en direct ou bouton Appliquer) —
;     seule la PREMIÈRE de la session pousse réellement un instantané ;
;   - action ponctuelle (créer, glisser, supprimer, choix de couleur/layer,
;     séparateur principal…) → Undo_PushSnapshot() direct, une fois, au début
;     du geste (ex. clic initial d'un glisser — pas à chaque pas de souris).
; =============================================================================

Global $g_aUndoStack[0]
Global $g_aRedoStack[0]
Global Const $UNDO_MAX_DEPTH = 200

; --- Armement différé (cf. saisie dans un champ suivi, ci-dessus) ---
Global $g_bUndoArmed = False

Func Undo_Arm()
	$g_bUndoArmed = True
EndFunc   ;==>Undo_Arm

Func Undo_Disarm()
	$g_bUndoArmed = False
EndFunc   ;==>Undo_Disarm

; À appeler juste AVANT chaque écriture effective du modèle déclenchée par une
; saisie utilisateur : empile l'état courant UNE SEULE fois par armement
; (cf. Undo_Arm), puis désarme — les écritures suivantes de la même session
; n'empilent plus rien.
Func Undo_CaptureIfArmed()
	If Not $g_bUndoArmed Then Return
	$g_bUndoArmed = False
	Undo_PushSnapshot()
EndFunc   ;==>Undo_CaptureIfArmed

; --- Capture / restauration d'un instantané ----------------------------------

Func _Undo_Capture()
	Local $aSnap[7]
	$aSnap[0] = $g_aPrjBox
	$aSnap[1] = $g_aPrjLayers
	$aSnap[2] = $g_aPrjSeps
	$aSnap[3] = $g_iPrjSepNextId
	$aSnap[4] = $g_iPrjSepNextGroup
	Local $aOrg[2] = [$g_fPrjBoxOrgX, $g_fPrjBoxOrgY]
	$aSnap[5] = $aOrg
	; Sélection : sans elle, Annuler la CRÉATION d'un séparateur (qui vide la
	; sélection, son id disparaissant) puis Rétablir le recréerait DÉSÉLECTIONNÉ
	; — le panneau Séparateur resterait fermé alors que l'utilisateur s'attend
	; à retrouver exactement l'état d'avant (sélection comprise).
	$aSnap[6] = Selection_GetId()
	Return $aSnap
EndFunc   ;==>_Undo_Capture

; Restaure un instantané : les données SOURCES sont remplacées, puis les
; données DÉRIVÉES (sous-zones, portées, intersections) sont recalculées —
; jamais restaurées telles quelles (même principe que ProjectIO_LoadFrom).
Func _Undo_Restore($aSnap)
	$g_aPrjBox = $aSnap[0]
	$g_aPrjLayers = $aSnap[1]
	$g_aPrjSeps = $aSnap[2]
	$g_iPrjSepNextId = $aSnap[3]
	$g_iPrjSepNextGroup = $aSnap[4]
	Local $aOrg = $aSnap[5]
	Project_BoxSetOrg($aOrg[0], $aOrg[1])
	Zones_Rebuild()
	Metier_ApplyFormulas() ; par sécurité, même principe que ProjectIO_LoadFrom

	; La sélection capturée peut référencer un id absent de CET instantané
	; (ex. remonter avant sa création) : dans ce cas, pas de sélection.
	Local $iSelId = $aSnap[6]
	If $iSelId <> -1 And Project_SepFindById($iSelId) = -1 Then $iSelId = -1
	Selection_Set($iSelId)
EndFunc   ;==>_Undo_Restore

; --- Piles --------------------------------------------------------------------

; Vide les deux piles : plus rien à annuler/rétablir avant ce point (nouveau
; projet, chargement — cf. UI_AfterProjectReplaced). Désarme aussi une
; éventuelle capture différée en attente (cf. Undo_Arm) : elle référencerait
; un projet qui n'existe plus.
Func Undo_Reset()
	ReDim $g_aUndoStack[0]
	ReDim $g_aRedoStack[0]
	Undo_Disarm()
EndFunc   ;==>Undo_Reset

; Empile l'état ACTUEL (donc : avant la modification sur le point d'être
; appliquée par l'appelant) sur la pile Annuler, et vide la pile Rétablir —
; toute nouvelle action rend l'ancien "futur rétabli" caduc (convention
; standard undo/redo).
Func Undo_PushSnapshot()
	Undo_PushCaptured(_Undo_Capture())
EndFunc   ;==>Undo_PushSnapshot

; Capture explicite SANS empiler : utile quand l'appelant doit d'abord savoir
; si son action va réussir avant de décider d'empiler (ex. création d'un
; séparateur, qui peut échouer si la sous-zone visée est trop étroite — pas
; d'entrée Annuler pour un clic qui n'a rien changé). Combiner avec
; Undo_PushCaptured une fois le succès confirmé.
Func Undo_CaptureNow()
	Return _Undo_Capture()
EndFunc   ;==>Undo_CaptureNow

; Empile un instantané déjà capturé (cf. Undo_CaptureNow) — même effet que
; Undo_PushSnapshot, sans re-capturer l'état courant (qui a pu changer entre
; la capture et cet appel).
Func Undo_PushCaptured($aSnap)
	Local $iN = UBound($g_aUndoStack)
	ReDim $g_aUndoStack[$iN + 1]
	$g_aUndoStack[$iN] = $aSnap

	; Garde-fou mémoire : purge le plus ancien instantané au-delà de la
	; profondeur max (décalage O(n), rare — seulement au-delà de la limite).
	If $iN + 1 > $UNDO_MAX_DEPTH Then
		For $i = 0 To $iN - 1
			$g_aUndoStack[$i] = $g_aUndoStack[$i + 1]
		Next
		ReDim $g_aUndoStack[$UNDO_MAX_DEPTH]
	EndIf

	ReDim $g_aRedoStack[0]
EndFunc   ;==>Undo_PushCaptured

Func Undo_CanUndo()
	Return UBound($g_aUndoStack) > 0
EndFunc   ;==>Undo_CanUndo

Func Undo_CanRedo()
	Return UBound($g_aRedoStack) > 0
EndFunc   ;==>Undo_CanRedo

; Annule la dernière action : empile l'état courant sur Rétablir, restaure le
; sommet de la pile Annuler. Retourne True si une action a bien été annulée
; (False : pile vide, rien à faire).
Func Undo_Undo()
	If Not Undo_CanUndo() Then Return False
	Undo_Disarm() ; une capture différée en attente n'a plus de sens après un saut dans l'historique

	Local $iN = UBound($g_aUndoStack) - 1
	Local $aPrev = $g_aUndoStack[$iN]
	ReDim $g_aUndoStack[$iN]

	Local $iR = UBound($g_aRedoStack)
	ReDim $g_aRedoStack[$iR + 1]
	$g_aRedoStack[$iR] = _Undo_Capture()

	_Undo_Restore($aPrev)
	Return True
EndFunc   ;==>Undo_Undo

; Rétablit la dernière action annulée. Retourne True si une action a bien été
; rétablie (False : pile vide, rien à faire).
Func Undo_Redo()
	If Not Undo_CanRedo() Then Return False
	Undo_Disarm()

	Local $iN = UBound($g_aRedoStack) - 1
	Local $aNext = $g_aRedoStack[$iN]
	ReDim $g_aRedoStack[$iN]

	Local $iU = UBound($g_aUndoStack)
	ReDim $g_aUndoStack[$iU + 1]
	$g_aUndoStack[$iU] = _Undo_Capture()

	_Undo_Restore($aNext)
	Return True
EndFunc   ;==>Undo_Redo
