#include-once
#include <GDIPlus.au3>
#include <WinAPI.au3>
#include <WinAPIGdi.au3>
#include <WindowsConstants.au3>
#include "App.au3"
#include "Camera.au3"
#include "Project.au3"
#include "Zones.au3"
#include "Selection.au3"

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
Global Const $RDR_COLOR_BG         = 0xFF15171B ; fond du canvas
Global Const $RDR_COLOR_TEXT       = 0xFFB8BCC4 ; texte d'information
Global Const $RDR_COLOR_ACCENT     = 0xFF4C8DFF ; éléments de repère
Global Const $RDR_COLOR_GRID_MINOR = 0xFF1E2126 ; grille fine
Global Const $RDR_COLOR_GRID_MAJOR = 0xFF272B33 ; grille principale (×10)
Global Const $RDR_COLOR_AXIS       = 0xFF3A4356 ; axes X=0 / Y=0
Global Const $RDR_COLOR_WALL       = 0xFF4A4238 ; parois de la boîte (bois sombre)
Global Const $RDR_COLOR_INTERIOR   = 0xFF23252B ; fond intérieur de la boîte
Global Const $RDR_COLOR_BOX_LINE   = 0xFFA8865E ; contours de la boîte

; Alpha plein appliqué aux couleurs de layer (stockées en 0xRRGGBB au modèle).
Global Const $RDR_ALPHA_OPAQUE = 0xFF000000

Global Const $RDR_COLOR_SELECT = 0xFFFFA030 ; contour du séparateur sélectionné
Global Const $RDR_COLOR_HOVER  = 0x14FFFFFF ; voile de la sous-zone survolée

; --- Grille : espacement écran minimal d'une ligne fine (pixels) ---
Global Const $RDR_GRID_MIN_SPACING_PX = 10

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
Global $g_hRdrFormatCenter  = 0 ; alignement centré H+V (labels de taille de zone)
Global $g_hRdrBrushText     = 0
Global $g_hRdrPenAccent     = 0
Global $g_hRdrPenGridMinor  = 0
Global $g_hRdrPenGridMajor  = 0
Global $g_hRdrPenAxis       = 0
Global $g_hRdrBrushWall     = 0
Global $g_hRdrBrushInterior = 0
Global $g_hRdrPenBoxLine    = 0

; Brush/pen RÉUTILISABLES pour les séparateurs : un seul couple d'objets dont
; la couleur est changée par SetSolidColor/SetColor (coût µs) — jamais de
; création de brush/pen dans le chemin par frame (§8), et aucune invalidation
; de cache à gérer quand la couleur d'un layer change.
Global $g_hRdrBrushSep   = 0
Global $g_hRdrPenSepEdge = 0

; Sélection et survol.
Global $g_hRdrPenSelect  = 0 ; contour épais du séparateur sélectionné
Global $g_hRdrBrushHover = 0 ; voile translucide de la sous-zone survolée

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
	$g_hRdrFormatCenter = _GDIPlus_StringFormatCreate()
	_GDIPlus_StringFormatSetAlign($g_hRdrFormatCenter, 1)     ; StringAlignmentCenter (0=Near,1=Center,2=Far)
	_GDIPlus_StringFormatSetLineAlign($g_hRdrFormatCenter, 1) ; idem, axe vertical
	$g_hRdrBrushText = _GDIPlus_BrushCreateSolid($RDR_COLOR_TEXT)
	$g_hRdrPenAccent = _GDIPlus_PenCreate($RDR_COLOR_ACCENT)
	$g_hRdrPenGridMinor = _GDIPlus_PenCreate($RDR_COLOR_GRID_MINOR)
	$g_hRdrPenGridMajor = _GDIPlus_PenCreate($RDR_COLOR_GRID_MAJOR)
	$g_hRdrPenAxis = _GDIPlus_PenCreate($RDR_COLOR_AXIS)
	$g_hRdrBrushWall = _GDIPlus_BrushCreateSolid($RDR_COLOR_WALL)
	$g_hRdrBrushInterior = _GDIPlus_BrushCreateSolid($RDR_COLOR_INTERIOR)
	$g_hRdrPenBoxLine = _GDIPlus_PenCreate($RDR_COLOR_BOX_LINE)
	$g_hRdrBrushSep = _GDIPlus_BrushCreateSolid(0xFF808080)
	$g_hRdrPenSepEdge = _GDIPlus_PenCreate(0xFF404040)
	$g_hRdrPenSelect = _GDIPlus_PenCreate($RDR_COLOR_SELECT, 2)
	$g_hRdrBrushHover = _GDIPlus_BrushCreateSolid($RDR_COLOR_HOVER)

	Renderer_RegisterDisposer("Renderer_DisposeSharedObjects")
EndFunc   ;==>Renderer_CreateSharedObjects

Func Renderer_DisposeSharedObjects()
	If $g_hRdrBrushHover <> 0 Then
		_GDIPlus_BrushDispose($g_hRdrBrushHover)
		$g_hRdrBrushHover = 0
	EndIf
	If $g_hRdrPenSelect <> 0 Then
		_GDIPlus_PenDispose($g_hRdrPenSelect)
		$g_hRdrPenSelect = 0
	EndIf
	If $g_hRdrPenSepEdge <> 0 Then
		_GDIPlus_PenDispose($g_hRdrPenSepEdge)
		$g_hRdrPenSepEdge = 0
	EndIf
	If $g_hRdrBrushSep <> 0 Then
		_GDIPlus_BrushDispose($g_hRdrBrushSep)
		$g_hRdrBrushSep = 0
	EndIf
	If $g_hRdrPenBoxLine <> 0 Then
		_GDIPlus_PenDispose($g_hRdrPenBoxLine)
		$g_hRdrPenBoxLine = 0
	EndIf
	If $g_hRdrBrushInterior <> 0 Then
		_GDIPlus_BrushDispose($g_hRdrBrushInterior)
		$g_hRdrBrushInterior = 0
	EndIf
	If $g_hRdrBrushWall <> 0 Then
		_GDIPlus_BrushDispose($g_hRdrBrushWall)
		$g_hRdrBrushWall = 0
	EndIf
	If $g_hRdrPenAxis <> 0 Then
		_GDIPlus_PenDispose($g_hRdrPenAxis)
		$g_hRdrPenAxis = 0
	EndIf
	If $g_hRdrPenGridMajor <> 0 Then
		_GDIPlus_PenDispose($g_hRdrPenGridMajor)
		$g_hRdrPenGridMajor = 0
	EndIf
	If $g_hRdrPenGridMinor <> 0 Then
		_GDIPlus_PenDispose($g_hRdrPenGridMinor)
		$g_hRdrPenGridMinor = 0
	EndIf
	If $g_hRdrPenAccent <> 0 Then
		_GDIPlus_PenDispose($g_hRdrPenAccent)
		$g_hRdrPenAccent = 0
	EndIf
	If $g_hRdrBrushText <> 0 Then
		_GDIPlus_BrushDispose($g_hRdrBrushText)
		$g_hRdrBrushText = 0
	EndIf
	If $g_hRdrFormatCenter <> 0 Then
		_GDIPlus_StringFormatDispose($g_hRdrFormatCenter)
		$g_hRdrFormatCenter = 0
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

	Renderer_DrawGrid()
	Renderer_DrawBox()
	Renderer_DrawHoverZone()
	Renderer_DrawSeparators()
	Renderer_DrawZoneLabels()
	Renderer_DrawHud()

	Renderer_Present()
EndFunc   ;==>Renderer_Frame

; -----------------------------------------------------------------------------
; Choix du pas de grille (mm) selon le zoom : le plus petit pas de la
; progression 1-5-10-50-100-… dont l'espacement écran reste lisible.
; -----------------------------------------------------------------------------
Func Renderer_PickGridStep()
	Local Static $aSteps[8] = [1, 5, 10, 50, 100, 500, 1000, 5000]
	For $i = 0 To UBound($aSteps) - 1
		If Camera_MmToPx($aSteps[$i]) >= $RDR_GRID_MIN_SPACING_PX Then Return $aSteps[$i]
	Next
	Return $aSteps[UBound($aSteps) - 1]
EndFunc   ;==>Renderer_PickGridStep

; -----------------------------------------------------------------------------
; Grille millimétrique adaptative + axes de l'origine.
; Lignes fines au pas courant, lignes majeures tous les 10 pas, axes X=0/Y=0.
; -----------------------------------------------------------------------------
Func Renderer_DrawGrid()
	Local $fStep = Renderer_PickGridStep()

	; Bornes monde visibles. Axe Y inversé : le bas de l'écran porte le Y
	; monde MINIMAL — on itère toujours du min vers le max.
	Local $fLeft = Camera_ScreenToWorldX(0)
	Local $fRight = Camera_ScreenToWorldX($g_iRdrW)
	Local $fYMin = Camera_ScreenToWorldY($g_iRdrH)
	Local $fYMax = Camera_ScreenToWorldY(0)

	Local $hPen

	; Lignes verticales.
	Local $fX = Floor($fLeft / $fStep) * $fStep
	While $fX <= $fRight
		Local $iPx = Camera_WorldToScreenX($fX)
		$hPen = (Mod(Camera_RoundSigned($fX / $fStep), 10) = 0) ? $g_hRdrPenGridMajor : $g_hRdrPenGridMinor
		_GDIPlus_GraphicsDrawLine($g_hRdrGfx, $iPx, 0, $iPx, $g_iRdrH, $hPen)
		$fX += $fStep
	WEnd

	; Lignes horizontales.
	Local $fY = Floor($fYMin / $fStep) * $fStep
	While $fY <= $fYMax
		Local $iPy = Camera_WorldToScreenY($fY)
		$hPen = (Mod(Camera_RoundSigned($fY / $fStep), 10) = 0) ? $g_hRdrPenGridMajor : $g_hRdrPenGridMinor
		_GDIPlus_GraphicsDrawLine($g_hRdrGfx, 0, $iPy, $g_iRdrW, $iPy, $hPen)
		$fY += $fStep
	WEnd

	; Axes de l'origine monde (0, 0).
	If $fLeft <= 0 And $fRight >= 0 Then
		Local $iAxisX = Camera_WorldToScreenX(0)
		_GDIPlus_GraphicsDrawLine($g_hRdrGfx, $iAxisX, 0, $iAxisX, $g_iRdrH, $g_hRdrPenAxis)
	EndIf
	If $fYMin <= 0 And $fYMax >= 0 Then
		Local $iAxisY = Camera_WorldToScreenY(0)
		_GDIPlus_GraphicsDrawLine($g_hRdrGfx, 0, $iAxisY, $g_iRdrW, $iAxisY, $g_hRdrPenAxis)
	EndIf
EndFunc   ;==>Renderer_DrawGrid

; -----------------------------------------------------------------------------
; Helper générique : rectangle monde (mm) → écran, rempli et/ou contouré.
; Chaque bord est snappé individuellement par le même chemin d'arrondi que
; tout le reste du rendu : les rectangles adjacents coïncident au pixel près.
; Passer 0 pour ignorer le brush ou le pen.
; -----------------------------------------------------------------------------
Func Renderer_DrawWorldRect($fXmm, $fYmm, $fWmm, $fHmm, $hBrush, $hPen)
	Local $iX0 = Camera_WorldToScreenX($fXmm)
	Local $iX1 = Camera_WorldToScreenX($fXmm + $fWmm)
	; Axe Y inversé à l'affichage : le haut écran du rectangle correspond au
	; Y monde le plus GRAND ($fYmm + $fHmm).
	Local $iY0 = Camera_WorldToScreenY($fYmm + $fHmm)
	Local $iY1 = Camera_WorldToScreenY($fYmm)
	; Taille écran minimale de 1 px : une dimension monde non nulle reste
	; toujours visible, même très dézoomée (cf. pratiques §6, Render_ScaledSize).
	Local $iW = $iX1 - $iX0
	Local $iH = $iY1 - $iY0
	If $iW < 1 And $fWmm > 0 Then $iW = 1
	If $iH < 1 And $fHmm > 0 Then $iH = 1
	If $hBrush <> 0 Then _GDIPlus_GraphicsFillRect($g_hRdrGfx, $iX0, $iY0, $iW, $iH, $hBrush)
	If $hPen <> 0 Then _GDIPlus_GraphicsDrawRect($g_hRdrGfx, $iX0, $iY0, $iW, $iH, $hPen)
EndFunc   ;==>Renderer_DrawWorldRect

; -----------------------------------------------------------------------------
; Boîte : parois pleines entre le rectangle extérieur et l'intérieur.
; Le renderer ne fait que LIRE le modèle (aucune logique métier).
; -----------------------------------------------------------------------------
Func Renderer_DrawBox()
	; Rectangles monde fournis par les données (l'origine peut être non nulle
	; pendant un drag de bord : le renderer n'en sait rien, il dessine).
	Local $fOx1, $fOy1, $fOx2, $fOy2, $fIx1, $fIy1, $fIx2, $fIy2
	Project_BoxOuter($fOx1, $fOy1, $fOx2, $fOy2)
	Project_BoxInterior($fIx1, $fIy1, $fIx2, $fIy2)

	; Rectangle extérieur rempli (couleur parois) puis intérieur par-dessus :
	; la bande restante visible EST la paroi, sans calcul de 4 rectangles.
	Renderer_DrawWorldRect($fOx1, $fOy1, $fOx2 - $fOx1, $fOy2 - $fOy1, $g_hRdrBrushWall, 0)
	Renderer_DrawWorldRect($fIx1, $fIy1, $fIx2 - $fIx1, $fIy2 - $fIy1, $g_hRdrBrushInterior, $g_hRdrPenBoxLine)
	Renderer_DrawWorldRect($fOx1, $fOy1, $fOx2 - $fOx1, $fOy2 - $fOy1, 0, $g_hRdrPenBoxLine)
EndFunc   ;==>Renderer_DrawBox

; -----------------------------------------------------------------------------
; Voile translucide sur la sous-zone survolée : retour visuel de l'endroit où
; un clic créerait un séparateur. Le renderer LIT l'état de Selection.au3.
; -----------------------------------------------------------------------------
Func Renderer_DrawHoverZone()
	Local $iZone = Selection_GetHoverZone()
	If $iZone < 0 Or $iZone >= Zones_Count() Then Return
	Renderer_DrawWorldRect($g_aZones[$iZone][$ZONE_X1], $g_aZones[$iZone][$ZONE_Y1], _
			$g_aZones[$iZone][$ZONE_X2] - $g_aZones[$iZone][$ZONE_X1], _
			$g_aZones[$iZone][$ZONE_Y2] - $g_aZones[$iZone][$ZONE_Y1], $g_hRdrBrushHover, 0)
EndFunc   ;==>Renderer_DrawHoverZone

; -----------------------------------------------------------------------------
; Séparateurs : un rectangle par segment, à l'épaisseur réelle du layer (mm),
; rempli de la couleur du layer avec un contour assombri. Un séparateur
; sélectionné (directement ou via son groupe) reçoit un contour épais dédié.
; Le renderer ne fait que LIRE le modèle : portées et positions viennent du
; recalcul métier (Zones_Rebuild), jamais d'un calcul local.
; -----------------------------------------------------------------------------
Func Renderer_DrawSeparators()
	For $i = 0 To Project_SepCount() - 1
		Local $iLayer = Project_SepGet($i, $SEP_LAYER)
		Local $iColor = BitOR($RDR_ALPHA_OPAQUE, Project_LayerGet($iLayer, $LAYER_COLOR))
		Local $fThick = Project_LayerGet($iLayer, $LAYER_THICKNESS)
		Local $fPos = Project_SepGet($i, $SEP_POS)
		Local $fS1 = Project_SepGet($i, $SEP_SPAN1)
		Local $fS2 = Project_SepGet($i, $SEP_SPAN2)
		If $fS2 - $fS1 <= 0 Then ContinueLoop ; portée dégénérée : rien à dessiner

		_GDIPlus_BrushSetSolidColor($g_hRdrBrushSep, $iColor)
		_GDIPlus_PenSetColor($g_hRdrPenSepEdge, Renderer_DarkenColor($iColor))

		; Dessin différencié de la sélection (cahier des charges).
		Local $hPen = Selection_IsRowSelected($i) ? $g_hRdrPenSelect : $g_hRdrPenSepEdge

		If Project_SepGet($i, $SEP_ORIENT) = $SEP_ORIENT_V Then
			Renderer_DrawWorldRect($fPos - $fThick / 2, $fS1, $fThick, $fS2 - $fS1, _
					$g_hRdrBrushSep, $hPen)
		Else
			Renderer_DrawWorldRect($fS1, $fPos - $fThick / 2, $fS2 - $fS1, $fThick, _
					$g_hRdrBrushSep, $hPen)
		EndIf
	Next
EndFunc   ;==>Renderer_DrawSeparators

; Format d'affichage d'une valeur en mm : 2 décimales max, sans zéros inutiles.
; Copie locale du pattern déjà dupliqué dans UI_FmtMm/_Zones_FmtToken : le
; Renderer (niveau 3) ne doit pas dépendre de l'UI (niveau 4).
Func _Renderer_FmtMm($fValue)
	Local $s = StringFormat("%.2f", $fValue)
	$s = StringRegExpReplace($s, "0+$", "")
	Return StringRegExpReplace($s, "\.$", "")
EndFunc   ;==>_Renderer_FmtMm

; -----------------------------------------------------------------------------
; Taille des sous-zones, au centre : "largeur × hauteur" affiché seulement si
; le texte tient dans le rectangle écran de la zone. Zones concernées selon
; le mode courant (App_GetZoneLabelMode, réglé par le menu Affichage) :
; aucune / seulement la zone survolée / toutes.
; -----------------------------------------------------------------------------
Func Renderer_DrawZoneLabels()
	Local $iMode = App_GetZoneLabelMode()
	If $iMode = $APP_ZONELABEL_NEVER Then Return

	Local $iHoverZone = Selection_GetHoverZone()
	For $i = 0 To Zones_Count() - 1
		If $iMode = $APP_ZONELABEL_HOVER And $i <> $iHoverZone Then ContinueLoop

		Local $fW = $g_aZones[$i][$ZONE_X2] - $g_aZones[$i][$ZONE_X1]
		Local $fH = $g_aZones[$i][$ZONE_Y2] - $g_aZones[$i][$ZONE_Y1]
		If $fW <= 0 Or $fH <= 0 Then ContinueLoop

		Local $iX0 = Camera_WorldToScreenX($g_aZones[$i][$ZONE_X1])
		Local $iX1 = Camera_WorldToScreenX($g_aZones[$i][$ZONE_X2])
		; Axe Y inversé à l'écran : le haut du rectangle correspond au Y monde max.
		Local $iY0 = Camera_WorldToScreenY($g_aZones[$i][$ZONE_Y2])
		Local $iY1 = Camera_WorldToScreenY($g_aZones[$i][$ZONE_Y1])
		Local $iZoneW = $iX1 - $iX0
		Local $iZoneH = $iY1 - $iY0

		Local $sText = _Renderer_FmtMm($fW) & " × " & _Renderer_FmtMm($fH)
		Local $tLayout = _GDIPlus_RectFCreate($iX0, $iY0, $iZoneW, $iZoneH)
		Local $aInfo = _GDIPlus_GraphicsMeasureString($g_hRdrGfx, $sText, $g_hRdrFontUi, $tLayout, $g_hRdrFormatDefault)
		If DllStructGetData($aInfo[0], "Width") + 4 > $iZoneW Then ContinueLoop
		If DllStructGetData($aInfo[0], "Height") + 4 > $iZoneH Then ContinueLoop

		_GDIPlus_GraphicsDrawStringEx($g_hRdrGfx, $sText, $g_hRdrFontUi, $tLayout, $g_hRdrFormatCenter, $g_hRdrBrushText)
	Next
EndFunc   ;==>Renderer_DrawZoneLabels

; Assombrit une couleur ARGB de moitié (contours des séparateurs).
Func Renderer_DarkenColor($iArgb)
	Local $iR = BitShift(BitAND($iArgb, 0x00FF0000), 17) ; composante /2
	Local $iG = BitShift(BitAND($iArgb, 0x0000FF00), 9)
	Local $iB = BitShift(BitAND($iArgb, 0x000000FF), 1)
	Return BitOR($RDR_ALPHA_OPAQUE, BitShift($iR, -16), BitShift($iG, -8), $iB)
EndFunc   ;==>Renderer_DarkenColor

; -----------------------------------------------------------------------------
; HUD : informations d'état en haut à gauche du canvas (zoom, pas de grille).
; -----------------------------------------------------------------------------
Func Renderer_DrawHud()
	Local $sInfo = StringFormat("zoom : %.2f px/mm   |   grille : %d mm   |   séparateurs : %d   |   sous-zones : %d", _
			Camera_GetZoom(), Renderer_PickGridStep(), Project_SepCount(), Zones_Count())
	Local $tLayout = _GDIPlus_RectFCreate(10, 8, $g_iRdrW - 20, 24)
	_GDIPlus_GraphicsDrawStringEx($g_hRdrGfx, $sInfo, $g_hRdrFontUi, $tLayout, _
			$g_hRdrFormatDefault, $g_hRdrBrushText)
EndFunc   ;==>Renderer_DrawHud

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
