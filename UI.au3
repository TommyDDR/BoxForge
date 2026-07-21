#include-once
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <WinAPI.au3>
#include <WinAPISysInternals.au3>
#include <ListViewConstants.au3>
#include <GuiListView.au3>
#include <GuiImageList.au3>
#include <StaticConstants.au3>
#include <Misc.au3>
#include <ComboConstants.au3>
#include <GuiComboBox.au3>
#include <MsgBoxConstants.au3>
#include <FileConstants.au3>
#include "App.au3"
#include "Project.au3"
#include "Zones.au3"
#include "Selection.au3"
#include "Camera.au3"
#include "ProjectIO.au3"
#include "DXF.au3"
#include "Undo.au3"

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

; --- Contrôles du panneau Propriétés : section Layer actif ---
; ($g_aidUiLayerInputs est indexé comme les champs Layer ; l'entrée COLOR
;  n'est pas un input texte mais un bouton dédié → slot inutilisé à 0.)
Global $g_aidUiLayerInputs[$LAYER_FIELD_COUNT]
Global $g_idUiLayerSectionTitle = 0
Global $g_idUiLayerColorBtn     = 0
Global $g_idUiLayerColorSwatch  = 0
Global $g_idUiBtnApplyLayer     = 0

; --- Contrôles du panneau Propriétés : section Séparateur sélectionné ---
; Visible uniquement quand un séparateur est sélectionné. Les contrôles sont
; recensés dans $g_aidUiSepCtrls pour être montrés/masqués d'un bloc.
Global $g_aidUiSepCtrls[0]
Global $g_idUiSepTitle       = 0 ; "Séparateur #n (vertical)"
Global $g_idUiSepPosInput    = 0 ; position : nombre OU formule "s1.pos + 20"
Global $g_idUiSepPosEff      = 0 ; position effective calculée (lecture seule)
Global $g_idUiSepLenValue    = 0 ; longueur (dérivée, lecture seule)
Global $g_idUiSepLayerCombo  = 0 ; layer du séparateur (éditable)
Global $g_idUiSepGroupValue  = 0 ; groupe SHIFT éventuel
Global $g_idUiBtnSepApplyPos = 0
Global $g_idUiBtnSepDelete   = 0

; --- Panneau du bas : liste des layers ---
; Deux représentations possibles (menu Affichage) : la liste détaillée
; (colonnes + icône de couleur) ou une grille de pastilles colorées.
Global $g_idUiLayerList     = 0
Global $g_aidUiLayerItems[$LAYERS_COUNT]
Global $g_hUiLayerImgList   = 0 ; imagelist des icônes de couleur (vue détaillée)
Global $g_bUiLayerSimpleView = False
Global $g_aidUiLayerSwatchFill[$LAYERS_COUNT]   ; pastille cliquable (couleur du layer)
Global $g_aidUiLayerSwatchBorder[$LAYERS_COUNT] ; cadre autour de la pastille (surbrillance active)

; --- Layer actif (état d'édition UI : layer des futurs séparateurs) ---
Global $g_iUiActiveLayer = 0

; --- Menu principal ---
Global $g_idUiMenuNew    = 0
Global $g_idUiMenuOpen   = 0
Global $g_idUiMenuSave   = 0
Global $g_idUiMenuSaveAs = 0
Global $g_idUiMenuQuit   = 0
Global $g_idUiMenuFit    = 0
Global $g_idUiMenuLayerSimpleView = 0
Global $g_idUiMenuDxf    = 0
Global $g_idUiMenuMainSepH = 0 ; Génération > Séparateur principal > Horizontal
Global $g_idUiMenuMainSepV = 0 ; Génération > Séparateur principal > Vertical
Global $g_idUiMenuGenStructure = 0 ; Génération > Boîte de structure
Global $g_idUiMenuDxfLabels    = 0 ; Génération > Noms des pièces dans le DXF
Global $g_idUiMenuSepTooltips  = 0 ; Affichage > Noms des séparateurs en permanence
Global $g_idUiMenuUndo = 0
Global $g_idUiMenuRedo = 0

; --- Affichage > Taille des zones (réglage "menu uniquement", cf. cahier des
;     charges) : jamais / au survol / toujours. L'état vit dans App.au3 (lu
;     par Renderer.au3) ; le popup de survol, lui, est TOUJOURS affiché quel
;     que soit ce mode (cf. Input_OnMouseMove). ---
Global $g_idUiMenuZoneNever  = 0
Global $g_idUiMenuZoneHover  = 0
Global $g_idUiMenuZoneAlways = 0

; --- Bulles d'information (popups) ---
; Bulle de survol (canevas) : nom du séparateur/de la boîte survolé.
; Bulle de formule (saisie Position) : traduction + résultat de la formule.
Global $g_hUiHoverTipGui    = 0
Global $g_idUiHoverTipLbl   = 0
Global $g_hUiFormulaTipGui  = 0
Global $g_idUiFormulaTipLbl = 0
Global Const $UI_TOOLTIP_PAD_X  = 6
Global Const $UI_TOOLTIP_PAD_Y  = 4
Global Const $UI_TOOLTIP_LINE_H = 16
Global Const $UI_TOOLTIP_CHAR_W = 7

; --- Demande de fermeture émise par le menu Quitter ---
Global $g_bUiQuitRequested = False

; --- Accélérateurs Haut/Bas (incrément/décrément du champ suivi actif) ---
; Actifs UNIQUEMENT quand un champ suivi a le focus (cf. Input_OnCommand) :
; un accélérateur, contrairement à un polling, intercepte la touche AVANT
; qu'elle n'atteigne le contrôle Edit natif (qui sinon déplace le curseur
; silencieusement — cf. Input_PollKeys). Hors saisie (ex. la combo Layer du
; séparateur), Haut/Bas doivent garder leur comportement natif : la table
; d'accélérateurs est donc reconstruite à chaque bascule plutôt que fixée une
; fois pour toutes.
Global $g_idUiAccelUp   = 0
Global $g_idUiAccelDown = 0
Global $g_bUiUpDownAccelActive = False

; -----------------------------------------------------------------------------
; Création de la fenêtre principale et de ses trois zones.
; -----------------------------------------------------------------------------
Func UI_Create()
	; $WS_CLIPCHILDREN : le fond de la fenêtre principale ne repeint jamais
	; par-dessus les zones enfants (indispensable contre le scintillement).
	$g_hUiMainGui = GUICreate($APP_NAME & " " & $APP_VERSION, $UI_MAIN_START_W, $UI_MAIN_START_H, _
			-1, -1, BitOR($WS_OVERLAPPEDWINDOW, $WS_CLIPCHILDREN))
	GUISetBkColor($UI_COLOR_MAIN_BG, $g_hUiMainGui)
	UI_CreateMenus()

	; Zone de dessin : GUI enfant nue, entièrement repeinte par le renderer.
	$g_hUiCanvasGui = GUICreate("", 100, 100, 0, 0, $WS_CHILD, 0, $g_hUiMainGui)
	GUISetBkColor($UI_COLOR_MAIN_BG, $g_hUiCanvasGui)

	UI_CreatePanelRight()
	UI_CreatePanelBottom()
	UI_TooltipsCreate()

	; Messages fenêtre : anti-scintillement + suivi du redimensionnement.
	GUIRegisterMsg($WM_ERASEBKGND, "UI_OnEraseBkgnd")
	GUIRegisterMsg($WM_SIZE, "UI_OnSize")
	GUIRegisterMsg($WM_PAINT, "UI_OnPaint")

	UI_ApplyLayout()

	GUISetState(@SW_SHOW, $g_hUiCanvasGui)
	GUISetState(@SW_SHOW, $g_hUiPanelRightGui)
	GUISetState(@SW_SHOW, $g_hUiPanelBottomGui)
	GUISetState(@SW_SHOW, $g_hUiMainGui)

	UI_RefreshMainSepOrientMenu()
	UI_RefreshGenerateStructureMenu()
	UI_RefreshShowDxfLabelsMenu()
	UI_RefreshShowSepTooltipsMenu()
	UI_RefreshStructureDependentFields()
	UI_SetZoneLabelMode(App_GetZoneLabelMode()) ; synchronise la coche (Settings_Load peut la resurcharger ensuite)
	UI_UpdateTitle()
EndFunc   ;==>UI_Create

; -----------------------------------------------------------------------------
; Menu principal : Fichier / Affichage / Génération.
; (La génération DXF est câblée à l'étape suivante : entrée désactivée.)
; -----------------------------------------------------------------------------
Func UI_CreateMenus()
	Local $idMenuFile = GUICtrlCreateMenu("&Fichier")
	$g_idUiMenuNew = GUICtrlCreateMenuItem("Nouveau" & @TAB & "Ctrl+N", $idMenuFile)
	$g_idUiMenuOpen = GUICtrlCreateMenuItem("Ouvrir…" & @TAB & "Ctrl+O", $idMenuFile)
	GUICtrlCreateMenuItem("", $idMenuFile) ; séparateur
	$g_idUiMenuSave = GUICtrlCreateMenuItem("Enregistrer" & @TAB & "Ctrl+S", $idMenuFile)
	$g_idUiMenuSaveAs = GUICtrlCreateMenuItem("Enregistrer sous…" & @TAB & "Ctrl+Maj+S", $idMenuFile)
	GUICtrlCreateMenuItem("", $idMenuFile)
	$g_idUiMenuQuit = GUICtrlCreateMenuItem("Quitter", $idMenuFile)

	Local $idMenuEdit = GUICtrlCreateMenu("&Édition")
	$g_idUiMenuUndo = GUICtrlCreateMenuItem("Annuler" & @TAB & "Ctrl+Z", $idMenuEdit)
	$g_idUiMenuRedo = GUICtrlCreateMenuItem("Rétablir" & @TAB & "Ctrl+Y", $idMenuEdit)

	Local $idMenuView = GUICtrlCreateMenu("&Affichage")
	$g_idUiMenuFit = GUICtrlCreateMenuItem("Recentrer sur la boîte", $idMenuView)
	$g_idUiMenuLayerSimpleView = GUICtrlCreateMenuItem("Layers : vue simplifiée", $idMenuView)
	$g_idUiMenuSepTooltips = GUICtrlCreateMenuItem("Noms des séparateurs en permanence", $idMenuView)

	Local $idMenuZoneLabel = GUICtrlCreateMenu("Taille des zones", $idMenuView)
	$g_idUiMenuZoneNever = GUICtrlCreateMenuItem("Jamais", $idMenuZoneLabel)
	$g_idUiMenuZoneHover = GUICtrlCreateMenuItem("Zone survolée", $idMenuZoneLabel)
	$g_idUiMenuZoneAlways = GUICtrlCreateMenuItem("Toujours", $idMenuZoneLabel)

	Local $idMenuGen = GUICtrlCreateMenu("&Génération")
	$g_idUiMenuDxf = GUICtrlCreateMenuItem("Générer le DXF…" & @TAB & "Ctrl+G", $idMenuGen)
	GUICtrlCreateMenuItem("", $idMenuGen) ; séparateur
	$g_idUiMenuGenStructure = GUICtrlCreateMenuItem("Boîte de structure", $idMenuGen)
	$g_idUiMenuDxfLabels = GUICtrlCreateMenuItem("Noms des pièces dans le DXF", $idMenuGen)

	Local $idMenuMainSep = GUICtrlCreateMenu("Séparateur principal", $idMenuGen)
	$g_idUiMenuMainSepH = GUICtrlCreateMenuItem("Horizontal", $idMenuMainSep)
	$g_idUiMenuMainSepV = GUICtrlCreateMenuItem("Vertical", $idMenuMainSep)

	; Contrôles fantômes ciblés par les accélérateurs Haut/Bas (cf.
	; UI_SetUpDownAccelActive) — doivent être créés pendant que $g_hUiMainGui
	; est la GUI active, comme le reste de ce menu.
	$g_idUiAccelUp = GUICtrlCreateDummy()
	$g_idUiAccelDown = GUICtrlCreateDummy()

	UI_RebuildAccelerators()
EndFunc   ;==>UI_CreateMenus

; -----------------------------------------------------------------------------
; (Re)construit la table d'accélérateurs de la fenêtre principale : les
; raccourcis clavier de menu (déclenchent le même id de contrôle qu'un clic
; menu, actifs même si le focus est dans un champ de saisie), et — SEULEMENT
; quand $g_bUiUpDownAccelActive — Haut/Bas (cf. UI_SetUpDownAccelActive).
; -----------------------------------------------------------------------------
Func UI_RebuildAccelerators()
	Local $aBase[7][2] = [ _
			["^n", $g_idUiMenuNew], ["^o", $g_idUiMenuOpen], ["^s", $g_idUiMenuSave], _
			["^+s", $g_idUiMenuSaveAs], ["^g", $g_idUiMenuDxf], _
			["^z", $g_idUiMenuUndo], ["^y", $g_idUiMenuRedo]]

	If Not $g_bUiUpDownAccelActive Then
		GUISetAccelerators($aBase, $g_hUiMainGui)
		Return
	EndIf

	Local $aAccel[9][2]
	For $i = 0 To 6
		$aAccel[$i][0] = $aBase[$i][0]
		$aAccel[$i][1] = $aBase[$i][1]
	Next
	$aAccel[7][0] = "{UP}"
	$aAccel[7][1] = $g_idUiAccelUp
	$aAccel[8][0] = "{DOWN}"
	$aAccel[8][1] = $g_idUiAccelDown
	GUISetAccelerators($aAccel, $g_hUiMainGui)
EndFunc   ;==>UI_RebuildAccelerators

; Active/désactive l'interception Haut/Bas (cf. Input_OnCommand, EN_SETFOCUS/
; EN_KILLFOCUS des champs suivis). Un accélérateur Windows, contrairement à un
; polling, consomme la touche avant qu'elle n'atteigne le contrôle Edit natif
; (qui sinon déplace le curseur silencieusement au passage) — mais il le fait
; pour TOUTE la fenêtre, d'où la bascule : hors saisie d'un champ suivi (ex.
; la combo Layer du séparateur), Haut/Bas doivent garder leur usage natif.
Func UI_SetUpDownAccelActive($bActive)
	If $g_bUiUpDownAccelActive = $bActive Then Return
	$g_bUiUpDownAccelActive = $bActive
	UI_RebuildAccelerators()
EndFunc   ;==>UI_SetUpDownAccelActive

; -----------------------------------------------------------------------------
; Applique le style de docking standard des labels/inputs des panneaux : la
; taille et la distance au bord droit/haut restent fixes quand la fenêtre est
; redimensionnée (sans ça, AutoIt redimensionne/déplace ces contrôles de façon
; proportionnelle par défaut — ils dériveraient au fil des redimensionnements).
; Retourne l'id reçu (permet de chaîner : UI_Dock(GUICtrlCreateLabel(...))).
; -----------------------------------------------------------------------------
Func UI_Dock($idCtrl)
	GUICtrlSetResizing($idCtrl, BitOR($GUI_DOCKSIZE, $GUI_DOCKRIGHT, $GUI_DOCKTOP))
	Return $idCtrl
EndFunc   ;==>UI_Dock

; =============================================================================
; Bulles d'information (popups légers, sans focus) :
;   - bulle de survol : nom du séparateur/de la boîte survolé sur le canevas ;
;   - bulle de formule : traduction + résultat, au-dessus du champ Position
;     pendant la saisie d'une formule.
; Deux instances distinctes (pas une bulle partagée) : les deux contextes
; peuvent être actifs en même temps (survol du canevas pendant une saisie).
; =============================================================================
Func UI_TooltipsCreate()
	UI_TooltipCreateInstance($g_hUiHoverTipGui, $g_idUiHoverTipLbl)
	UI_TooltipCreateInstance($g_hUiFormulaTipGui, $g_idUiFormulaTipLbl)
EndFunc   ;==>UI_TooltipsCreate

Func UI_TooltipCreateInstance(ByRef $hGui, ByRef $idLbl)
	$hGui = GUICreate("", $UI_TOOLTIP_PAD_X*3, $UI_TOOLTIP_PAD_Y*3, -1, -1, BitOR($WS_POPUP, $WS_BORDER), $WS_EX_TOPMOST, $g_hUiMainGui)
	GUISetBkColor($UI_COLOR_PANEL_BG, $hGui)
	$idLbl = GUICtrlCreateLabel("", $UI_TOOLTIP_PAD_X, $UI_TOOLTIP_PAD_Y, $UI_TOOLTIP_PAD_X, $UI_TOOLTIP_PAD_X)
	GUICtrlSetColor($idLbl, $UI_COLOR_TEXT)
	GUICtrlSetBkColor($idLbl, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlSetFont($idLbl, 9)
	GUICtrlSetResizing($idLbl, BitOR($GUI_DOCKLEFT, $GUI_DOCKRIGHT, $GUI_DOCKTOP, $GUI_DOCKBOTTOM))
EndFunc   ;==>UI_TooltipCreateInstance

; Taille (px) nécessaire pour afficher $sText (lignes séparées par @CRLF).
; Mesure approximative (largeur moyenne de caractère) : la police n'étant pas
; à chasse fixe, on préfère une bulle légèrement trop large à un texte tronqué.
Func UI_TooltipMeasure($sText, ByRef $iW, ByRef $iH)
	Local $aLines = StringSplit($sText, @CRLF, 3)
	Local $iMaxLen = 1
	For $i = 0 To UBound($aLines) - 1
		If StringLen($aLines[$i]) > $iMaxLen Then $iMaxLen = StringLen($aLines[$i])
	Next
	$iW = $UI_TOOLTIP_PAD_X * 2.5 + $iMaxLen * $UI_TOOLTIP_CHAR_W
	$iH = $UI_TOOLTIP_PAD_Y * 2.5 + UBound($aLines) * $UI_TOOLTIP_LINE_H
EndFunc   ;==>UI_TooltipMeasure

; Affiche l'instance ($hGui/$idLbl) à la position écran ($iScreenX, $iScreenY)
; = coin haut-gauche. SHOWNOACTIVATE : la bulle n'enlève jamais le focus
; (indispensable pendant une saisie).
Func UI_TooltipShowAt($hGui, $idLbl, $sText, $iScreenX, $iScreenY)
	If $hGui = 0 Then Return
	Local $iW, $iH
	UI_TooltipMeasure($sText, $iW, $iH)
	GUICtrlSetData($idLbl, $sText)
	WinMove($hGui, "", $iScreenX, $iScreenY, $iW, $iH)
	GUISetState(@SW_SHOWNOACTIVATE, $hGui)
EndFunc   ;==>UI_TooltipShowAt

Func UI_TooltipHideInstance($hGui)
	If $hGui = 0 Then Return
	GUISetState(@SW_HIDE, $hGui)
EndFunc   ;==>UI_TooltipHideInstance

; --- Bulle de survol : positionnée près du curseur (coordonnées ÉCRAN) ---
Func UI_HoverTipShow($sText, $iScreenX, $iScreenY)
	UI_TooltipShowAt($g_hUiHoverTipGui, $g_idUiHoverTipLbl, $sText, $iScreenX + 16, $iScreenY + 16)
EndFunc   ;==>UI_HoverTipShow

Func UI_HoverTipHide()
	UI_TooltipHideInstance($g_hUiHoverTipGui)
EndFunc   ;==>UI_HoverTipHide

; --- Bulle de formule : positionnée juste AU-DESSUS du contrôle donné ---
Func UI_FormulaTipShowAboveControl($idCtrl, $sText)
	Local $iW, $iH
	UI_TooltipMeasure($sText, $iW, $iH)
	Local $tRect = _WinAPI_GetWindowRect(GUICtrlGetHandle($idCtrl))
	UI_TooltipShowAt($g_hUiFormulaTipGui, $g_idUiFormulaTipLbl, $sText, _
			DllStructGetData($tRect, "Left"), DllStructGetData($tRect, "Top") - $iH - 4)
EndFunc   ;==>UI_FormulaTipShowAboveControl

Func UI_FormulaTipHide()
	UI_TooltipHideInstance($g_hUiFormulaTipGui)
EndFunc   ;==>UI_FormulaTipHide

; -----------------------------------------------------------------------------
; Génération DXF : demande un chemin puis délègue à l'export (niveau 5).
; -----------------------------------------------------------------------------
Func UI_DoExportDxf()
	; Nom proposé : celui du projet, en .dxf.
	Local $sDefault = StringRegExpReplace(ProjectIO_GetDisplayName(), "(?i)\." & $IO_FILE_EXT & "$", "") & ".dxf"
	Local $sPath = FileSaveDialog("Générer le DXF", "", "Fichier DXF (*.dxf)", _
			$FD_PATHMUSTEXIST, $sDefault, $g_hUiMainGui)
	If @error Then Return ; annulé
	If Not StringRegExp($sPath, "(?i)\.dxf$") Then $sPath &= ".dxf"

	If DXF_Export($sPath) Then
		MsgBox(BitOR($MB_OK, $MB_ICONINFORMATION), $APP_NAME, _
				"DXF généré :" & @CRLF & $sPath, 0, $g_hUiMainGui)
	Else
		MsgBox(BitOR($MB_OK, $MB_ICONERROR), $APP_NAME, _
				"Impossible d'écrire le fichier :" & @CRLF & $sPath, 0, $g_hUiMainGui)
	EndIf
EndFunc   ;==>UI_DoExportDxf

; -----------------------------------------------------------------------------
; Séparateur principal (Génération > Séparateur principal) : réglage "menu
; uniquement" (cahier des charges) — décide quelle orientation reçoit
; l'encoche haute aux croisements de séparateurs (cf. DXF.au3). Coches
; mutuellement exclusives, gérées à la main (pas de radio-menu natif AutoIt).
; -----------------------------------------------------------------------------
Func UI_SetMainSepOrient($iOrient)
	If Project_BoxGet($BOX_MAIN_SEP_ORIENT) = $iOrient Then Return ; rien ne change : pas d'entrée Annuler
	Undo_PushSnapshot()
	If Not Project_BoxSet($BOX_MAIN_SEP_ORIENT, $iOrient) Then Return
	UI_RefreshMainSepOrientMenu()
	UI_MarkProjectModified()
EndFunc   ;==>UI_SetMainSepOrient

; Applique l'orientation SANS marquer le projet modifié : utilisé pour semer
; un projet FRAÎCHEMENT créé (démarrage, Nouveau) avec le dernier choix de
; l'utilisateur (cf. Settings_GetMainSepOrient) — ce n'est pas une action de
; l'utilisateur sur CE projet, donc pas une modification à signaler/enregistrer.
; Un projet OUVERT, lui, reprend sa propre valeur sauvegardée (ProjectIO.au3).
Func UI_SeedMainSepOrient($iOrient)
	If Not Project_BoxSet($BOX_MAIN_SEP_ORIENT, $iOrient) Then Return
	UI_RefreshMainSepOrientMenu()
EndFunc   ;==>UI_SeedMainSepOrient

Func UI_RefreshMainSepOrientMenu()
	Local $iOrient = Project_BoxGet($BOX_MAIN_SEP_ORIENT)
	GUICtrlSetState($g_idUiMenuMainSepH, ($iOrient = $SEP_ORIENT_H) ? $GUI_CHECKED : $GUI_UNCHECKED)
	GUICtrlSetState($g_idUiMenuMainSepV, ($iOrient = $SEP_ORIENT_V) ? $GUI_CHECKED : $GUI_UNCHECKED)
EndFunc   ;==>UI_RefreshMainSepOrientMenu

; -----------------------------------------------------------------------------
; Génération > Boîte de structure (cahier des charges) : réglage "menu
; uniquement", persisté avec le projet ET comme dernier choix (mêmes règles
; que le séparateur principal ci-dessus). Désactivée : le fond et les 4 côtés
; ne sont plus générés/affichés (seuls les séparateurs le sont), les
; extrémités de séparateur contre une paroi restent pleines (pas d'encoche de
; fixation) et leurs créneaux traversants inférieurs disparaissent
; (cf. DXF.au3) — les champs "créneau" de la boîte et du layer actif n'ont
; alors plus d'effet et sont grisés (cf. UI_RefreshStructureDependentFields).
; Bascule l'épaisseur EFFECTIVE (cf. Box_EffectiveThickness) entre sa valeur
; réelle et 0 : Metier_OnBoxChanged reclampe séparateurs/formules et recalcule
; les sous-zones ($g_aZones) sur ce nouvel intérieur — sans cet appel, zones
; et séparateurs resteraient affichés avec l'ancien retrait tant qu'aucun
; autre événement (redimensionnement, etc.) ne force un recalcul ; le fond
; gris (cf. Renderer_DrawBox), lui, est recalculé à chaque frame et suit donc
; immédiatement, mais doit rester visuellement cohérent avec les zones.
; -----------------------------------------------------------------------------
Func UI_SetGenerateStructure($bOn)
	If Project_BoxGet($BOX_GENERATE_STRUCTURE) = $bOn Then Return
	Undo_PushSnapshot()
	If Not Project_BoxSet($BOX_GENERATE_STRUCTURE, $bOn) Then Return
	Metier_OnBoxChanged() ; ré-ancre séparateurs/zones sur le nouvel intérieur (épaisseur effective)
	UI_RefreshGenerateStructureMenu()
	UI_RefreshStructureDependentFields()
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>UI_SetGenerateStructure

Func UI_ToggleGenerateStructure()
	UI_SetGenerateStructure(Not Project_BoxGet($BOX_GENERATE_STRUCTURE))
EndFunc   ;==>UI_ToggleGenerateStructure

; Sème un projet FRAÎCHEMENT créé avec le dernier choix (cf. UI_SeedMainSepOrient) —
; pas une action de l'utilisateur sur CE projet, donc pas de modification signalée.
Func UI_SeedGenerateStructure($bOn)
	If Not Project_BoxSet($BOX_GENERATE_STRUCTURE, $bOn) Then Return
	Metier_OnBoxChanged() ; cf. UI_SetGenerateStructure : zones/séparateurs sur le bon intérieur dès la création
	UI_RefreshGenerateStructureMenu()
	UI_RefreshStructureDependentFields()
EndFunc   ;==>UI_SeedGenerateStructure

Func UI_RefreshGenerateStructureMenu()
	GUICtrlSetState($g_idUiMenuGenStructure, Project_BoxGet($BOX_GENERATE_STRUCTURE) ? $GUI_CHECKED : $GUI_UNCHECKED)
EndFunc   ;==>UI_RefreshGenerateStructureMenu

; Grise les champs "créneau" de la boîte et du layer actif quand la boîte de
; structure est désactivée (plus aucun effet sur la génération, cf. ci-dessus).
Func UI_RefreshStructureDependentFields()
	Local $iState = Project_BoxGet($BOX_GENERATE_STRUCTURE) ? $GUI_ENABLE : $GUI_DISABLE
	GUICtrlSetState($g_aidUiBoxInputs[$BOX_THICKNESS], $iState)
	GUICtrlSetState($g_aidUiBoxInputs[$BOX_FINGER_LEN], $iState)
	GUICtrlSetState($g_aidUiBoxInputs[$BOX_FINGER_SPACING], $iState)
	GUICtrlSetState($g_aidUiLayerInputs[$LAYER_FINGER_LEN], $iState)
	GUICtrlSetState($g_aidUiLayerInputs[$LAYER_FINGER_SPACING], $iState)
EndFunc   ;==>UI_RefreshStructureDependentFields

; -----------------------------------------------------------------------------
; Génération > Noms des pièces dans le DXF (cahier des charges) : réglage
; "menu uniquement", mêmes règles de persistance que ci-dessus. N'affecte que
; l'export (cf. DXF.au3) — pas de rafraîchissement du canevas nécessaire.
; -----------------------------------------------------------------------------
Func UI_SetShowDxfLabels($bOn)
	If Project_BoxGet($BOX_SHOW_DXF_LABELS) = $bOn Then Return
	Undo_PushSnapshot()
	If Not Project_BoxSet($BOX_SHOW_DXF_LABELS, $bOn) Then Return
	UI_RefreshShowDxfLabelsMenu()
	UI_MarkProjectModified()
EndFunc   ;==>UI_SetShowDxfLabels

Func UI_ToggleShowDxfLabels()
	UI_SetShowDxfLabels(Not Project_BoxGet($BOX_SHOW_DXF_LABELS))
EndFunc   ;==>UI_ToggleShowDxfLabels

Func UI_SeedShowDxfLabels($bOn)
	If Not Project_BoxSet($BOX_SHOW_DXF_LABELS, $bOn) Then Return
	UI_RefreshShowDxfLabelsMenu()
EndFunc   ;==>UI_SeedShowDxfLabels

Func UI_RefreshShowDxfLabelsMenu()
	GUICtrlSetState($g_idUiMenuDxfLabels, Project_BoxGet($BOX_SHOW_DXF_LABELS) ? $GUI_CHECKED : $GUI_UNCHECKED)
EndFunc   ;==>UI_RefreshShowDxfLabelsMenu

; -----------------------------------------------------------------------------
; Affichage > Noms des séparateurs en permanence (cahier des charges) : réglage
; "menu uniquement", mêmes règles de persistance que ci-dessus. Lu par
; Renderer.au3 (cf. Renderer_DrawSeparatorLabels) ; la bulle de survol reste
; toujours active quel que soit ce réglage (cf. Input_OnMouseMove).
; -----------------------------------------------------------------------------
Func UI_SetShowSepTooltips($bOn)
	If Project_BoxGet($BOX_SHOW_SEP_TOOLTIPS) = $bOn Then Return
	Undo_PushSnapshot()
	If Not Project_BoxSet($BOX_SHOW_SEP_TOOLTIPS, $bOn) Then Return
	UI_RefreshShowSepTooltipsMenu()
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>UI_SetShowSepTooltips

Func UI_ToggleShowSepTooltips()
	UI_SetShowSepTooltips(Not Project_BoxGet($BOX_SHOW_SEP_TOOLTIPS))
EndFunc   ;==>UI_ToggleShowSepTooltips

Func UI_SeedShowSepTooltips($bOn)
	If Not Project_BoxSet($BOX_SHOW_SEP_TOOLTIPS, $bOn) Then Return
	UI_RefreshShowSepTooltipsMenu()
EndFunc   ;==>UI_SeedShowSepTooltips

Func UI_RefreshShowSepTooltipsMenu()
	GUICtrlSetState($g_idUiMenuSepTooltips, Project_BoxGet($BOX_SHOW_SEP_TOOLTIPS) ? $GUI_CHECKED : $GUI_UNCHECKED)
EndFunc   ;==>UI_RefreshShowSepTooltipsMenu

; -----------------------------------------------------------------------------
; Mode d'affichage de la taille des zones (Affichage > Taille des zones) :
; réglage "menu uniquement", persisté avec l'état fenêtre (cf. Settings.au3),
; PAS avec le projet (c'est une préférence d'affichage, pas une donnée
; métier). Le popup de survol reste toujours actif quel que soit ce mode.
; L'état vit dans App.au3 (lu par Renderer.au3) ; cette fonction se contente
; de synchroniser les coches du menu.
; -----------------------------------------------------------------------------
Func UI_SetZoneLabelMode($iMode)
	If Not App_SetZoneLabelMode($iMode) Then Return
	GUICtrlSetState($g_idUiMenuZoneNever, ($iMode = $APP_ZONELABEL_NEVER) ? $GUI_CHECKED : $GUI_UNCHECKED)
	GUICtrlSetState($g_idUiMenuZoneHover, ($iMode = $APP_ZONELABEL_HOVER) ? $GUI_CHECKED : $GUI_UNCHECKED)
	GUICtrlSetState($g_idUiMenuZoneAlways, ($iMode = $APP_ZONELABEL_ALWAYS) ? $GUI_CHECKED : $GUI_UNCHECKED)
	App_InvalidateView()
EndFunc   ;==>UI_SetZoneLabelMode

Func UI_GetZoneLabelMode()
	Return App_GetZoneLabelMode()
EndFunc   ;==>UI_GetZoneLabelMode

; -----------------------------------------------------------------------------
; Titre de la fenêtre : application, projet courant, astérisque si modifié.
; -----------------------------------------------------------------------------
Func UI_UpdateTitle()
	WinSetTitle($g_hUiMainGui, "", $APP_NAME & " " & $APP_VERSION & " — " _
			 & ProjectIO_GetDisplayName() & (App_IsProjectModified() ? " *" : ""))
EndFunc   ;==>UI_UpdateTitle

; Signale une mutation du projet (appelé par l'UI/Input après chaque action
; métier). Ne rafraîchit le titre qu'à la transition non-modifié → modifié.
Func UI_MarkProjectModified()
	If App_SetProjectModified(True) Then UI_UpdateTitle()
EndFunc   ;==>UI_MarkProjectModified

; -----------------------------------------------------------------------------
; Confirmation avant d'abandonner des modifications non enregistrées.
; Retourne True si l'opération peut continuer.
; -----------------------------------------------------------------------------
Func UI_ConfirmDiscard()
	If Not App_IsProjectModified() Then Return True
	Return MsgBox(BitOR($MB_YESNO, $MB_ICONWARNING, $MB_DEFBUTTON2), $APP_NAME, _
			"Le projet comporte des modifications non enregistrées." & @CRLF & _
			"Continuer sans enregistrer ?", 0, $g_hUiMainGui) = $IDYES
EndFunc   ;==>UI_ConfirmDiscard

; Le menu Quitter a-t-il demandé la fermeture ? (consommé par la boucle)
Func UI_ConsumeQuitRequested()
	If Not $g_bUiQuitRequested Then Return False
	$g_bUiQuitRequested = False
	Return True
EndFunc   ;==>UI_ConsumeQuitRequested

; -----------------------------------------------------------------------------
; Resynchronise TOUTE l'interface après remplacement du projet (Nouveau/Ouvrir) :
; panneaux, liste des layers, sélection, caméra, titre.
; -----------------------------------------------------------------------------
; Cadre le rectangle EXTÉRIEUR de la boîte dans le canvas (l'origine monde
; étant le coin intérieur, l'extérieur commence en (−épaisseur, −épaisseur)).
Func UI_FitCameraToBox()
	Local $fOx1, $fOy1, $fOx2, $fOy2
	Project_BoxOuter($fOx1, $fOy1, $fOx2, $fOy2)
	Camera_FitRect($fOx1, $fOy1, $fOx2 - $fOx1, $fOy2 - $fOy1)
EndFunc   ;==>UI_FitCameraToBox

; Resynchronise les panneaux (Boîte/Layers/Séparateur) avec le modèle
; courant — partagé par UI_AfterProjectReplaced (Nouveau/Ouvrir) et
; UI_DoUndo/UI_DoRedo. La sélection n'est désélectionnée QUE si elle
; référence un id absent du nouvel état (ex. Annuler la création d'un
; séparateur) — la garder quand l'id existe encore (cas courant d'un
; Annuler/Rétablir de position/formule) permet à l'utilisateur de VOIR le
; panneau Séparateur suivre le changement au lieu de se refermer à chaque fois.
; Ne touche PAS à la sélection : l'appelant en décide (Selection_Clear() pour
; un nouveau projet — cf. UI_AfterProjectReplaced —, ou déjà restaurée telle
; quelle par Undo_Undo/Undo_Redo, cf. Undo.au3/_Undo_Restore).
Func UI_RefreshAllPanels()
	UI_RefreshBoxInputs()
	UI_RefreshMainSepOrientMenu()
	UI_RefreshGenerateStructureMenu()
	UI_RefreshShowDxfLabelsMenu()
	UI_RefreshShowSepTooltipsMenu()
	UI_RefreshStructureDependentFields()
	UI_RefreshLayerInputs()
	For $i = 0 To $LAYERS_COUNT - 1
		UI_RefreshLayerRow($i)
	Next
	UI_RefreshSeparatorSection()
EndFunc   ;==>UI_RefreshAllPanels

Func UI_AfterProjectReplaced()
	Undo_Reset() ; rien à annuler/rétablir avant un projet tout juste chargé
	Selection_Clear() ; nouveau projet : une ancienne sélection n'a plus de sens ici
	UI_RefreshAllPanels()

	UI_FitCameraToBox()

	App_SetProjectModified(False)
	UI_UpdateTitle()
	App_InvalidateView()
EndFunc   ;==>UI_AfterProjectReplaced

; -----------------------------------------------------------------------------
; Annuler / Rétablir (Ctrl+Z / Ctrl+Y, cf. UI_RebuildAccelerators) : le modèle
; est remplacé par un instantané antérieur/postérieur (cf. Undo.au3) — la
; caméra n'est PAS recadrée (contrairement à Nouveau/Ouvrir : l'utilisateur
; regarde la même zone avant et après), mais tout le reste se resynchronise
; comme un changement de projet.
; -----------------------------------------------------------------------------
Func UI_DoUndo()
	If Not Undo_Undo() Then Return
	UI_RefreshAllPanels()
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>UI_DoUndo

Func UI_DoRedo()
	If Not Undo_Redo() Then Return
	UI_RefreshAllPanels()
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>UI_DoRedo

; --- Actions du menu Fichier ---------------------------------------------------

Func UI_DoNew()
	If Not UI_ConfirmDiscard() Then Return
	Metier_NewProject()
	ProjectIO_SetPath("")
	; Reprend le dernier choix de l'utilisateur, pas le défaut d'usine.
	UI_SeedMainSepOrient(Settings_GetMainSepOrient())
	UI_SeedGenerateStructure(Settings_GetGenerateStructure())
	UI_SeedShowDxfLabels(Settings_GetShowDxfLabels())
	UI_SeedShowSepTooltips(Settings_GetShowSepTooltips())
	UI_AfterProjectReplaced()
EndFunc   ;==>UI_DoNew

Func UI_DoOpen()
	If Not UI_ConfirmDiscard() Then Return
	Local $sPath = FileOpenDialog("Ouvrir un projet", "", _
			"Projet BoxForge (*." & $IO_FILE_EXT & ")", $FD_FILEMUSTEXIST, "", $g_hUiMainGui)
	If @error Then Return ; annulé

	If Not ProjectIO_LoadFrom($sPath) Then
		MsgBox(BitOR($MB_OK, $MB_ICONERROR), $APP_NAME, _
				"Fichier de projet invalide ou illisible :" & @CRLF & $sPath, 0, $g_hUiMainGui)
		Return
	EndIf
	UI_AfterProjectReplaced()
EndFunc   ;==>UI_DoOpen

; Enregistre le projet ($bForceDialog : "Enregistrer sous…").
Func UI_DoSave($bForceDialog)
	Local $sPath = ProjectIO_GetPath()
	If $bForceDialog Or $sPath = "" Then
		$sPath = FileSaveDialog("Enregistrer le projet", "", _
				"Projet BoxForge (*." & $IO_FILE_EXT & ")", $FD_PATHMUSTEXIST, _
				ProjectIO_GetDisplayName(), $g_hUiMainGui)
		If @error Then Return ; annulé
		; FileSaveDialog ne force pas l'extension.
		If Not StringRegExp($sPath, "(?i)\." & $IO_FILE_EXT & "$") Then $sPath &= "." & $IO_FILE_EXT
	EndIf

	If Not ProjectIO_SaveTo($sPath) Then
		MsgBox(BitOR($MB_OK, $MB_ICONERROR), $APP_NAME, _
				"Impossible d'écrire le fichier :" & @CRLF & $sPath, 0, $g_hUiMainGui)
		Return
	EndIf
	App_SetProjectModified(False)
	UI_UpdateTitle()
EndFunc   ;==>UI_DoSave

; -----------------------------------------------------------------------------
; Panneau de droite : Propriétés (contenu réel à l'étape "Sélection").
; -----------------------------------------------------------------------------
Func UI_CreatePanelRight()
	$g_hUiPanelRightGui = GUICreate("", $UI_PANEL_RIGHT_W, 100, 0, 0, $WS_CHILD, 0, $g_hUiMainGui)
	GUISetBkColor($UI_COLOR_PANEL_BG, $g_hUiPanelRightGui)

	Local $idTitle = UI_Dock(GUICtrlCreateLabel("Propriétés", 12, 10, $UI_PANEL_RIGHT_W - 24, 20))
	GUICtrlSetColor($idTitle, $UI_COLOR_TEXT)
	GUICtrlSetBkColor($idTitle, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlSetFont($idTitle, 10, 700)

	UI_CreateBoxSection(42)
	UI_CreateLayerSection(300)
	UI_CreateSeparatorSection(524)
EndFunc   ;==>UI_CreatePanelRight

; -----------------------------------------------------------------------------
; Section "Séparateur" du panneau Propriétés (cahier des charges : position,
; layer, orientation, longueur, identifiant, lien de groupe SHIFT).
; Créée masquée : UI_RefreshSeparatorSection la montre quand une sélection
; existe. Tous les contrôles sont recensés pour le masquage en bloc.
; -----------------------------------------------------------------------------
Func UI_CreateSeparatorSection($iYStart)
	$g_idUiSepTitle = UI_Dock(GUICtrlCreateLabel("", 12, $iYStart, $UI_PANEL_RIGHT_W - 24, 18))
	GUICtrlSetColor($g_idUiSepTitle, $UI_COLOR_TEXT)
	GUICtrlSetBkColor($g_idUiSepTitle, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlSetFont($g_idUiSepTitle, 9, 700)
	UI_TrackSepCtrl($g_idUiSepTitle)

	Local $iY = $iYStart + 26

	; Position : saisissable — un NOMBRE (clampé par le métier) ou une
	; FORMULE référençant d'autres séparateurs, ex : "s1.pos + 20" (le
	; séparateur devient alors piloté et suit ses références).
	Local $idPosLabel = UI_Dock(GUICtrlCreateLabel("Position (mm / formule)", 12, $iY + 3, 136, 18))
	GUICtrlSetColor($idPosLabel, $UI_COLOR_TEXT_DIM)
	GUICtrlSetBkColor($idPosLabel, $GUI_BKCOLOR_TRANSPARENT)
	UI_TrackSepCtrl($idPosLabel)
	$g_idUiSepPosInput = UI_Dock(GUICtrlCreateInput("", 156, $iY, 96, 22))
	UI_TrackSepCtrl($g_idUiSepPosInput)
	$iY += 28

	$g_idUiSepPosEff = UI_CreateSepValueRow("Pos. effective (mm)", $iY)
	$g_idUiSepLenValue = UI_CreateSepValueRow("Longueur (mm)", $iY)
	$g_idUiSepGroupValue = UI_CreateSepValueRow("Groupe", $iY)

	; Layer du séparateur : liste déroulante des 30 layers.
	Local $idLabel = UI_Dock(GUICtrlCreateLabel("Layer", 12, $iY + 3, 136, 18))
	GUICtrlSetColor($idLabel, $UI_COLOR_TEXT_DIM)
	GUICtrlSetBkColor($idLabel, $GUI_BKCOLOR_TRANSPARENT)
	UI_TrackSepCtrl($idLabel)
	$g_idUiSepLayerCombo = UI_Dock(GUICtrlCreateCombo("", 156, $iY, 96, 22, BitOR($CBS_DROPDOWNLIST, $WS_VSCROLL)))
	Local $sItems = ""
	For $i = 0 To $LAYERS_COUNT - 1
		$sItems &= ($i > 0 ? "|" : "") & Layers_Name($i)
	Next
	GUICtrlSetData($g_idUiSepLayerCombo, $sItems)
	UI_TrackSepCtrl($g_idUiSepLayerCombo)
	$iY += 28

	$g_idUiBtnSepApplyPos =  UI_Dock(GUICtrlCreateButton("Appliquer", 52, $iY + 4, 96, 26))
	UI_TrackSepCtrl($g_idUiBtnSepApplyPos)
	$g_idUiBtnSepDelete =  UI_Dock(GUICtrlCreateButton("Supprimer", 156, $iY + 4, 96, 26))
	UI_TrackSepCtrl($g_idUiBtnSepDelete)

	UI_RefreshSeparatorSection() ; masque la section (aucune sélection au départ)
EndFunc   ;==>UI_CreateSeparatorSection

; Crée une rangée "libellé + valeur en lecture seule" de la section Séparateur
; et avance $iY. Retourne l'id du label de valeur.
Func UI_CreateSepValueRow($sLabel, ByRef $iY)
	Local $idLabel = UI_Dock(GUICtrlCreateLabel($sLabel, 12, $iY + 3, 136, 18))
	GUICtrlSetColor($idLabel, $UI_COLOR_TEXT_DIM)
	GUICtrlSetBkColor($idLabel, $GUI_BKCOLOR_TRANSPARENT)
	UI_TrackSepCtrl($idLabel)

	Local $idValue = UI_Dock(GUICtrlCreateLabel("", 156, $iY + 3, 96, 18))
	GUICtrlSetColor($idValue, $UI_COLOR_TEXT)
	GUICtrlSetBkColor($idValue, $GUI_BKCOLOR_TRANSPARENT)
	UI_TrackSepCtrl($idValue)

	$iY += 28
	Return $idValue
EndFunc   ;==>UI_CreateSepValueRow

; Recense un contrôle de la section Séparateur (masquage/affichage en bloc).
Func UI_TrackSepCtrl($idCtrl)
	ReDim $g_aidUiSepCtrls[UBound($g_aidUiSepCtrls) + 1]
	$g_aidUiSepCtrls[UBound($g_aidUiSepCtrls) - 1] = $idCtrl
EndFunc   ;==>UI_TrackSepCtrl

; -----------------------------------------------------------------------------
; Synchronise la section Séparateur avec la sélection courante :
; masquée si aucune sélection, sinon remplie depuis le modèle.
; -----------------------------------------------------------------------------
Func UI_RefreshSeparatorSection()
	Local $iRow = Selection_HasSelection() ? Project_SepFindById(Selection_GetId()) : -1

	Local $iState = ($iRow = -1) ? $GUI_HIDE : $GUI_SHOW
	For $i = 0 To UBound($g_aidUiSepCtrls) - 1
		GUICtrlSetState($g_aidUiSepCtrls[$i], $iState)
	Next
	If $iRow = -1 Then Return

	GUICtrlSetData($g_idUiSepTitle, StringFormat("Séparateur #%d (%s)", _
			Project_SepGet($iRow, $SEP_ID), Separator_OrientName(Project_SepGet($iRow, $SEP_ORIENT))))
	UI_RefreshSeparatorPosition()

	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)
	GUICtrlSetData($g_idUiSepGroupValue, ($iGroup = $SEP_NO_GROUP) ? "aucun" _
			 : StringFormat("G%d (%d segments)", $iGroup, Project_SepGroupSize($iGroup)))

	; Sélection du layer courant dans la liste déroulante.
	; (PAS GUICtrlSetData : sur une combo, il AJOUTERAIT un doublon.)
	_GUICtrlComboBox_SelectString(GUICtrlGetHandle($g_idUiSepLayerCombo), _
			Layers_Name(Project_SepGet($iRow, $SEP_LAYER)))
EndFunc   ;==>UI_RefreshSeparatorSection

; Rafraîchit uniquement position et longueur (appelé à chaque pas de drag :
; on ne retouche pas les autres contrôles, ni la combo).
; Le champ Position montre la FORMULE quand le séparateur est piloté ; la
; position calculée est toujours visible dans "Pos. effective".
Func UI_RefreshSeparatorPosition()
	Local $iRow = Selection_HasSelection() ? Project_SepFindById(Selection_GetId()) : -1
	If $iRow = -1 Then Return
	Local $sFormula = Project_SepGet($iRow, $SEP_FORMULA)
	GUICtrlSetData($g_idUiSepPosInput, ($sFormula = "") _
			 ? UI_FmtMm(Project_SepGet($iRow, $SEP_POS)) : $sFormula)
	UI_RefreshSeparatorDerived()
EndFunc   ;==>UI_RefreshSeparatorPosition

; Rafraîchit uniquement les libellés DÉRIVÉS (Pos. effective, Longueur) — PAS
; le champ Position lui-même. Utilisé pendant la frappe (aperçu en direct,
; cf. Input.au3) : le champ édité par l'utilisateur ne doit jamais être
; réécrit sous ses yeux tant qu'il n'a pas validé (Entrée / perte de focus).
Func UI_RefreshSeparatorDerived()
	Local $iRow = Selection_HasSelection() ? Project_SepFindById(Selection_GetId()) : -1
	If $iRow = -1 Then Return
	GUICtrlSetData($g_idUiSepPosEff, UI_FmtMm(Project_SepGet($iRow, $SEP_POS)))
	GUICtrlSetData($g_idUiSepLenValue, UI_FmtMm(Project_SepLength($iRow)))
EndFunc   ;==>UI_RefreshSeparatorDerived

; Applique la saisie du champ Position au séparateur sélectionné :
;   - un NOMBRE : position libre (efface une éventuelle formule) puis
;     déplacement clampé par le métier ;
;   - autre chose : une FORMULE (validée : syntaxe, références, cycles) —
;     le séparateur devient piloté et suit ses références.
; La valeur réellement acceptée est réaffichée.
Func UI_ApplySeparatorPosition()
	If Not Selection_HasSelection() Then Return
	Local $iId = Selection_GetId()
	Local $sInput = StringStripWS(GUICtrlRead($g_idUiSepPosInput), 3)

	; État d'avant-frappe — une seule fois par session (cf. Undo_Arm). En
	; général déjà capturé par l'aperçu en direct (cf. Input_PreviewSepPos) ;
	; reste utile quand la saisie n'a jamais été applicable pendant la frappe
	; (formule restée invalide jusqu'à la validation, par exemple).
	Undo_CaptureIfArmed()

	If StringRegExp($sInput, "^[-+]?[0-9]+([\.,][0-9]+)?$") Then
		; Nombre pur : libère le séparateur puis le déplace.
		Metier_SetSeparatorFormula($iId, "")
		If Metier_MoveSeparator($iId, Number(StringReplace($sInput, ",", "."))) Then UI_MarkProjectModified()
	Else
		Local $sErr = Metier_SetSeparatorFormula($iId, $sInput)
		If $sErr <> "" Then
			MsgBox(BitOR($MB_OK, $MB_ICONWARNING), $APP_NAME, $sErr, 0, $g_hUiMainGui)
		Else
			UI_MarkProjectModified()
		EndIf
	EndIf
	UI_RefreshSeparatorSection()
	App_InvalidateView()
EndFunc   ;==>UI_ApplySeparatorPosition

; Applique le layer choisi dans la liste au séparateur sélectionné — et à tout
; son groupe : les segments liés se comportent comme un seul objet.
Func UI_ApplySeparatorLayer()
	Local $iRow = Selection_HasSelection() ? Project_SepFindById(Selection_GetId()) : -1
	If $iRow = -1 Then Return

	; "Layer NN" → NN (index numérique).
	Local $iLayer = Number(StringTrimLeft(GUICtrlRead($g_idUiSepLayerCombo), 6))
	If $iLayer < 0 Or $iLayer >= $LAYERS_COUNT Then Return

	Undo_PushSnapshot() ; action ponctuelle (combo), pas une session de frappe

	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)
	For $i = 0 To Project_SepCount() - 1
		If $i = $iRow Or ($iGroup <> $SEP_NO_GROUP And Project_SepGet($i, $SEP_GROUP) = $iGroup) Then
			Project_SepSet($i, $SEP_LAYER, $iLayer)
		EndIf
	Next
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>UI_ApplySeparatorLayer

; Supprime le séparateur sélectionné (le groupe entier suit — règle métier).
Func UI_DeleteSelectedSeparator()
	If Not Selection_HasSelection() Then Return
	Undo_PushSnapshot()
	Metier_DeleteSeparator(Selection_GetId())
	Selection_Clear()
	UI_RefreshSeparatorSection()
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>UI_DeleteSelectedSeparator

; -----------------------------------------------------------------------------
; Section "Boîte" du panneau Propriétés : les 6 champs modifiables + Appliquer.
; Création générique pilotée par un tableau de libellés indexé comme la
; structure Boîte (aucun code dupliqué par champ).
; -----------------------------------------------------------------------------
Func UI_CreateBoxSection($iYStart)
	Local $idSection = UI_Dock(GUICtrlCreateLabel("Boîte", 12, $iYStart, $UI_PANEL_RIGHT_W - 24, 18))
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
		; Séparateur principal / options de génération : réglages "menu
		; uniquement" (cf. cahier des charges, UI_CreateMenus) — pas de champ
		; dans ce panneau, accessibles uniquement depuis le menu du haut.
		If $i = $BOX_MAIN_SEP_ORIENT Or $i = $BOX_GENERATE_STRUCTURE Or _
				$i = $BOX_SHOW_DXF_LABELS Or $i = $BOX_SHOW_SEP_TOOLTIPS Then ContinueLoop
		Local $idLabel = UI_Dock(GUICtrlCreateLabel($aLabels[$i], 12, $iY + 3, 136, 18))
		GUICtrlSetColor($idLabel, $UI_COLOR_TEXT_DIM)
		GUICtrlSetBkColor($idLabel, $GUI_BKCOLOR_TRANSPARENT)
		$g_aidUiBoxInputs[$i] = UI_Dock(GUICtrlCreateInput("", 156, $iY, 96, 22))
		$iY += 28
	Next

	$g_idUiBtnApplyBox =  UI_Dock(GUICtrlCreateButton("Appliquer", 156, $iY + 4, 96, 26))
EndFunc   ;==>UI_CreateBoxSection

; -----------------------------------------------------------------------------
; Section "Layer" du panneau Propriétés : propriétés du layer actif.
; La couleur s'édite via le sélecteur Windows (bouton) ; les 4 dimensions via
; des inputs créés génériquement, indexés comme la structure Layer.
; -----------------------------------------------------------------------------
Func UI_CreateLayerSection($iYStart)
	$g_idUiLayerSectionTitle = UI_Dock(GUICtrlCreateLabel("", 12, $iYStart, $UI_PANEL_RIGHT_W - 24, 18))
	GUICtrlSetColor($g_idUiLayerSectionTitle, $UI_COLOR_TEXT)
	GUICtrlSetBkColor($g_idUiLayerSectionTitle, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlSetFont($g_idUiLayerSectionTitle, 9, 700)

	; Rangée couleur : pastille (label coloré) + bouton sélecteur.
	Local $iY = $iYStart + 26
	Local $idColorLabel = UI_Dock(GUICtrlCreateLabel("Couleur", 12, $iY + 3, 136, 18))
	GUICtrlSetColor($idColorLabel, $UI_COLOR_TEXT_DIM)
	GUICtrlSetBkColor($idColorLabel, $GUI_BKCOLOR_TRANSPARENT)
	$g_idUiLayerColorSwatch = UI_Dock(GUICtrlCreateLabel("", 156, $iY + 2, 18, 18))
	$g_idUiLayerColorBtn =  UI_Dock(GUICtrlCreateButton("Choisir…", 182, $iY, 70, 22))
	$iY += 28

	; Libellés indexés comme les champs Layer (COLOR traité au-dessus).
	Local $aLabels[$LAYER_FIELD_COUNT]
	$aLabels[$LAYER_THICKNESS] = "Épaisseur (mm)"
	$aLabels[$LAYER_HEIGHT] = "Hauteur (mm)"
	$aLabels[$LAYER_FINGER_LEN] = "Créneau : long. (mm)"
	$aLabels[$LAYER_FINGER_SPACING] = "Créneau : espac. (mm)"

	For $i = 0 To $LAYER_FIELD_COUNT - 1
		If $i = $LAYER_COLOR Then ContinueLoop
		Local $idLabel = UI_Dock(GUICtrlCreateLabel($aLabels[$i], 12, $iY + 3, 136, 18))
		GUICtrlSetColor($idLabel, $UI_COLOR_TEXT_DIM)
		GUICtrlSetBkColor($idLabel, $GUI_BKCOLOR_TRANSPARENT)
		$g_aidUiLayerInputs[$i] = UI_Dock(GUICtrlCreateInput("", 156, $iY, 96, 22))
		$iY += 28
	Next

	$g_idUiBtnApplyLayer =  UI_Dock(GUICtrlCreateButton("Appliquer", 156, $iY + 4, 96, 26))
EndFunc   ;==>UI_CreateLayerSection

; Recharge la section Layer depuis le modèle (titre, pastille, dimensions).
Func UI_RefreshLayerInputs()
	GUICtrlSetData($g_idUiLayerSectionTitle, "Layer actif : " & Layers_Name($g_iUiActiveLayer))
	GUICtrlSetBkColor($g_idUiLayerColorSwatch, Project_LayerGet($g_iUiActiveLayer, $LAYER_COLOR))
	For $i = 0 To $LAYER_FIELD_COUNT - 1
		If $i = $LAYER_COLOR Then ContinueLoop
		GUICtrlSetData($g_aidUiLayerInputs[$i], Project_LayerGet($g_iUiActiveLayer, $i))
	Next
EndFunc   ;==>UI_RefreshLayerInputs

; Applique les saisies de la section Layer au modèle (validation métier),
; puis resynchronise l'affichage (inputs + ligne de la liste).
Func UI_ApplyLayerInputs()
	For $i = 0 To $LAYER_FIELD_COUNT - 1
		If $i = $LAYER_COLOR Then ContinueLoop
		Project_LayerSet($g_iUiActiveLayer, $i, Number(GUICtrlRead($g_aidUiLayerInputs[$i])))
	Next
	UI_RefreshLayerInputs()
	UI_RefreshLayerRow($g_iUiActiveLayer)
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>UI_ApplyLayerInputs

; Ouvre le sélecteur de couleur Windows pour le layer actif.
Func UI_PickLayerColor()
	Local $iColor = _ChooseColor(2, Project_LayerGet($g_iUiActiveLayer, $LAYER_COLOR), 2, $g_hUiMainGui)
	If @error Then Return ; annulé par l'utilisateur
	Undo_PushSnapshot()
	Project_LayerSet($g_iUiActiveLayer, $LAYER_COLOR, $iColor)
	UI_RefreshLayerInputs()
	UI_RefreshLayerRow($g_iUiActiveLayer)
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>UI_PickLayerColor

; Format d'affichage d'une valeur en mm : 2 décimales maximum, sans zéros
; inutiles ("150", "150.5", "150.25").
Func UI_FmtMm($fValue)
	Local $s = StringFormat("%.2f", $fValue)
	$s = StringRegExpReplace($s, "0+$", "")
	Return StringRegExpReplace($s, "\.$", "")
EndFunc   ;==>UI_FmtMm

; Recharge les champs depuis le modèle (source de vérité : le métier).
Func UI_RefreshBoxInputs()
	For $i = 0 To $BOX_FIELD_COUNT - 1
		If $i = $BOX_MAIN_SEP_ORIENT Or $i = $BOX_GENERATE_STRUCTURE Or _
				$i = $BOX_SHOW_DXF_LABELS Or $i = $BOX_SHOW_SEP_TOOLTIPS Then ContinueLoop
		GUICtrlSetData($g_aidUiBoxInputs[$i], UI_FmtMm(Project_BoxGet($i)))
	Next
EndFunc   ;==>UI_RefreshBoxInputs

; Applique les saisies au modèle : chaque champ passe par la validation
; métier ; les valeurs refusées sont simplement réaffichées telles quelles.
; Les dimensions ayant pu changer, le métier ramène les séparateurs dans le
; nouvel intérieur et recalcule les sous-zones.
Func UI_ApplyBoxInputs()
	For $i = 0 To $BOX_FIELD_COUNT - 1
		If $i = $BOX_MAIN_SEP_ORIENT Or $i = $BOX_GENERATE_STRUCTURE Or _
				$i = $BOX_SHOW_DXF_LABELS Or $i = $BOX_SHOW_SEP_TOOLTIPS Then ContinueLoop
		Project_BoxSet($i, Number(GUICtrlRead($g_aidUiBoxInputs[$i])))
	Next
	Metier_OnBoxChanged()
	UI_RefreshBoxInputs() ; réaffiche les valeurs réellement acceptées
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>UI_ApplyBoxInputs

; -----------------------------------------------------------------------------
; Dispatch des événements de contrôles (appelé par la boucle principale).
; Retourne True si l'événement a été consommé.
; -----------------------------------------------------------------------------
Func UI_HandleGuiEvent($iMsg)
	Switch $iMsg
		Case $g_idUiMenuNew
			UI_DoNew()
			Return True
		Case $g_idUiMenuOpen
			UI_DoOpen()
			Return True
		Case $g_idUiMenuSave
			UI_DoSave(False)
			Return True
		Case $g_idUiMenuSaveAs
			UI_DoSave(True)
			Return True
		Case $g_idUiMenuQuit
			If UI_ConfirmDiscard() Then $g_bUiQuitRequested = True
			Return True
		Case $g_idUiMenuUndo
			UI_DoUndo()
			Return True
		Case $g_idUiMenuRedo
			UI_DoRedo()
			Return True
		Case $g_idUiMenuFit
			UI_FitCameraToBox()
			App_InvalidateView()
			Return True
		Case $g_idUiMenuLayerSimpleView
			UI_ToggleLayerSimpleView()
			Return True
		Case $g_idUiMenuSepTooltips
			UI_ToggleShowSepTooltips()
			Return True
		Case $g_idUiMenuZoneNever
			UI_SetZoneLabelMode($APP_ZONELABEL_NEVER)
			Return True
		Case $g_idUiMenuZoneHover
			UI_SetZoneLabelMode($APP_ZONELABEL_HOVER)
			Return True
		Case $g_idUiMenuZoneAlways
			UI_SetZoneLabelMode($APP_ZONELABEL_ALWAYS)
			Return True
		Case $g_idUiMenuDxf
			UI_DoExportDxf()
			Return True
		Case $g_idUiMenuMainSepH
			UI_SetMainSepOrient($SEP_ORIENT_H)
			Return True
		Case $g_idUiMenuMainSepV
			UI_SetMainSepOrient($SEP_ORIENT_V)
			Return True
		Case $g_idUiMenuGenStructure
			UI_ToggleGenerateStructure()
			Return True
		Case $g_idUiMenuDxfLabels
			UI_ToggleShowDxfLabels()
			Return True
		Case $g_idUiBtnApplyBox
			UI_ApplyBoxInputs()
			Return True
		Case $g_idUiBtnApplyLayer
			UI_ApplyLayerInputs()
			Return True
		Case $g_idUiLayerColorBtn
			UI_PickLayerColor()
			Return True
		Case $g_idUiSepLayerCombo
			UI_ApplySeparatorLayer()
			Return True
		Case $g_idUiBtnSepApplyPos
			UI_ApplySeparatorPosition()
			Return True
		Case $g_idUiBtnSepDelete
			UI_DeleteSelectedSeparator()
			Return True
		Case $g_idUiLayerList
			; Clic dans la liste : suit la sélection courante.
			UI_SetActiveLayer(_GUICtrlListView_GetSelectionMark($g_idUiLayerList))
			Return True
		Case $g_idUiAccelUp
			Input_AdjustFieldAtCursor(True)
			Return True
		Case $g_idUiAccelDown
			Input_AdjustFieldAtCursor(False)
			Return True
	EndSwitch

	; Clic directement sur un item de la liste, ou sur une pastille de la
	; grille simplifiée (l'événement porte l'id de l'item/de la pastille).
	For $i = 0 To $LAYERS_COUNT - 1
		If $iMsg = $g_aidUiLayerItems[$i] Or $iMsg = $g_aidUiLayerSwatchFill[$i] Or $iMsg = $g_aidUiLayerSwatchBorder[$i] Then
			UI_SetActiveLayer($i)
			Return True
		EndIf
	Next
	Return False
EndFunc   ;==>UI_HandleGuiEvent

; -----------------------------------------------------------------------------
; Panneau du bas : Layers. Deux représentations superposées au même endroit
; (une seule visible à la fois, cf. UI_SetLayerSimpleView) :
;   - vue détaillée : ListView + icône de couleur (pas de colonne #RRGGBB) ;
;   - vue simplifiée : grille de pastilles colorées, cadre orange = layer actif.
; -----------------------------------------------------------------------------
Func UI_CreatePanelBottom()
	$g_hUiPanelBottomGui = GUICreate("", 100, $UI_PANEL_BOTTOM_H, 0, 0, $WS_CHILD, 0, $g_hUiMainGui)
	GUISetBkColor($UI_COLOR_PANEL_BG, $g_hUiPanelBottomGui)

	Local $idTitle = GUICtrlCreateLabel("Layers", 12, 8, 200, 20)
	GUICtrlSetColor($idTitle, $UI_COLOR_TEXT)
	GUICtrlSetBkColor($idTitle, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlSetFont($idTitle, 10, 700)
	GUICtrlSetResizing($idTitle, BitOR($GUI_DOCKSIZE, $GUI_DOCKLEFT, $GUI_DOCKBOTTOM))


	; Liste des 30 layers. Sélectionner une ligne = choisir le layer actif.
	; Pas de colonne de couleur textuelle : une icône (imagelist) précède le
	; nom du layer dans la première colonne.
	$g_idUiLayerList = GUICtrlCreateListView("Layer|Ép. (mm)|Haut. (mm)|Créneau L (mm)|Créneau E (mm)", _
			12, 32, 600, $UI_PANEL_BOTTOM_H - 44, BitOR($LVS_REPORT, $LVS_SINGLESEL, $LVS_SHOWSELALWAYS))
	GUICtrlSetBkColor($g_idUiLayerList, $UI_COLOR_PANEL_BG)      ; fond des items
	GUICtrlSetColor($g_idUiLayerList, $UI_COLOR_TEXT)
	_GUICtrlListView_SetBkColor($g_idUiLayerList, $UI_COLOR_PANEL_BG) ; fond du contrôle
	Local $aWidths[5] = [110, 70, 80, 100, 100]
	For $i = 0 To 4
		_GUICtrlListView_SetColumnWidth($g_idUiLayerList, $i, $aWidths[$i])
	Next

	UI_BuildLayerImageList()
	For $i = 0 To $LAYERS_COUNT - 1
		$g_aidUiLayerItems[$i] = GUICtrlCreateListViewItem(UI_LayerRowText($i), $g_idUiLayerList)
		_GUICtrlListView_SetItemImage($g_idUiLayerList, $i, $i)
	Next
	_GUICtrlListView_SetItemSelected($g_idUiLayerList, 0, True)

	UI_CreateLayerSwatches()
EndFunc   ;==>UI_CreatePanelBottom

; Texte d'une ligne de la liste des layers, depuis le modèle (la couleur est
; portée par l'icône, cf. UI_BuildLayerImageList — plus de colonne #RRGGBB).
Func UI_LayerRowText($iIndex)
	Return Layers_Name($iIndex) & _
			"|" & Project_LayerGet($iIndex, $LAYER_THICKNESS) & _
			"|" & Project_LayerGet($iIndex, $LAYER_HEIGHT) & _
			"|" & Project_LayerGet($iIndex, $LAYER_FINGER_LEN) & _
			"|" & Project_LayerGet($iIndex, $LAYER_FINGER_SPACING)
EndFunc   ;==>UI_LayerRowText

; -----------------------------------------------------------------------------
; Imagelist des icônes de couleur (vue détaillée) : un petit bitmap uni par
; layer, indexé comme les layers (index stable : les 30 lignes ne sont jamais
; réordonnées/supprimées). Reconstruit une icône à l'index $iIndex quand sa
; couleur change (cf. UI_RefreshLayerRow) via _GUIImageList_Replace.
; -----------------------------------------------------------------------------
Func UI_BuildLayerImageList()
	$g_hUiLayerImgList = _GUIImageList_Create(14, 14, 5, 0, $LAYERS_COUNT, 0)
	_GUICtrlListView_SetImageList($g_idUiLayerList, $g_hUiLayerImgList, 1) ; 1 = LVSIL_SMALL
	For $i = 0 To $LAYERS_COUNT - 1
		Local $hBmp = _WinAPI_CreateSolidBitmap($g_hUiPanelBottomGui, Project_LayerGet($i, $LAYER_COLOR), 14, 14)
		_GUIImageList_Add($g_hUiLayerImgList, $hBmp)
		_WinAPI_DeleteObject($hBmp)
	Next
EndFunc   ;==>UI_BuildLayerImageList

Func UI_RefreshLayerIcon($iIndex)
	If $g_hUiLayerImgList = 0 Then Return
	Local $hBmp = _WinAPI_CreateSolidBitmap($g_hUiPanelBottomGui, Project_LayerGet($iIndex, $LAYER_COLOR), 14, 14)
	_GUIImageList_Replace($g_hUiLayerImgList, $iIndex, $hBmp)
	_WinAPI_DeleteObject($hBmp)
EndFunc   ;==>UI_RefreshLayerIcon

; -----------------------------------------------------------------------------
; Grille de pastilles (vue simplifiée) : chaque layer est représenté par une
; pastille cliquable (couleur = couleur du layer, numéro centré) entourée d'un
; cadre — orange pour le layer actif, sinon invisible (couleur de fond du
; panneau). Créée masquée : UI_SetLayerSimpleView bascule l'affichage.
;
; La grille est DYNAMIQUE : le nombre de colonnes dépend de la largeur
; disponible (UI_SwatchColumns), recalculé et repositionné à chaque
; UI_ApplyLayout (UI_RepositionLayerSwatches) — pas de disposition figée en
; dur, pour rester correct au-delà de 30 layers et sur toute largeur fenêtre.
; -----------------------------------------------------------------------------
Global Const $UI_SWATCH_CELL   = 32
Global Const $UI_SWATCH_SIZE   = 26
Global Const $UI_SWATCH_FILL   = 20
Global Const $UI_COLOR_LAYER_ACTIVE = 0xFFA030 ; identique au contour de sélection des séparateurs

; Colonnes tenant dans une largeur disponible $iAvailW (px), au moins 1.
Func UI_SwatchColumns($iAvailW)
	Local $iCols = Int($iAvailW / $UI_SWATCH_CELL)
	Return ($iCols < 1) ? 1 : $iCols
EndFunc   ;==>UI_SwatchColumns

; Hauteur nécessaire (px) pour la grille complète à $iAvailW de large.
Func UI_ComputeSimpleViewHeight($iAvailW)
	Local $iCols = UI_SwatchColumns($iAvailW)
	Local $iRows = Ceiling($LAYERS_COUNT / $iCols)
	Return 32 + $iRows * $UI_SWATCH_CELL + 10
EndFunc   ;==>UI_ComputeSimpleViewHeight

; Couleur de texte (noir/blanc) contrastée avec un fond 0xRRGGBB (luminance
; perçue standard, seuil 128).
Func _UI_ContrastTextColor($iRgb)
	Local $iR = BitShift(BitAND($iRgb, 0xFF0000), 16)
	Local $iG = BitShift(BitAND($iRgb, 0x00FF00), 8)
	Local $iB = BitAND($iRgb, 0x0000FF)
	Local $fLum = ($iR * 299 + $iG * 587 + $iB * 114) / 1000
	Return ($fLum >= 128) ? 0x000000 : 0xFFFFFF
EndFunc   ;==>_UI_ContrastTextColor

Func UI_CreateLayerSwatches()
	For $i = 0 To $LAYERS_COUNT - 1
		; Position provisoire (0,0) : la position réelle est posée par le
		; premier UI_ApplyLayout → UI_RepositionLayerSwatches. $SS_NOTIFY sur
		; les DEUX contrôles : sans ce style, un Label n'émet AUCUN événement
		; clic dans GUIGetMsg (comportement par défaut d'un STATIC Win32) ;
		; les deux sont cliquables — quel que soit celui que Windows retient
		; au hit-test (le cadre entoure toute la pastille, aucune zone
		; "morte" pour l'utilisateur), UI_HandleGuiEvent teste les deux ids.
		$g_aidUiLayerSwatchBorder[$i] = GUICtrlCreateLabel("", 0, 0, $UI_SWATCH_SIZE, $UI_SWATCH_SIZE, $SS_NOTIFY)
		GUICtrlSetBkColor($g_aidUiLayerSwatchBorder[$i], $UI_COLOR_PANEL_BG)
		GUICtrlSetState($g_aidUiLayerSwatchBorder[$i], $GUI_HIDE)
		GUICtrlSetResizing($g_aidUiLayerSwatchBorder[$i], BitOR($GUI_DOCKSIZE, $GUI_DOCKLEFT, $GUI_DOCKTOP))

		; Numéro du layer centré H+V (SS_CENTER + SS_CENTERIMAGE : le second
		; centre aussi le texte verticalement sur un label Win32 mono-ligne).
		$g_aidUiLayerSwatchFill[$i] = GUICtrlCreateLabel(StringFormat("%02d", $i), 0, 0, _
				$UI_SWATCH_FILL, $UI_SWATCH_FILL, BitOR($SS_NOTIFY, $SS_CENTER, $SS_CENTERIMAGE))
		GUICtrlSetFont($g_aidUiLayerSwatchFill[$i], 8, 700)
		GUICtrlSetBkColor($g_aidUiLayerSwatchFill[$i], Project_LayerGet($i, $LAYER_COLOR))
		GUICtrlSetColor($g_aidUiLayerSwatchFill[$i], _UI_ContrastTextColor(Project_LayerGet($i, $LAYER_COLOR)))
		GUICtrlSetState($g_aidUiLayerSwatchFill[$i], $GUI_HIDE)
		GUICtrlSetResizing($g_aidUiLayerSwatchFill[$i], BitOR($GUI_DOCKSIZE, $GUI_DOCKLEFT, $GUI_DOCKTOP))
	Next
EndFunc   ;==>UI_CreateLayerSwatches

; Repositionne toute la grille selon $iCols colonnes (appelé par
; UI_ApplyLayout quand la vue simplifiée est active).
Func UI_RepositionLayerSwatches($iCols)
	If $iCols < 1 Then $iCols = 1
	Local $iMargin = ($UI_SWATCH_SIZE - $UI_SWATCH_FILL) / 2
	For $i = 0 To $LAYERS_COUNT - 1
		Local $iX = 12 + Mod($i, $iCols) * $UI_SWATCH_CELL
		Local $iY = 32 + Int($i / $iCols) * $UI_SWATCH_CELL
		GUICtrlSetPos($g_aidUiLayerSwatchBorder[$i], $iX, $iY, $UI_SWATCH_SIZE, $UI_SWATCH_SIZE)
		GUICtrlSetPos($g_aidUiLayerSwatchFill[$i], $iX + $iMargin, $iY + $iMargin, $UI_SWATCH_FILL, $UI_SWATCH_FILL)
	Next
EndFunc   ;==>UI_RepositionLayerSwatches

Func UI_RefreshLayerSwatchColor($iIndex)
	GUICtrlSetBkColor($g_aidUiLayerSwatchFill[$iIndex], Project_LayerGet($iIndex, $LAYER_COLOR))
	GUICtrlSetColor($g_aidUiLayerSwatchFill[$iIndex], _UI_ContrastTextColor(Project_LayerGet($iIndex, $LAYER_COLOR)))
EndFunc   ;==>UI_RefreshLayerSwatchColor

; Remet à jour le cadre de TOUTES les pastilles (coût négligeable : 30
; contrôles) — plus simple que de traquer laquelle était active avant.
Func UI_RefreshLayerSwatchActive()
	For $i = 0 To $LAYERS_COUNT - 1
		GUICtrlSetBkColor($g_aidUiLayerSwatchBorder[$i], ($i = $g_iUiActiveLayer) ? $UI_COLOR_LAYER_ACTIVE : $UI_COLOR_PANEL_BG)
	Next
EndFunc   ;==>UI_RefreshLayerSwatchActive

; Bascule entre vue détaillée (ListView) et vue simplifiée (pastilles) —
; câblé sur le menu Affichage.
Func UI_SetLayerSimpleView($bSimple)
	$g_bUiLayerSimpleView = $bSimple
	GUICtrlSetState($g_idUiMenuLayerSimpleView, $bSimple ? $GUI_CHECKED : $GUI_UNCHECKED)

	GUICtrlSetState($g_idUiLayerList, $bSimple ? $GUI_HIDE : $GUI_SHOW)
	Local $iSwatchState = $bSimple ? $GUI_SHOW : $GUI_HIDE
	For $i = 0 To $LAYERS_COUNT - 1
		GUICtrlSetState($g_aidUiLayerSwatchBorder[$i], $iSwatchState)
		GUICtrlSetState($g_aidUiLayerSwatchFill[$i], $iSwatchState)
	Next
	If $bSimple Then UI_RefreshLayerSwatchActive()

	; La hauteur du panneau du bas dépend du mode (fixe en vue détaillée,
	; dynamique en vue simplifiée, cf. UI_ApplyLayout) : demande une nouvelle
	; passe de disposition au prochain tour de boucle (même chemin que
	; WM_SIZE — UI.au3 n'appelle jamais Renderer_* directement).
	$g_bUiLayoutPending = True
EndFunc   ;==>UI_SetLayerSimpleView

Func UI_ToggleLayerSimpleView()
	UI_SetLayerSimpleView(Not $g_bUiLayerSimpleView)
EndFunc   ;==>UI_ToggleLayerSimpleView

Func UI_IsLayerSimpleView()
	Return $g_bUiLayerSimpleView
EndFunc   ;==>UI_IsLayerSimpleView

; Resynchronise une ligne de la liste (+ son icône et sa pastille) après
; mutation du layer (dimensions ou couleur).
Func UI_RefreshLayerRow($iIndex)
	GUICtrlSetData($g_aidUiLayerItems[$iIndex], UI_LayerRowText($iIndex))
	UI_RefreshLayerIcon($iIndex)
	UI_RefreshLayerSwatchColor($iIndex)
EndFunc   ;==>UI_RefreshLayerRow

; Change le layer actif et resynchronise la section Layer du panneau droit
; ainsi que la surbrillance de la grille de pastilles.
Func UI_SetActiveLayer($iIndex)
	If $iIndex < 0 Or $iIndex >= $LAYERS_COUNT Then Return
	$g_iUiActiveLayer = $iIndex
	UI_RefreshLayerInputs()
	UI_RefreshLayerSwatchActive()
EndFunc   ;==>UI_SetActiveLayer

Func UI_GetActiveLayer()
	Return $g_iUiActiveLayer
EndFunc   ;==>UI_GetActiveLayer

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
	If $iCanvasW < 1 Then $iCanvasW = 1

	; Hauteur du panneau du bas : fixe en vue détaillée, dynamique (dépend du
	; nombre de lignes de pastilles à ce nombre de colonnes) en vue simplifiée
	; — le canevas récupère automatiquement l'espace restant.
	Local $iPanelBottomH = $g_bUiLayerSimpleView _
			? UI_ComputeSimpleViewHeight($iCanvasW - 24) : $UI_PANEL_BOTTOM_H

	Local $iCanvasH = $aClient[1] - $iPanelBottomH
	If $iCanvasH < 1 Then $iCanvasH = 1

	_WinAPI_MoveWindow($g_hUiCanvasGui, 0, 0, $iCanvasW, $iCanvasH)
	_WinAPI_MoveWindow($g_hUiPanelRightGui, $iCanvasW, 0, $UI_PANEL_RIGHT_W, $aClient[1])
	_WinAPI_MoveWindow($g_hUiPanelBottomGui, 0, $iCanvasH, $iCanvasW, $iPanelBottomH)

	; La liste des layers suit la largeur du panneau du bas ; la grille de
	; pastilles suit sa largeur (nombre de colonnes recalculé).
	If $g_idUiLayerList <> 0 Then GUICtrlSetPos($g_idUiLayerList, 12, 32, $iCanvasW - 24, $UI_PANEL_BOTTOM_H - 44)
	If $g_bUiLayerSimpleView Then UI_RepositionLayerSwatches(UI_SwatchColumns($iCanvasW - 24))

	$g_iUiCanvasW = $iCanvasW
	$g_iUiCanvasH = $iCanvasH
EndFunc   ;==>UI_ApplyLayout

; --- Accesseurs -------------------------------------------------------------
Func UI_GetMainHwnd()
	Return $g_hUiMainGui
EndFunc   ;==>UI_GetMainHwnd

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
