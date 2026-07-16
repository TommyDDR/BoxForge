#include-once
#include <GDIPlus.au3>
#include <WinAPI.au3>
#include <WinAPIGdi.au3>
#include <WindowsConstants.au3>
#include "App.au3"

; =============================================================================
; Renderer.au3 — Chaîne de rendu GDI+ (niveau 3 : affichage).
;
; Architecture (cf. pratiques-rendu-performant.md §1) :
;
;   backbuffer = DIB section 32bpp sélectionnée dans un memory DC
;         │  (Graphics GDI+ créé sur ce DC : composition offscreen)
;         ▼
;   Renderer_Present() : un seul BitBlt memDC → DC du canvas (SRCCOPY)
;
; On ne dessine JAMAIS directement dans la fenêtre pendant la frame.
; Contrairement au document (pixel art upscalé), le backbuffer est ici à la
; taille NATIVE du canvas : dessin vectoriel, netteté garantie à tout zoom.
;
; Ce module ne contient AUCUNE logique métier : il ne fait qu'afficher.
; =============================================================================

; --- Couleurs de rendu (format GDI+ 0xAARRGGBB) ---
Global Const $RDR_COLOR_BG     = 0xFF15171B ; fond du canvas
Global Const $RDR_COLOR_TEXT   = 0xFFB8BCC4 ; texte d'information
Global Const $RDR_COLOR_ACCENT = 0xFF4C8DFF ; éléments de repère

; TextRenderingHint constant partout (3 = AntiAlias, cf. pratiques §3)
Global Const $RDR_TEXT_RENDER_HINT = 3

; --- Cibles de rendu ---
Global $g_hRdrWnd       = 0 ; HWND du canvas
Global $g_hRdrPresentDC = 0 ; DC de la fenêtre (présentation)
Global $g_hRdrMemDC     = 0 ; memory DC (composition)
Global $g_hRdrDib       = 0 ; DIB section 32bpp (backbuffer)
Global $g_hRdrDibOld    = 0 ; bitmap d'origine du memory DC (à restaurer)
Global $g_hRdrGfx       = 0 ; Graphics GDI+ créé sur le memory DC
Global $g_iRdrW         = 1 ; taille courante du backbuffer
Global $g_iRdrH         = 1

; --- Objets de dessin partagés (créés une fois, jamais par frame — §8) ---
Global $g_hRdrFontFamily    = 0
Global $g_hRdrFontUi        = 0
Global $g_hRdrFormatDefault = 0
Global $g_hRdrBrushText     = 0
Global $g_hRdrPenAccent     = 0

; --- Registre de disposers (cf. pratiques §11) ---
Global $g_aRdrDisposers[0]

; -----------------------------------------------------------------------------
; Initialisation : GDI+, cibles de rendu, objets partagés.
; -----------------------------------------------------------------------------
Func Renderer_Init($hWnd, $iW, $iH)
	_GDIPlus_Startup()

	$g_hRdrWnd = $hWnd
	$g_hRdrPresentDC = _WinAPI_GetDC($hWnd)

	Renderer_CreateTargets($iW, $iH)
	Renderer_CreateSharedObjects()
EndFunc   ;==>Renderer_Init

; -----------------------------------------------------------------------------
; Bloc de modes GDI+ : à appliquer sur CHAQUE Graphics créé (cf. pratiques §3).
; Un Graphics fraîchement créé est en mode "qualité" lent ; on veut un dessin
; vectoriel net (pas d'antialiasing de forme : les traits snappés au pixel
; restent parfaitement nets à tout zoom).
; -----------------------------------------------------------------------------
Func Renderer_ApplyQualityModes($hGfx)
	_GDIPlus_GraphicsSetInterpolationMode($hGfx, 5) ; NearestNeighbor
	_GDIPlus_GraphicsSetPixelOffsetMode($hGfx, 2)   ; Half : pas de bavure d'1/2 px
	_GDIPlus_GraphicsSetSmoothingMode($hGfx, 0)     ; pas d'antialiasing des formes
	_GDIPlus_GraphicsSetTextRenderingHint($hGfx, $RDR_TEXT_RENDER_HINT)
EndFunc   ;==>Renderer_ApplyQualityModes

; -----------------------------------------------------------------------------
; (Re)création du backbuffer à la taille demandée.
; Patron "recreate" : on commence toujours par disposer l'existant (§11).
; -----------------------------------------------------------------------------
Func Renderer_CreateTargets($iW, $iH)
	Renderer_DisposeTargets()

	If $iW < 1 Then $iW = 1
	If $iH < 1 Then $iH = 1
	$g_iRdrW = $iW
	$g_iRdrH = $iH

	; DIB section 32bpp (pas un DDB) : GDI+ écrit directement les pixels,
	; et le BitBlt final vers l'écran reste une simple copie mémoire.
	$g_hRdrMemDC = _WinAPI_CreateCompatibleDC($g_hRdrPresentDC)
	$g_hRdrDib = _WinAPI_CreateDIB($iW, $iH)
	$g_hRdrDibOld = _WinAPI_SelectObject($g_hRdrMemDC, $g_hRdrDib)

	$g_hRdrGfx = _GDIPlus_GraphicsCreateFromHDC($g_hRdrMemDC)
	Renderer_ApplyQualityModes($g_hRdrGfx)
EndFunc   ;==>Renderer_CreateTargets

; Libère le backbuffer. Idempotent : appelable deux fois sans casse (§11).
; Ordre impératif : Graphics AVANT bitmap, bitmap désélectionnée AVANT delete.
Func Renderer_DisposeTargets()
	If $g_hRdrGfx <> 0 Then
		_GDIPlus_GraphicsDispose($g_hRdrGfx)
		$g_hRdrGfx = 0
	EndIf
	If $g_hRdrMemDC <> 0 Then
		_WinAPI_SelectObject($g_hRdrMemDC, $g_hRdrDibOld)
		$g_hRdrDibOld = 0
		_WinAPI_DeleteObject($g_hRdrDib)
		$g_hRdrDib = 0
		_WinAPI_DeleteDC($g_hRdrMemDC)
		$g_hRdrMemDC = 0
	EndIf
EndFunc   ;==>Renderer_DisposeTargets

; -----------------------------------------------------------------------------
; Redimensionnement du canvas : recrée uniquement le backbuffer.
; -----------------------------------------------------------------------------
Func Renderer_Resize($iW, $iH)
	If $iW = $g_iRdrW And $iH = $g_iRdrH Then Return
	Renderer_CreateTargets($iW, $iH)
EndFunc   ;==>Renderer_Resize

; -----------------------------------------------------------------------------
; Objets de dessin partagés : créés au démarrage, disposés au shutdown via le
; registre. JAMAIS de création de font/brush/pen dans le chemin par frame (§8).
; -----------------------------------------------------------------------------
Func Renderer_CreateSharedObjects()
	$g_hRdrFontFamily = _GDIPlus_FontFamilyCreate("Segoe UI")
	$g_hRdrFontUi = _GDIPlus_FontCreate($g_hRdrFontFamily, 10)
	$g_hRdrFormatDefault = _GDIPlus_StringFormatCreate()
	$g_hRdrBrushText = _GDIPlus_BrushCreateSolid($RDR_COLOR_TEXT)
	$g_hRdrPenAccent = _GDIPlus_PenCreate($RDR_COLOR_ACCENT)

	Renderer_RegisterDisposer("Renderer_DisposeSharedObjects")
EndFunc   ;==>Renderer_CreateSharedObjects

Func Renderer_DisposeSharedObjects()
	If $g_hRdrPenAccent <> 0 Then
		_GDIPlus_PenDispose($g_hRdrPenAccent)
		$g_hRdrPenAccent = 0
	EndIf
	If $g_hRdrBrushText <> 0 Then
		_GDIPlus_BrushDispose($g_hRdrBrushText)
		$g_hRdrBrushText = 0
	EndIf
	If $g_hRdrFormatDefault <> 0 Then
		_GDIPlus_StringFormatDispose($g_hRdrFormatDefault)
		$g_hRdrFormatDefault = 0
	EndIf
	If $g_hRdrFontUi <> 0 Then
		_GDIPlus_FontDispose($g_hRdrFontUi)
		$g_hRdrFontUi = 0
	EndIf
	If $g_hRdrFontFamily <> 0 Then
		_GDIPlus_FontFamilyDispose($g_hRdrFontFamily)
		$g_hRdrFontFamily = 0
	EndIf
EndFunc   ;==>Renderer_DisposeSharedObjects

; -----------------------------------------------------------------------------
; Registre de disposers (§11) : tout créateur de ressources GDI+ enregistre sa
; fonction de libération. Dédup intégrée ; chaque disposer est idempotent.
; -----------------------------------------------------------------------------
Func Renderer_RegisterDisposer($sFuncName)
	For $i = 0 To UBound($g_aRdrDisposers) - 1
		If $g_aRdrDisposers[$i] = $sFuncName Then Return
	Next
	ReDim $g_aRdrDisposers[UBound($g_aRdrDisposers) + 1]
	$g_aRdrDisposers[UBound($g_aRdrDisposers) - 1] = $sFuncName
EndFunc   ;==>Renderer_RegisterDisposer

Func Renderer_RunDisposers()
	For $i = 0 To UBound($g_aRdrDisposers) - 1
		Call($g_aRdrDisposers[$i])
	Next
EndFunc   ;==>Renderer_RunDisposers

; -----------------------------------------------------------------------------
; Composition d'une frame complète, puis présentation.
; -----------------------------------------------------------------------------
Func Renderer_Frame()
	_GDIPlus_GraphicsClear($g_hRdrGfx, $RDR_COLOR_BG)

	Renderer_DrawPlaceholder()

	Renderer_Present()
EndFunc   ;==>Renderer_Frame

; Dessin provisoire (étape 1) : prouve que la chaîne de rendu fonctionne.
; Sera remplacé par le dessin du modèle (boîte, séparateurs, sous-zones).
Func Renderer_DrawPlaceholder()
	; Croix de repère au centre du canvas.
	Local $iCx = Int($g_iRdrW / 2), $iCy = Int($g_iRdrH / 2)
	_GDIPlus_GraphicsDrawLine($g_hRdrGfx, $iCx - 12, $iCy, $iCx + 12, $iCy, $g_hRdrPenAccent)
	_GDIPlus_GraphicsDrawLine($g_hRdrGfx, $iCx, $iCy - 12, $iCx, $iCy + 12, $g_hRdrPenAccent)

	; Libellé d'état en haut à gauche.
	Local $tLayout = _GDIPlus_RectFCreate(10, 8, $g_iRdrW - 20, 24)
	_GDIPlus_GraphicsDrawStringEx($g_hRdrGfx, $APP_NAME & " " & $APP_VERSION & _
			" — étape 1 : socle de rendu", $g_hRdrFontUi, $tLayout, $g_hRdrFormatDefault, $g_hRdrBrushText)
EndFunc   ;==>Renderer_DrawPlaceholder

; Présentation : UN SEUL blit par frame, SRCCOPY, plein canvas (§1, §2).
Func Renderer_Present()
	_WinAPI_BitBlt($g_hRdrPresentDC, 0, 0, $g_iRdrW, $g_iRdrH, $g_hRdrMemDC, 0, 0, $SRCCOPY)
EndFunc   ;==>Renderer_Present

; -----------------------------------------------------------------------------
; Libération complète (ordre : disposers → cibles → DC fenêtre → GDI+).
; -----------------------------------------------------------------------------
Func Renderer_Shutdown()
	Renderer_RunDisposers()
	Renderer_DisposeTargets()
	If $g_hRdrPresentDC <> 0 Then
		_WinAPI_ReleaseDC($g_hRdrWnd, $g_hRdrPresentDC)
		$g_hRdrPresentDC = 0
	EndIf
	_GDIPlus_Shutdown()
EndFunc   ;==>Renderer_Shutdown
