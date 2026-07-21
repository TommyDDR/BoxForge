#include-once

; =============================================================================
; Settings.au3 — Réglages applicatifs persistés (niveau 5 : persistance).
;
; Distinct de ProjectIO.au3 : ce module ne stocke JAMAIS de données de projet
; (boîte, layers, séparateurs), seulement l'état fenêtre et les préférences
; d'affichage. Sans dépendance vers un autre module du projet (comme App.au3
; côté état transversal) : Main.au3 lit les valeurs chargées et les applique
; lui-même via les fonctions publiques de UI.au3.
;
; Fichier : @AppDataDir & "\BoxForge\settings.ini" — hors du dépôt de projet,
; convention Windows standard pour des préférences utilisateur.
; =============================================================================

Global Const $SET_DIR  = @AppDataDir & "\BoxForge"
Global Const $SET_PATH = $SET_DIR & "\settings.ini"

; --- Valeurs chargées (répliques locales, lues via les getters ci-dessous) ---
Global $g_iSetWinX = -1 ; -1 = pas de position sauvegardée (laisser Windows centrer)
Global $g_iSetWinY = -1
Global $g_iSetWinW = -1
Global $g_iSetWinH = -1
Global $g_bSetWinMaximized  = False
Global $g_bSetLayerSimpleView = False
Global $g_iSetZoneLabelMode   = 1 ; $APP_ZONELABEL_HOVER (App.au3) — valeur dupliquée pour ne pas créer de dépendance
; Dernier séparateur principal utilisé (Génération > Séparateur principal) :
; réglage "menu uniquement" (cf. UI.au3) qu'un NOUVEAU projet reprend tel
; quel — la valeur d'un projet OUVERT, elle, vient du fichier .bfp lui-même
; (cf. ProjectIO.au3). 1 = $SEP_ORIENT_H (Box.au3) — valeur dupliquée pour ne
; pas créer de dépendance.
Global $g_iSetMainSepOrient   = 1
; Mêmes réglages "menu uniquement" que $g_iSetMainSepOrient ci-dessus (valeurs
; dupliquées pour ne pas créer de dépendance vers Box.au3) : dernier choix
; repris par un NOUVEAU projet — un projet OUVERT garde sa propre valeur,
; lue depuis le fichier .bfp (cf. ProjectIO.au3).
Global $g_bSetGenerateStructure = True
Global $g_bSetShowDxfLabels     = True
Global $g_bSetShowSepTooltips   = False

; -----------------------------------------------------------------------------
; Charge les réglages depuis le fichier (silencieux si absent : valeurs par
; défaut ci-dessus conservées).
; -----------------------------------------------------------------------------
Func Settings_Load()
	$g_iSetWinX = Int(Number(IniRead($SET_PATH, "Window", "X", -1)))
	$g_iSetWinY = Int(Number(IniRead($SET_PATH, "Window", "Y", -1)))
	$g_iSetWinW = Int(Number(IniRead($SET_PATH, "Window", "W", -1)))
	$g_iSetWinH = Int(Number(IniRead($SET_PATH, "Window", "H", -1)))
	$g_bSetWinMaximized = (IniRead($SET_PATH, "Window", "Maximized", "0") = "1")

	$g_bSetLayerSimpleView = (IniRead($SET_PATH, "View", "LayerSimpleView", "0") = "1")
	Local $iMode = Int(Number(IniRead($SET_PATH, "View", "ZoneLabelMode", 1)))
	$g_iSetZoneLabelMode = ($iMode >= 0 And $iMode <= 2) ? $iMode : 1

	Local $iMainSep = Int(Number(IniRead($SET_PATH, "View", "MainSepOrient", 1)))
	$g_iSetMainSepOrient = ($iMainSep = 0 Or $iMainSep = 1) ? $iMainSep : 1

	$g_bSetGenerateStructure = (IniRead($SET_PATH, "View", "GenerateStructure", "1") = "1")
	$g_bSetShowDxfLabels = (IniRead($SET_PATH, "View", "ShowDxfLabels", "1") = "1")
	$g_bSetShowSepTooltips = (IniRead($SET_PATH, "View", "ShowSepTooltips", "0") = "1")
EndFunc   ;==>Settings_Load

; --- Accès à la position/taille fenêtre sauvegardées -------------------------
; $bValid : True si une position/taille valide a été chargée (sinon les
; ByRef ne sont pas modifiés — l'appelant garde la disposition de création).
Func Settings_GetWindowRect(ByRef $iX, ByRef $iY, ByRef $iW, ByRef $iH, ByRef $bMaximized)
	If $g_iSetWinW <= 0 Or $g_iSetWinH <= 0 Then Return False
	$iX = $g_iSetWinX
	$iY = $g_iSetWinY
	$iW = $g_iSetWinW
	$iH = $g_iSetWinH
	$bMaximized = $g_bSetWinMaximized
	Return True
EndFunc   ;==>Settings_GetWindowRect

Func Settings_GetLayerSimpleView()
	Return $g_bSetLayerSimpleView
EndFunc   ;==>Settings_GetLayerSimpleView

Func Settings_GetZoneLabelMode()
	Return $g_iSetZoneLabelMode
EndFunc   ;==>Settings_GetZoneLabelMode

Func Settings_GetMainSepOrient()
	Return $g_iSetMainSepOrient
EndFunc   ;==>Settings_GetMainSepOrient

Func Settings_GetGenerateStructure()
	Return $g_bSetGenerateStructure
EndFunc   ;==>Settings_GetGenerateStructure

Func Settings_GetShowDxfLabels()
	Return $g_bSetShowDxfLabels
EndFunc   ;==>Settings_GetShowDxfLabels

Func Settings_GetShowSepTooltips()
	Return $g_bSetShowSepTooltips
EndFunc   ;==>Settings_GetShowSepTooltips

; -----------------------------------------------------------------------------
; Sauvegarde l'état courant (écrasement complet, une seule passe).
; -----------------------------------------------------------------------------
Func Settings_Save($iX, $iY, $iW, $iH, $bMaximized, $bLayerSimpleView, $iZoneLabelMode, $iMainSepOrient, _
		$bGenerateStructure, $bShowDxfLabels, $bShowSepTooltips)
	If Not FileExists($SET_DIR) Then DirCreate($SET_DIR)

	IniWrite($SET_PATH, "Window", "X", $iX)
	IniWrite($SET_PATH, "Window", "Y", $iY)
	IniWrite($SET_PATH, "Window", "W", $iW)
	IniWrite($SET_PATH, "Window", "H", $iH)
	IniWrite($SET_PATH, "Window", "Maximized", $bMaximized ? "1" : "0")

	IniWrite($SET_PATH, "View", "LayerSimpleView", $bLayerSimpleView ? "1" : "0")
	IniWrite($SET_PATH, "View", "ZoneLabelMode", $iZoneLabelMode)
	IniWrite($SET_PATH, "View", "MainSepOrient", $iMainSepOrient)
	IniWrite($SET_PATH, "View", "GenerateStructure", $bGenerateStructure ? "1" : "0")
	IniWrite($SET_PATH, "View", "ShowDxfLabels", $bShowDxfLabels ? "1" : "0")
	IniWrite($SET_PATH, "View", "ShowSepTooltips", $bShowSepTooltips ? "1" : "0")
EndFunc   ;==>Settings_Save
