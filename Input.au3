#include-once
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <WinAPI.au3>
#include <Misc.au3>
#include "App.au3"
#include "Camera.au3"
#include "Zones.au3"
#include "Selection.au3"
#include "UI.au3"

; =============================================================================
; Input.au3 — Entrées souris/clavier du canvas (niveau 4 : UI).
;
; Rôle : traduire les messages Windows bruts en actions métier (création,
; sélection de séparateurs) ou de vue (caméra).
;
; Affectation des boutons (cf. cahier des charges) :
;   - molette            → zoom centré sur le curseur
;   - drag bouton milieu → pan de la caméra
;   - clic gauche        → sur un séparateur : sélection ;
;                          dans une sous-zone : création d'un séparateur
;                            vertical ; CTRL = horizontal ; SHIFT = global
;                            (traverse toutes les sous-zones, segments liés) ;
;                          le séparateur créé est sélectionné.
;   - clic droit         → sélection uniquement (jamais de création)
;   - Suppr              → supprime le séparateur sélectionné (et son groupe)
;   - Échap              → désélectionne
;
; Règle : un gestionnaire de message ne fait JAMAIS de travail lourd — il met
; à jour un état léger et pose le dirty flag ; le rendu a lieu dans la boucle
; principale. (Le recalcul des sous-zones — quelques dizaines de rectangles —
; reste négligeable à l'échelle d'un clic.)
; =============================================================================

; --- Modificateurs clavier packés dans wParam des messages souris ---
Global Const $INP_MK_SHIFT   = 0x0004
Global Const $INP_MK_CONTROL = 0x0008

; --- Tolérance de visée (pixels écran, convertie en mm selon le zoom) ---
Global Const $INP_PICK_TOL_PX = 4

; --- Codes de touches surveillées par le polling clavier ---
Global Const $INP_VK_ESCAPE = "1B"
Global Const $INP_VK_DELETE = "2E"

; --- État du pan en cours ---
Global $g_bInpPanning = False
Global $g_iInpLastX   = 0 ; dernière position souris (client canvas)
Global $g_iInpLastY   = 0

; --- État du drag de séparateur en cours ---
Global $g_iInpDragSepId = -1  ; identifiant du séparateur déplacé (-1 = aucun)
Global $g_fInpDragGrab  = 0.0 ; écart curseur→position au moment de la prise (mm)
                              ; conservé pendant tout le drag : pas de "saut"
                              ; du séparateur sous le curseur

; --- État du drag de bord(s) de la boîte (redimensionnement) ---
; Un bord seul → un axe ; un COIN → les deux axes à la fois.
Global $g_iInpDragEdgeX = -1  ; $METIER_EDGE_W / _E en cours de drag (-1 = aucun)
Global $g_iInpDragEdgeY = -1  ; $METIER_EDGE_N / _S en cours de drag (-1 = aucun)

; --- Curseur de survol courant (évite de re-poser le même curseur) ---
Global $g_iInpCursor = -1     ; -1 = défaut, sinon id GUISetCursor (11/13)

; --- Polling clavier : handle user32 partagé + états précédents (détection de
;     front montant : une action par appui, pas une par tour de boucle) ---
Global $g_hInpUser32  = 0
Global $g_bInpPrevDel = False
Global $g_bInpPrevEsc = False

; -----------------------------------------------------------------------------
; Enregistrement des messages souris et ouverture de user32 (polling clavier).
; -----------------------------------------------------------------------------
Func Input_Init()
	GUIRegisterMsg($WM_MOUSEWHEEL, "Input_OnMouseWheel")
	GUIRegisterMsg($WM_MBUTTONDOWN, "Input_OnMButtonDown")
	GUIRegisterMsg($WM_MBUTTONUP, "Input_OnMButtonUp")
	GUIRegisterMsg($WM_MOUSEMOVE, "Input_OnMouseMove")
	GUIRegisterMsg($WM_LBUTTONDOWN, "Input_OnLButtonDown")
	GUIRegisterMsg($WM_LBUTTONUP, "Input_OnLButtonUp")
	GUIRegisterMsg($WM_RBUTTONDOWN, "Input_OnRButtonDown")

	$g_hInpUser32 = DllOpen("user32.dll")
EndFunc   ;==>Input_Init

Func Input_Shutdown()
	If $g_hInpUser32 <> 0 Then
		DllClose($g_hInpUser32)
		$g_hInpUser32 = 0
	EndIf
EndFunc   ;==>Input_Shutdown

; --- Extraction de mots signés 16 bits (coordonnées souris packées) ----------
Func Input_LoWordSigned($iValue)
	Local $iWord = BitAND($iValue, 0xFFFF)
	If $iWord >= 0x8000 Then $iWord -= 0x10000
	Return $iWord
EndFunc   ;==>Input_LoWordSigned

Func Input_HiWordSigned($iValue)
	Local $iWord = BitAND(BitShift($iValue, 16), 0xFFFF)
	If $iWord >= 0x8000 Then $iWord -= 0x10000
	Return $iWord
EndFunc   ;==>Input_HiWordSigned

; -----------------------------------------------------------------------------
; Molette : zoom centré sur le curseur, uniquement au-dessus du canvas.
; WM_MOUSEWHEEL fournit des coordonnées ÉCRAN → conversion en client canvas.
; -----------------------------------------------------------------------------
Func Input_OnMouseWheel($hWnd, $iMsg, $wParam, $lParam)
	#forceref $hWnd, $iMsg
	Local $tPoint = DllStructCreate("long X;long Y")
	DllStructSetData($tPoint, "X", Input_LoWordSigned($lParam))
	DllStructSetData($tPoint, "Y", Input_HiWordSigned($lParam))
	_WinAPI_ScreenToClient(UI_GetCanvasHwnd(), $tPoint)

	Local $iX = DllStructGetData($tPoint, "X")
	Local $iY = DllStructGetData($tPoint, "Y")
	If $iX < 0 Or $iY < 0 Or $iX >= UI_GetCanvasW() Or $iY >= UI_GetCanvasH() Then Return $GUI_RUNDEFMSG

	Local $iDelta = Input_HiWordSigned($wParam)
	Camera_ZoomAt($iX, $iY, ($iDelta > 0) ? 1 : -1)
	App_InvalidateView()
	Return 0
EndFunc   ;==>Input_OnMouseWheel

; -----------------------------------------------------------------------------
; Bouton milieu : démarre le pan. La capture souris garantit un pan fluide
; même quand le curseur sort du canvas pendant le drag.
; -----------------------------------------------------------------------------
Func Input_OnMButtonDown($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam
	If $hWnd <> UI_GetCanvasHwnd() Then Return $GUI_RUNDEFMSG

	$g_bInpPanning = True
	$g_iInpLastX = Input_LoWordSigned($lParam)
	$g_iInpLastY = Input_HiWordSigned($lParam)
	_WinAPI_SetCapture(UI_GetCanvasHwnd())
	Return 0
EndFunc   ;==>Input_OnMButtonDown

Func Input_OnMButtonUp($hWnd, $iMsg, $wParam, $lParam)
	#forceref $hWnd, $iMsg, $wParam, $lParam
	If Not $g_bInpPanning Then Return $GUI_RUNDEFMSG

	$g_bInpPanning = False
	_WinAPI_ReleaseCapture()
	Return 0
EndFunc   ;==>Input_OnMButtonUp

; Tolérance de visée en mm au zoom courant.
Func Input_PickTolMm()
	Return $INP_PICK_TOL_PX / Camera_GetZoom()
EndFunc   ;==>Input_PickTolMm

; -----------------------------------------------------------------------------
; Hit-test des bords de la boîte : pose $iEdgeX ($METIER_EDGE_W/_E ou -1) et
; $iEdgeY ($METIER_EDGE_N/_S ou -1) selon les bandes de paroi touchées
; (bande pleine + tolérance côté extérieur). Les DEUX posés = un coin.
; Retourne le nombre de bords touchés (0, 1 ou 2).
; -----------------------------------------------------------------------------
Func Input_HitBoxEdges($fWx, $fWy, ByRef $iEdgeX, ByRef $iEdgeY)
	$iEdgeX = -1
	$iEdgeY = -1

	Local $fOx1, $fOy1, $fOx2, $fOy2
	Project_BoxOuter($fOx1, $fOy1, $fOx2, $fOy2)
	Local $fT = Project_BoxGet($BOX_THICKNESS)
	Local $fTol = Input_PickTolMm()

	; Hors du voisinage de la boîte : rien.
	If $fWx < $fOx1 - $fTol Or $fWx > $fOx2 + $fTol Then Return 0
	If $fWy < $fOy1 - $fTol Or $fWy > $fOy2 + $fTol Then Return 0

	If $fWx <= $fOx1 + $fT Then
		$iEdgeX = $METIER_EDGE_W
	ElseIf $fWx >= $fOx2 - $fT Then
		$iEdgeX = $METIER_EDGE_E
	EndIf
	If $fWy <= $fOy1 + $fT Then
		$iEdgeY = $METIER_EDGE_N
	ElseIf $fWy >= $fOy2 - $fT Then
		$iEdgeY = $METIER_EDGE_S
	EndIf

	Return ($iEdgeX <> -1 ? 1 : 0) + ($iEdgeY <> -1 ? 1 : 0)
EndFunc   ;==>Input_HitBoxEdges

; Pose le curseur de survol adapté (11 = redim. vertical, 13 = horizontal,
; -1 = défaut) sans le re-poser inutilement à chaque mouvement.
Func Input_SetHoverCursor($iCursor)
	If $g_iInpCursor = $iCursor Then Return
	$g_iInpCursor = $iCursor
	If $iCursor = -1 Then
		GUISetCursor(2, 0, UI_GetCanvasHwnd()) ; flèche, plus d'override
	Else
		GUISetCursor($iCursor, 1, UI_GetCanvasHwnd())
	EndIf
EndFunc   ;==>Input_SetHoverCursor

; Applique une nouvelle sélection et synchronise panneau + vue.
Func Input_ApplySelection($iId)
	If Selection_Set($iId) Then
		UI_RefreshSeparatorSection()
		App_InvalidateView()
	EndIf
EndFunc   ;==>Input_ApplySelection

; -----------------------------------------------------------------------------
; Clic gauche dans le canvas :
;   - sur un séparateur → sélection (le groupe entier suit) ;
;   - dans une sous-zone → création d'un séparateur (CTRL = horizontal,
;     SHIFT = global), puis sélection du séparateur créé ;
;   - hors de tout → désélection.
; La position de création est clampée par le métier (écart minimal 10 mm) ;
; un clic dans une sous-zone trop étroite ne crée rien.
; -----------------------------------------------------------------------------
Func Input_OnLButtonDown($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg
	If $hWnd <> UI_GetCanvasHwnd() Then Return $GUI_RUNDEFMSG

	Local $fWx = Camera_ScreenToWorldX(Input_LoWordSigned($lParam))
	Local $fWy = Camera_ScreenToWorldY(Input_HiWordSigned($lParam))

	; Priorité à la sélection : on ne crée jamais SUR un séparateur existant.
	Local $iId = Selection_HitTest($fWx, $fWy, Input_PickTolMm())

	; Puis aux parois : drag d'un bord = redimensionnement d'un axe ;
	; drag d'un COIN = redimensionnement des deux axes à la fois.
	If $iId = -1 Then
		Local $iEdgeX, $iEdgeY
		If Input_HitBoxEdges($fWx, $fWy, $iEdgeX, $iEdgeY) > 0 Then
			$g_iInpDragEdgeX = $iEdgeX
			$g_iInpDragEdgeY = $iEdgeY
			_WinAPI_SetCapture(UI_GetCanvasHwnd())
			Return 0
		EndIf
	EndIf

	; Enfin à la création dans une sous-zone.
	If $iId = -1 Then
		Local $iOrient = (BitAND($wParam, $INP_MK_CONTROL) <> 0) ? $SEP_ORIENT_H : $SEP_ORIENT_V
		Local $bGlobal = (BitAND($wParam, $INP_MK_SHIFT) <> 0)
		$iId = Metier_CreateSeparator($fWx, $fWy, $iOrient, $bGlobal, UI_GetActiveLayer())
		If $iId <> -1 Then
			UI_MarkProjectModified()
			App_InvalidateView() ; le modèle a changé, quoi qu'il arrive à la sélection
		EndIf
	EndIf

	Input_ApplySelection($iId)

	; Démarre le drag : le séparateur (sélectionné ou fraîchement créé) suit
	; la souris jusqu'au relâchement. La capture garantit la continuité même
	; quand le curseur sort du canvas.
	If $iId <> -1 Then
		Local $iRow = Project_SepFindById($iId)
		$g_iInpDragSepId = $iId
		$g_fInpDragGrab = ((Project_SepGet($iRow, $SEP_ORIENT) = $SEP_ORIENT_V) ? $fWx : $fWy) _
				 - Project_SepGet($iRow, $SEP_POS)
		_WinAPI_SetCapture(UI_GetCanvasHwnd())
	EndIf
	Return 0
EndFunc   ;==>Input_OnLButtonDown

; Fin d'un drag gauche (séparateur ou bord(s) de boîte) : libère la capture
; et resynchronise. Fin de redimensionnement : la boîte est recalée en (0,0)
; et la caméra décalée du même delta — visuellement la boîte ne bouge pas,
; c'est la grille qui se recale sous elle.
Func Input_OnLButtonUp($hWnd, $iMsg, $wParam, $lParam)
	#forceref $hWnd, $iMsg, $wParam, $lParam
	If $g_iInpDragSepId = -1 And $g_iInpDragEdgeX = -1 And $g_iInpDragEdgeY = -1 Then Return $GUI_RUNDEFMSG

	If $g_iInpDragSepId <> -1 Then UI_RefreshSeparatorSection()

	If $g_iInpDragEdgeX <> -1 Or $g_iInpDragEdgeY <> -1 Then
		Local $fShiftX, $fShiftY
		If Metier_EndBoxResize($fShiftX, $fShiftY) Then
			; Compense le recalage : le contenu a bougé de (shift), la caméra
			; le suit — l'utilisateur voit la grille glisser, pas la boîte.
			Camera_Translate($fShiftX, $fShiftY)
			UI_RefreshBoxInputs()
			App_InvalidateView()
		EndIf
	EndIf

	$g_iInpDragSepId = -1
	$g_iInpDragEdgeX = -1
	$g_iInpDragEdgeY = -1
	_WinAPI_ReleaseCapture()
	Return 0
EndFunc   ;==>Input_OnLButtonUp

; -----------------------------------------------------------------------------
; Clic droit : sélection uniquement (cahier des charges) — jamais de création.
; -----------------------------------------------------------------------------
Func Input_OnRButtonDown($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam
	If $hWnd <> UI_GetCanvasHwnd() Then Return $GUI_RUNDEFMSG

	Local $fWx = Camera_ScreenToWorldX(Input_LoWordSigned($lParam))
	Local $fWy = Camera_ScreenToWorldY(Input_HiWordSigned($lParam))
	Input_ApplySelection(Selection_HitTest($fWx, $fWy, Input_PickTolMm()))
	Return 0
EndFunc   ;==>Input_OnRButtonDown

; -----------------------------------------------------------------------------
; Polling clavier (appelé par la boucle principale) : Suppr et Échap.
; Un polling (plutôt qu'un accélérateur) laisse les touches fonctionner
; normalement dans les champs de saisie : on ignore Suppr quand le focus est
; dans un contrôle d'édition.
; -----------------------------------------------------------------------------
Func Input_PollKeys()
	; Uniquement quand l'application est active.
	If WinActive($g_hUiMainGui) = 0 Then Return

	; --- Suppr : suppression du séparateur sélectionné (front montant) ---
	Local $bDel = _IsPressed($INP_VK_DELETE, $g_hInpUser32)
	If $bDel And Not $g_bInpPrevDel And Selection_HasSelection() Then
		If _WinAPI_GetClassName(_WinAPI_GetFocus()) <> "Edit" Then
			UI_DeleteSelectedSeparator() ; même chemin que le bouton Supprimer
		EndIf
	EndIf
	$g_bInpPrevDel = $bDel

	; --- Échap : désélection ---
	Local $bEsc = _IsPressed($INP_VK_ESCAPE, $g_hInpUser32)
	If $bEsc And Not $g_bInpPrevEsc Then Input_ApplySelection(-1)
	$g_bInpPrevEsc = $bEsc
EndFunc   ;==>Input_PollKeys

; -----------------------------------------------------------------------------
; Déplacement souris :
;   - pan en temps réel pendant le drag milieu ;
;   - déplacement TEMPS RÉEL du séparateur pendant le drag gauche : le métier
;     clampe (sous-zone + écart 10 mm) et recalcule les sous-zones à chaque
;     pas — l'affichage suit immédiatement ;
;   - sinon, suivi de la sous-zone survolée (retour visuel de création).
; -----------------------------------------------------------------------------
Func Input_OnMouseMove($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam
	If $hWnd <> UI_GetCanvasHwnd() Then Return $GUI_RUNDEFMSG

	Local $iX = Input_LoWordSigned($lParam)
	Local $iY = Input_HiWordSigned($lParam)

	If $g_bInpPanning Then
		Camera_PanByPixels($iX - $g_iInpLastX, $iY - $g_iInpLastY)
		App_InvalidateView()
	ElseIf $g_iInpDragEdgeX <> -1 Or $g_iInpDragEdgeY <> -1 Then
		; Redimensionnement de la boîte : le(s) bord(s) suivent le curseur
		; (l'origine peut devenir négative pendant la manipulation — le
		; recalage en (0,0) a lieu au relâchement).
		Local $bResized = False
		If $g_iInpDragEdgeX <> -1 Then
			If Metier_ResizeBoxEdge($g_iInpDragEdgeX, Camera_ScreenToWorldX($iX)) Then $bResized = True
		EndIf
		If $g_iInpDragEdgeY <> -1 Then
			If Metier_ResizeBoxEdge($g_iInpDragEdgeY, Camera_ScreenToWorldY($iY)) Then $bResized = True
		EndIf
		If $bResized Then
			UI_RefreshBoxInputs()
			UI_MarkProjectModified()
			App_InvalidateView()
		EndIf
	ElseIf $g_iInpDragSepId <> -1 Then
		Local $iRow = Project_SepFindById($g_iInpDragSepId)
		If $iRow <> -1 Then
			Local $fCursor = (Project_SepGet($iRow, $SEP_ORIENT) = $SEP_ORIENT_V) _
					 ? Camera_ScreenToWorldX($iX) : Camera_ScreenToWorldY($iY)
			If Metier_MoveSeparator($g_iInpDragSepId, $fCursor - $g_fInpDragGrab) Then
				UI_RefreshSeparatorPosition() ; maj légère : position + longueur
				UI_MarkProjectModified()
				App_InvalidateView()
			EndIf
		EndIf
	Else
		Local $fWx = Camera_ScreenToWorldX($iX)
		Local $fWy = Camera_ScreenToWorldY($iY)

		; Sous-zone sous le curseur (invalidation seulement si elle change).
		If Selection_SetHoverZone(Zones_FindAt($fWx, $fWy)) Then App_InvalidateView()

		; Curseur de redimensionnement au survol d'un bord ou d'un coin
		; (hors séparateur). 13 = ↔, 11 = ↕, 10/12 = diagonales.
		Local $iEdgeX = -1, $iEdgeY = -1
		If Selection_HitTest($fWx, $fWy, Input_PickTolMm()) = -1 Then Input_HitBoxEdges($fWx, $fWy, $iEdgeX, $iEdgeY)
		If $iEdgeX <> -1 And $iEdgeY <> -1 Then
			; Coin : diagonale selon la paire (l'axe Y est inversé à l'écran).
			Input_SetHoverCursor((($iEdgeX = $METIER_EDGE_E) = ($iEdgeY = $METIER_EDGE_S)) ? 10 : 12)
		ElseIf $iEdgeX <> -1 Then
			Input_SetHoverCursor(13)
		ElseIf $iEdgeY <> -1 Then
			Input_SetHoverCursor(11)
		Else
			Input_SetHoverCursor(-1)
		EndIf
	EndIf

	$g_iInpLastX = $iX
	$g_iInpLastY = $iY
	Return 0
EndFunc   ;==>Input_OnMouseMove
