#include <GUIConstantsEx.au3>
#include "App.au3"
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
	UI_Create()
	Renderer_Init(UI_GetCanvasHwnd(), UI_GetCanvasW(), UI_GetCanvasH())
	App_InvalidateView()

	Main_Loop()

	Renderer_Shutdown()
EndFunc   ;==>Main

Func Main_Loop()
	While True
		; --- Événements GUI (GUIGetMsg dort ~10 ms quand la file est vide) ---
		Local $iMsg = GUIGetMsg()
		Switch $iMsg
			Case $GUI_EVENT_CLOSE
				ExitLoop
		EndSwitch

		; --- Redimensionnement en attente ? (posé par WM_SIZE) ---
		If UI_ConsumeLayoutPending() Then
			UI_ApplyLayout()
			Renderer_Resize(UI_GetCanvasW(), UI_GetCanvasH())
			App_InvalidateView()
		EndIf

		; --- Rendu uniquement si la vue a changé ---
		If App_ConsumeViewDirty() Then Renderer_Frame()
	WEnd
EndFunc   ;==>Main_Loop
