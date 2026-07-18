#include <GUIConstantsEx.au3>
#include "App.au3"
#include "Project.au3"
#include "Zones.au3"
#include "Camera.au3"
#include "Undo.au3"
#include "Input.au3"
#include "UI.au3"
#include "Renderer.au3"
#include "Settings.au3"

; =============================================================================
; Main.au3 — Point d'entrée : initialisation, boucle principale, arrêt propre.
;
; La boucle est pilotée par des drapeaux (dirty flags) :
;   - disposition à réappliquer  → UI_ApplyLayout + Renderer_Resize
;   - vue à recomposer           → Renderer_Frame
; On ne redessine que quand quelque chose a changé : coût proportionnel à ce
; qui change, adapté à un éditeur (pas de boucle de jeu débridée).
; =============================================================================

; Espacement minimal entre deux rendus (~60 Hz) : un drag souris rapide
; (séparateur, bord de boîte, pan) pose App_InvalidateView() à CHAQUE
; WM_MOUSEMOVE — les gestionnaires enregistrés via GUIRegisterMsg (Input.au3)
; s'exécutent au fil de l'eau, pas seulement au rythme de cette boucle. Sans
; ce garde-fou, une souris rapide (ou haute cadence de rapport) fait un rendu
; GDI+ complet par message et la boucle prend du retard sur la souris — gel
; qui grossit puis "rattrape" d'un coup à l'arrêt du geste. Le drapeau dirty
; n'est PAS consommé tant que l'intervalle n'est pas écoulé : la dernière
; position atteinte est donc toujours rendue, juste pas plus souvent que
; nécessaire à l'oeil.
Global Const $MAIN_FRAME_MIN_MS = 15

Main()

Func Main()
	; Nouveau projet : la boîte par défaut est créée automatiquement
	; (et les données dérivées — sous-zones — sont calculées).
	Metier_NewProject()

	UI_Create()
	UI_RefreshBoxInputs()
	UI_RefreshLayerInputs()

	; Réglages persistés (fenêtre, vue simplifiée, mode d'affichage des
	; zones) : appliqués AVANT UI_ApplyLayout pour que le calcul de la
	; disposition (canvas/panneau bas dynamique) parte de leurs valeurs.
	Settings_Load()
	Local $iWinX, $iWinY, $iWinW, $iWinH, $bWinMaximized
	If Settings_GetWindowRect($iWinX, $iWinY, $iWinW, $iWinH, $bWinMaximized) Then
		WinMove(UI_GetMainHwnd(), "", $iWinX, $iWinY, $iWinW, $iWinH)
		If $bWinMaximized Then WinSetState(UI_GetMainHwnd(), "", @SW_MAXIMIZE)
	EndIf
	UI_SetLayerSimpleView(Settings_GetLayerSimpleView())
	UI_SetZoneLabelMode(Settings_GetZoneLabelMode())
	UI_SeedMainSepOrient(Settings_GetMainSepOrient())
	UI_ApplyLayout()

	; Caméra : cadre la boîte dans le canvas.
	Camera_SetViewport(UI_GetCanvasW(), UI_GetCanvasH())
	UI_FitCameraToBox()

	Renderer_Init(UI_GetCanvasHwnd(), UI_GetCanvasW(), UI_GetCanvasH())
	Input_Init()
	App_InvalidateView()

	Main_Loop()

	; Sauvegarde de l'état courant (fenêtre, vue simplifiée, mode d'affichage
	; des zones, dernier séparateur principal) pour la resynchroniser au
	; prochain lancement.
	Local $aPos = WinGetPos(UI_GetMainHwnd())
	Local $bMaximizedNow = BitAND(WinGetState(UI_GetMainHwnd()), $WIN_STATE_MAXIMIZED) <> 0
	Settings_Save($aPos[0], $aPos[1], $aPos[2], $aPos[3], $bMaximizedNow, _
			UI_IsLayerSimpleView(), UI_GetZoneLabelMode(), Project_BoxGet($BOX_MAIN_SEP_ORIENT))

	Input_Shutdown()
	Renderer_Shutdown()
EndFunc   ;==>Main

Func Main_Loop()
	Local $hRenderTimer = TimerInit()
	While True
		; --- Événements GUI (GUIGetMsg dort ~10 ms quand la file est vide) ---
		Local $iMsg = GUIGetMsg()
		Switch $iMsg
			Case $GUI_EVENT_CLOSE
				; Fermeture (croix) : confirmation si modifications non enregistrées.
				If UI_ConfirmDiscard() Then ExitLoop
			Case 0
				; rien à faire
			Case Else
				UI_HandleGuiEvent($iMsg)
		EndSwitch

		; Fermeture demandée par le menu Quitter (déjà confirmée).
		If UI_ConsumeQuitRequested() Then ExitLoop

		; --- Redimensionnement en attente ? (posé par WM_SIZE) ---
		If UI_ConsumeLayoutPending() Then
			UI_ApplyLayout()
			Camera_SetViewport(UI_GetCanvasW(), UI_GetCanvasH())
			Renderer_Resize(UI_GetCanvasW(), UI_GetCanvasH())
			App_InvalidateView()
		EndIf

		; --- Clavier : Suppr (suppression) / Échap (désélection) ---
		Input_PollKeys()

		; --- Drag en cours + rendu : au plus à ~60 Hz ---
		; Le déplacement coalescé (séparateur/bord, cf. Input.au3) est appliqué
		; ICI, juste avant le rendu du même tick : un seul déplacement métier et
		; un seul rafraîchissement du panneau par image affichée, quelle que
		; soit la cadence des WM_MOUSEMOVE.
		If TimerDiff($hRenderTimer) >= $MAIN_FRAME_MIN_MS Then
			$hRenderTimer = TimerInit()
			Input_ProcessPendingDrag()
			If App_ConsumeViewDirty() Then Renderer_Frame()
		EndIf
	WEnd
EndFunc   ;==>Main_Loop
