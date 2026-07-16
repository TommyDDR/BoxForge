#include-once
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <WinAPI.au3>
#include "App.au3"
#include "Project.au3"

; =============================================================================
; UI.au3 — Fenêtre principale et disposition des zones (niveau 4 : UI).
;
; Disposition :
;   +--------------------------------+-----------+
;   |                                |           |
;   |        Canvas GDI+             | Propriétés|
;   |        (zone de dessin)        |           |
;   |                                |           |
;   +--------------------------------+           |
;   |        Layers                  |           |
;   +--------------------------------+-----------+
;
; Chaque zone est une GUI enfant : la disposition au redimensionnement se
; résume à déplacer 3 fenêtres, et chaque panneau gère ses propres contrôles.
;
; Ce module ne connaît PAS le renderer : lors d'un redimensionnement il lève
; simplement un drapeau ($g_bUiLayoutPending) que la boucle principale consomme
; pour réappliquer la disposition puis redimensionner les cibles de rendu.
; =============================================================================

; --- Dimensions de la disposition (pixels) ---
Global Const $UI_MAIN_START_W    = 1280
Global Const $UI_MAIN_START_H    = 800
Global Const $UI_PANEL_RIGHT_W   = 280  ; largeur du panneau Propriétés
Global Const $UI_PANEL_BOTTOM_H  = 150  ; hauteur du panneau Layers

; --- Couleurs de l'interface native (format 0xRRGGBB) ---
Global Const $UI_COLOR_MAIN_BG  = 0x1B1D21
Global Const $UI_COLOR_PANEL_BG = 0x24262B
Global Const $UI_COLOR_TEXT     = 0xD8D8D8
Global Const $UI_COLOR_TEXT_DIM = 0x8A8F98

; --- Fenêtres ---
Global $g_hUiMainGui        = 0
Global $g_hUiCanvasGui      = 0
Global $g_hUiPanelRightGui  = 0
Global $g_hUiPanelBottomGui = 0

; --- Taille courante du canvas (maintenue par UI_ApplyLayout) ---
Global $g_iUiCanvasW = 1
Global $g_iUiCanvasH = 1

; --- Drapeau "la disposition doit être réappliquée" (posé par WM_SIZE) ---
Global $g_bUiLayoutPending = False

; --- Contrôles du panneau Propriétés : section Boîte ---
Global $g_aidUiBoxInputs[$BOX_FIELD_COUNT]
Global $g_idUiBtnApplyBox = 0

; -----------------------------------------------------------------------------
; Création de la fenêtre principale et de ses trois zones.
; -----------------------------------------------------------------------------
Func UI_Create()
	; $WS_CLIPCHILDREN : le fond de la fenêtre principale ne repeint jamais
	; par-dessus les zones enfants (indispensable contre le scintillement).
	$g_hUiMainGui = GUICreate($APP_NAME & " " & $APP_VERSION, $UI_MAIN_START_W, $UI_MAIN_START_H, _
			-1, -1, BitOR($WS_OVERLAPPEDWINDOW, $WS_CLIPCHILDREN))
	GUISetBkColor($UI_COLOR_MAIN_BG, $g_hUiMainGui)

	; Zone de dessin : GUI enfant nue, entièrement repeinte par le renderer.
	$g_hUiCanvasGui = GUICreate("", 100, 100, 0, 0, $WS_CHILD, 0, $g_hUiMainGui)
	GUISetBkColor($UI_COLOR_MAIN_BG, $g_hUiCanvasGui)

	UI_CreatePanelRight()
	UI_CreatePanelBottom()

	; Messages fenêtre : anti-scintillement + suivi du redimensionnement.
	GUIRegisterMsg($WM_ERASEBKGND, "UI_OnEraseBkgnd")
	GUIRegisterMsg($WM_SIZE, "UI_OnSize")
	GUIRegisterMsg($WM_PAINT, "UI_OnPaint")

	UI_ApplyLayout()

	GUISetState(@SW_SHOW, $g_hUiCanvasGui)
	GUISetState(@SW_SHOW, $g_hUiPanelRightGui)
	GUISetState(@SW_SHOW, $g_hUiPanelBottomGui)
	GUISetState(@SW_SHOW, $g_hUiMainGui)
EndFunc   ;==>UI_Create

; -----------------------------------------------------------------------------
; Panneau de droite : Propriétés (contenu réel à l'étape "Sélection").
; -----------------------------------------------------------------------------
Func UI_CreatePanelRight()
	$g_hUiPanelRightGui = GUICreate("", $UI_PANEL_RIGHT_W, 100, 0, 0, $WS_CHILD, 0, $g_hUiMainGui)
	GUISetBkColor($UI_COLOR_PANEL_BG, $g_hUiPanelRightGui)

	Local $idTitle = GUICtrlCreateLabel("Propriétés", 12, 10, $UI_PANEL_RIGHT_W - 24, 20)
	GUICtrlSetColor($idTitle, $UI_COLOR_TEXT)
	GUICtrlSetBkColor($idTitle, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlSetFont($idTitle, 10, 700)

	UI_CreateBoxSection(42)
EndFunc   ;==>UI_CreatePanelRight

; -----------------------------------------------------------------------------
; Section "Boîte" du panneau Propriétés : les 6 champs modifiables + Appliquer.
; Création générique pilotée par un tableau de libellés indexé comme la
; structure Boîte (aucun code dupliqué par champ).
; -----------------------------------------------------------------------------
Func UI_CreateBoxSection($iYStart)
	Local $idSection = GUICtrlCreateLabel("Boîte", 12, $iYStart, $UI_PANEL_RIGHT_W - 24, 18)
	GUICtrlSetColor($idSection, $UI_COLOR_TEXT)
	GUICtrlSetBkColor($idSection, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlSetFont($idSection, 9, 700)

	; Libellés indexés EXACTEMENT comme les champs de la structure Boîte.
	Local $aLabels[$BOX_FIELD_COUNT]
	$aLabels[$BOX_WIDTH] = "Largeur X (mm)"
	$aLabels[$BOX_LENGTH] = "Longueur Y (mm)"
	$aLabels[$BOX_HEIGHT] = "Hauteur (mm)"
	$aLabels[$BOX_THICKNESS] = "Épaisseur (mm)"
	$aLabels[$BOX_FINGER_LEN] = "Créneau : long. (mm)"
	$aLabels[$BOX_FINGER_SPACING] = "Créneau : espac. (mm)"

	Local $iY = $iYStart + 26
	For $i = 0 To $BOX_FIELD_COUNT - 1
		Local $idLabel = GUICtrlCreateLabel($aLabels[$i], 12, $iY + 3, 136, 18)
		GUICtrlSetColor($idLabel, $UI_COLOR_TEXT_DIM)
		GUICtrlSetBkColor($idLabel, $GUI_BKCOLOR_TRANSPARENT)
		$g_aidUiBoxInputs[$i] = GUICtrlCreateInput("", 156, $iY, 96, 22)
		$iY += 28
	Next

	$g_idUiBtnApplyBox = GUICtrlCreateButton("Appliquer", 156, $iY + 4, 96, 26)
EndFunc   ;==>UI_CreateBoxSection

; Recharge les champs depuis le modèle (source de vérité : le métier).
Func UI_RefreshBoxInputs()
	For $i = 0 To $BOX_FIELD_COUNT - 1
		GUICtrlSetData($g_aidUiBoxInputs[$i], Project_BoxGet($i))
	Next
EndFunc   ;==>UI_RefreshBoxInputs

; Applique les saisies au modèle : chaque champ passe par la validation
; métier ; les valeurs refusées sont simplement réaffichées telles quelles.
Func UI_ApplyBoxInputs()
	For $i = 0 To $BOX_FIELD_COUNT - 1
		Project_BoxSet($i, Number(GUICtrlRead($g_aidUiBoxInputs[$i])))
	Next
	UI_RefreshBoxInputs() ; réaffiche les valeurs réellement acceptées
	App_InvalidateView()
EndFunc   ;==>UI_ApplyBoxInputs

; -----------------------------------------------------------------------------
; Dispatch des événements de contrôles (appelé par la boucle principale).
; Retourne True si l'événement a été consommé.
; -----------------------------------------------------------------------------
Func UI_HandleGuiEvent($iMsg)
	If $iMsg = $g_idUiBtnApplyBox Then
		UI_ApplyBoxInputs()
		Return True
	EndIf
	Return False
EndFunc   ;==>UI_HandleGuiEvent

; -----------------------------------------------------------------------------
; Panneau du bas : Layers (contenu réel à l'étape "Layers").
; -----------------------------------------------------------------------------
Func UI_CreatePanelBottom()
	$g_hUiPanelBottomGui = GUICreate("", 100, $UI_PANEL_BOTTOM_H, 0, 0, $WS_CHILD, 0, $g_hUiMainGui)
	GUISetBkColor($UI_COLOR_PANEL_BG, $g_hUiPanelBottomGui)

	Local $idTitle = GUICtrlCreateLabel("Layers", 12, 8, 200, 20)
	GUICtrlSetColor($idTitle, $UI_COLOR_TEXT)
	GUICtrlSetBkColor($idTitle, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlSetFont($idTitle, 10, 700)
EndFunc   ;==>UI_CreatePanelBottom

; -----------------------------------------------------------------------------
; Applique la disposition : positionne les 3 zones dans la zone cliente.
; Appelée à la création puis à chaque redimensionnement (via la boucle).
; -----------------------------------------------------------------------------
Func UI_ApplyLayout()
	Local $aClient = WinGetClientSize($g_hUiMainGui)
	If @error Then Return
	; Fenêtre minimisée : zone cliente nulle, on ne touche à rien.
	If $aClient[0] < 1 Or $aClient[1] < 1 Then Return

	Local $iCanvasW = $aClient[0] - $UI_PANEL_RIGHT_W
	Local $iCanvasH = $aClient[1] - $UI_PANEL_BOTTOM_H
	If $iCanvasW < 1 Then $iCanvasW = 1
	If $iCanvasH < 1 Then $iCanvasH = 1

	_WinAPI_MoveWindow($g_hUiCanvasGui, 0, 0, $iCanvasW, $iCanvasH)
	_WinAPI_MoveWindow($g_hUiPanelRightGui, $iCanvasW, 0, $UI_PANEL_RIGHT_W, $aClient[1])
	_WinAPI_MoveWindow($g_hUiPanelBottomGui, 0, $iCanvasH, $iCanvasW, $UI_PANEL_BOTTOM_H)

	$g_iUiCanvasW = $iCanvasW
	$g_iUiCanvasH = $iCanvasH
EndFunc   ;==>UI_ApplyLayout

; --- Accesseurs -------------------------------------------------------------
Func UI_GetCanvasHwnd()
	Return $g_hUiCanvasGui
EndFunc   ;==>UI_GetCanvasHwnd

Func UI_GetCanvasW()
	Return $g_iUiCanvasW
EndFunc   ;==>UI_GetCanvasW

Func UI_GetCanvasH()
	Return $g_iUiCanvasH
EndFunc   ;==>UI_GetCanvasH

; Retourne True si un redimensionnement est en attente, et réarme le drapeau.
Func UI_ConsumeLayoutPending()
	If Not $g_bUiLayoutPending Then Return False
	$g_bUiLayoutPending = False
	Return True
EndFunc   ;==>UI_ConsumeLayoutPending

; -----------------------------------------------------------------------------
; Gestionnaires de messages fenêtre.
; Règle : un gestionnaire ne fait JAMAIS de travail lourd (pas de recréation de
; ressources ici) — il pose un drapeau que la boucle principale consomme.
; -----------------------------------------------------------------------------

; Anti-scintillement : le canvas est intégralement repeint par le renderer,
; on interdit à Windows d'en effacer le fond (cf. pratiques §2).
Func UI_OnEraseBkgnd($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam, $lParam
	If $hWnd = $g_hUiCanvasGui Then Return 1 ; "déjà effacé"
	Return $GUI_RUNDEFMSG
EndFunc   ;==>UI_OnEraseBkgnd

; Redimensionnement : on note simplement qu'il faudra réappliquer la disposition.
Func UI_OnSize($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam, $lParam
	If $hWnd = $g_hUiMainGui Then $g_bUiLayoutPending = True
	Return $GUI_RUNDEFMSG
EndFunc   ;==>UI_OnSize

; Le canvas vient d'être invalidé par Windows (fenêtre recouverte/découverte) :
; on demande une recomposition au prochain tour de boucle.
Func UI_OnPaint($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam, $lParam
	If $hWnd = $g_hUiCanvasGui Then App_InvalidateView()
	Return $GUI_RUNDEFMSG
EndFunc   ;==>UI_OnPaint
