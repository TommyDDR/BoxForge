#include-once

; =============================================================================
; Camera.au3 — Caméra 2D : conversion monde (mm) ↔ écran (pixels).
;
; Niveau : affichage (aucune logique métier, aucune dépendance UI/GDI+).
;
; Principes :
;   - TOUTES les coordonnées du modèle sont en millimètres (monde).
;   - Le zoom n'agit que sur l'affichage : il exprime des pixels par mm.
;   - Helpers de conversion CENTRALISÉS : jamais de multiplication inline
;     dispersée dans le code de rendu (cf. pratiques §6).
;   - Arrondi SIGNÉ pour le snapping écran : Int(x+0.5) n'est pas un arrondi
;     pour x négatif — deux couches dessinées via deux chemins d'arrondi
;     différents divergeraient d'1 px (cf. pratiques §6, piège Int()).
;
; Repère : vue de dessus du tiroir. X monde → droite écran, Y monde → bas
; écran. Le point ($g_fCamCenterX, $g_fCamCenterY) est affiché au centre du
; viewport.
; =============================================================================

; --- Limites et pas du zoom ---
Global Const $CAM_ZOOM_MIN  = 0.05 ; px/mm (très dézoomé)
Global Const $CAM_ZOOM_MAX  = 50.0 ; px/mm (très zoomé)
Global Const $CAM_ZOOM_STEP = 1.15 ; facteur par cran de molette

; --- État de la caméra ---
Global $g_fCamCenterX = 0.0 ; point monde (mm) affiché au centre du viewport
Global $g_fCamCenterY = 0.0
Global $g_fCamZoom    = 1.0 ; pixels par millimètre
Global $g_iCamViewW   = 1   ; taille du viewport (pixels)
Global $g_iCamViewH   = 1

; -----------------------------------------------------------------------------
; Viewport : la caméra reçoit la taille du canvas (elle n'interroge pas l'UI).
; -----------------------------------------------------------------------------
Func Camera_SetViewport($iW, $iH)
	If $iW < 1 Then $iW = 1
	If $iH < 1 Then $iH = 1
	$g_iCamViewW = $iW
	$g_iCamViewH = $iH
EndFunc   ;==>Camera_SetViewport

Func Camera_GetZoom()
	Return $g_fCamZoom
EndFunc   ;==>Camera_GetZoom

; -----------------------------------------------------------------------------
; Arrondi signé : arrondit au plus proche pour x positif ET négatif.
; TOUTE conversion monde→écran passe par cet arrondi (un seul chemin d'arrondi).
; -----------------------------------------------------------------------------
Func Camera_RoundSigned($fValue)
	If $fValue >= 0 Then Return Int($fValue + 0.5)
	Return Int($fValue - 0.5)
EndFunc   ;==>Camera_RoundSigned

; --- Conversions monde (mm) → écran (px, snappé au pixel) -------------------
Func Camera_WorldToScreenX($fXmm)
	Return Camera_RoundSigned(($fXmm - $g_fCamCenterX) * $g_fCamZoom + $g_iCamViewW / 2)
EndFunc   ;==>Camera_WorldToScreenX

Func Camera_WorldToScreenY($fYmm)
	Return Camera_RoundSigned(($fYmm - $g_fCamCenterY) * $g_fCamZoom + $g_iCamViewH / 2)
EndFunc   ;==>Camera_WorldToScreenY

; --- Conversions écran (px) → monde (mm, flottant) ---------------------------
Func Camera_ScreenToWorldX($iPx)
	Return ($iPx - $g_iCamViewW / 2) / $g_fCamZoom + $g_fCamCenterX
EndFunc   ;==>Camera_ScreenToWorldX

Func Camera_ScreenToWorldY($iPx)
	Return ($iPx - $g_iCamViewH / 2) / $g_fCamZoom + $g_fCamCenterY
EndFunc   ;==>Camera_ScreenToWorldY

; Longueur mm → pixels (flottant, non snappé : à snapper au point d'usage).
Func Camera_MmToPx($fMm)
	Return $fMm * $g_fCamZoom
EndFunc   ;==>Camera_MmToPx

; -----------------------------------------------------------------------------
; Zoom d'un ou plusieurs crans, centré sur un point écran : le point monde
; situé sous le curseur reste exactement sous le curseur après zoom.
; -----------------------------------------------------------------------------
Func Camera_ZoomAt($iScreenX, $iScreenY, $iSteps)
	; Point monde sous le curseur AVANT zoom.
	Local $fWorldX = Camera_ScreenToWorldX($iScreenX)
	Local $fWorldY = Camera_ScreenToWorldY($iScreenY)

	; Nouveau zoom, clampé.
	$g_fCamZoom = $g_fCamZoom * ($CAM_ZOOM_STEP ^ $iSteps)
	If $g_fCamZoom < $CAM_ZOOM_MIN Then $g_fCamZoom = $CAM_ZOOM_MIN
	If $g_fCamZoom > $CAM_ZOOM_MAX Then $g_fCamZoom = $CAM_ZOOM_MAX

	; Recale le centre pour que ($fWorldX, $fWorldY) reste sous le curseur.
	$g_fCamCenterX = $fWorldX - ($iScreenX - $g_iCamViewW / 2) / $g_fCamZoom
	$g_fCamCenterY = $fWorldY - ($iScreenY - $g_iCamViewH / 2) / $g_fCamZoom
EndFunc   ;==>Camera_ZoomAt

; -----------------------------------------------------------------------------
; Pan : déplace la vue d'un delta exprimé en pixels écran.
; Un drag de +N px vers la droite fait suivre le contenu → le centre recule.
; -----------------------------------------------------------------------------
Func Camera_PanByPixels($iDxPx, $iDyPx)
	$g_fCamCenterX = $g_fCamCenterX - $iDxPx / $g_fCamZoom
	$g_fCamCenterY = $g_fCamCenterY - $iDyPx / $g_fCamZoom
EndFunc   ;==>Camera_PanByPixels

; -----------------------------------------------------------------------------
; Cadre un rectangle monde (mm) dans le viewport avec une marge relative.
; Utilisé pour centrer la boîte à l'ouverture d'un projet.
; -----------------------------------------------------------------------------
Func Camera_FitRect($fXmm, $fYmm, $fWmm, $fHmm, $fMarginRatio = 0.08)
	If $fWmm <= 0 Or $fHmm <= 0 Then Return

	Local $fPaddedW = $fWmm * (1 + 2 * $fMarginRatio)
	Local $fPaddedH = $fHmm * (1 + 2 * $fMarginRatio)

	Local $fZoomX = $g_iCamViewW / $fPaddedW
	Local $fZoomY = $g_iCamViewH / $fPaddedH
	$g_fCamZoom = ($fZoomX < $fZoomY) ? $fZoomX : $fZoomY
	If $g_fCamZoom < $CAM_ZOOM_MIN Then $g_fCamZoom = $CAM_ZOOM_MIN
	If $g_fCamZoom > $CAM_ZOOM_MAX Then $g_fCamZoom = $CAM_ZOOM_MAX

	$g_fCamCenterX = $fXmm + $fWmm / 2
	$g_fCamCenterY = $fYmm + $fHmm / 2
EndFunc   ;==>Camera_FitRect
