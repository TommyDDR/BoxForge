#include <GUIConstantsEx.au3>
#include "App.au3"
#include "Project.au3"
#include "Zones.au3"
#include "Camera.au3"
#include "Input.au3"
#include "UI.au3"
#include "Renderer.au3"

; =============================================================================
; Main.au3 — Point d'entrée : initialisation, boucle principale, arrêt propre.
;
; La boucle est pilotée par des drapeaux (dirty flags) :
;   - disposition à réappliquer  → UI_ApplyLayout + Renderer_Resize
;   - vue à recomposer           → Renderer_Frame
; On ne redessine que quand quelque chose a changé : coût proportionnel à ce
; qui change, adapté à un éditeur (pas de boucle de jeu débridée).
; =============================================================================

Main()

Func Main()
	; Nouveau projet : la boîte par défaut est créée automatiquement
	; (et les données dérivées — sous-zones — sont calculées).
	Metier_NewProject()

	UI_Create()
	UI_RefreshBoxInputs()
	UI_RefreshLayerInputs()

	; Caméra : cadre la boîte dans le canvas.
	Camera_SetViewport(UI_GetCanvasW(), UI_GetCanvasH())
	Camera_FitRect(0, 0, Project_BoxGet($BOX_WIDTH), Project_BoxGet($BOX_LENGTH))

	Renderer_Init(UI_GetCanvasHwnd(), UI_GetCanvasW(), UI_GetCanvasH())
	Input_Init()
	App_InvalidateView()

	Main_Loop()

	Input_Shutdown()
	Renderer_Shutdown()
EndFunc   ;==>Main

Func Main_Loop()
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

		; --- Rendu uniquement si la vue a changé ---
		If App_ConsumeViewDirty() Then Renderer_Frame()
	WEnd
EndFunc   ;==>Main_Loop
