#include-once
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <WinAPI.au3>
#include "App.au3"
#include "Camera.au3"
#include "Zones.au3"
#include "UI.au3"

; =============================================================================
; Input.au3 — Entrées souris du canvas (niveau 4 : UI).
;
; Rôle : traduire les messages Windows bruts en actions métier (création de
; séparateurs) ou de vue (caméra). Sélection et déplacement arrivent aux
; étapes suivantes.
;
; Affectation des boutons (cf. cahier des charges) :
;   - molette            → zoom centré sur le curseur
;   - drag bouton milieu → pan de la caméra
;   - clic gauche        → création d'un séparateur dans la sous-zone :
;                            vertical ; CTRL = horizontal ; SHIFT = global
;                            (traverse toutes les sous-zones, segments liés)
;   - clic droit         → réservé (sélection)
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

; --- État du pan en cours ---
Global $g_bInpPanning = False
Global $g_iInpLastX   = 0 ; dernière position souris (client canvas)
Global $g_iInpLastY   = 0

; -----------------------------------------------------------------------------
; Enregistrement des messages souris.
; -----------------------------------------------------------------------------
Func Input_Init()
	GUIRegisterMsg($WM_MOUSEWHEEL, "Input_OnMouseWheel")
	GUIRegisterMsg($WM_MBUTTONDOWN, "Input_OnMButtonDown")
	GUIRegisterMsg($WM_MBUTTONUP, "Input_OnMButtonUp")
	GUIRegisterMsg($WM_MOUSEMOVE, "Input_OnMouseMove")
	GUIRegisterMsg($WM_LBUTTONDOWN, "Input_OnLButtonDown")
EndFunc   ;==>Input_Init

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

; -----------------------------------------------------------------------------
; Clic gauche dans le canvas : création d'un séparateur dans la sous-zone
; cliquée. CTRL bascule en horizontal, SHIFT en création globale (un segment
; par sous-zone traversée, tous liés en groupe).
; La position est clampée par le métier (écart minimal 10 mm) ; un clic hors
; de toute sous-zone, ou dans une sous-zone trop étroite, ne crée rien.
; -----------------------------------------------------------------------------
Func Input_OnLButtonDown($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg
	If $hWnd <> UI_GetCanvasHwnd() Then Return $GUI_RUNDEFMSG

	Local $fWx = Camera_ScreenToWorldX(Input_LoWordSigned($lParam))
	Local $fWy = Camera_ScreenToWorldY(Input_HiWordSigned($lParam))

	Local $iOrient = (BitAND($wParam, $INP_MK_CONTROL) <> 0) ? $SEP_ORIENT_H : $SEP_ORIENT_V
	Local $bGlobal = (BitAND($wParam, $INP_MK_SHIFT) <> 0)

	Local $iId = Metier_CreateSeparator($fWx, $fWy, $iOrient, $bGlobal, UI_GetActiveLayer())
	If $iId <> -1 Then App_InvalidateView()
	Return 0
EndFunc   ;==>Input_OnLButtonDown

; -----------------------------------------------------------------------------
; Déplacement souris : applique le pan en temps réel pendant le drag milieu.
; -----------------------------------------------------------------------------
Func Input_OnMouseMove($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam
	If Not $g_bInpPanning Then Return $GUI_RUNDEFMSG
	If $hWnd <> UI_GetCanvasHwnd() Then Return $GUI_RUNDEFMSG

	Local $iX = Input_LoWordSigned($lParam)
	Local $iY = Input_HiWordSigned($lParam)
	Camera_PanByPixels($iX - $g_iInpLastX, $iY - $g_iInpLastY)
	$g_iInpLastX = $iX
	$g_iInpLastY = $iY
	App_InvalidateView()
	Return 0
EndFunc   ;==>Input_OnMouseMove
