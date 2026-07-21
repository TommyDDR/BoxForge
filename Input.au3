#include-once
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <WinAPI.au3>
#include <WinAPISysInternals.au3>
#include <EditConstants.au3>
#include <GuiEdit.au3>
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
Global Const $INP_VK_TAB    = "09"
Global Const $INP_VK_RETURN = "0D"
Global Const $INP_VK_SHIFT  = "10"
Global Const $INP_VK_LBUTTON = "01"

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

; --- Coalescence des WM_MOUSEMOVE pendant un drag (séparateur ou bord) ---
; Une souris rapide (voire à haute cadence de rapport : 500-1000 Hz) émet bien
; plus de WM_MOUSEMOVE que nécessaire ; exécuter TOUTE la chaîne (déplacement
; métier + recalcul des zones + GUICtrlSetData sur le panneau — synchrone,
; avec repeint du contrôle) à chaque message sature l'interpréteur : la file
; prend du retard sur la souris (gel qui grossit puis "rattrape" d'un coup).
; Le gestionnaire ne fait donc que MÉMORISER la dernière position ; c'est la
; boucle principale qui applique, au rythme du rendu (~60 Hz, largement
; suffisant à l'oeil) — cf. Input_ProcessPendingDrag, et le flush au
; relâchement dans Input_OnLButtonUp (la position finale n'est jamais perdue).
Global $g_bInpDragPending = False ; une position attend d'être appliquée
Global $g_iInpDragPendX = 0, $g_iInpDragPendY = 0 ; dernière position (client canvas)

; --- Curseur de survol courant (évite de re-poser le même curseur) ---
Global $g_iInpCursor = -1     ; -1 = défaut, sinon id GUISetCursor (11/13)

; --- Polling clavier : handle user32 partagé + états précédents (détection de
;     front montant : une action par appui, pas une par tour de boucle) ---
Global $g_hInpUser32  = 0
Global $g_bInpPrevDel = False
Global $g_bInpPrevEsc = False
Global $g_bInpPrevTab = False
Global $g_bInpPrevReturn = False

; -----------------------------------------------------------------------------
; Champs suivis (Box/Layer/Séparateur) : saisie en direct, Tab, Entrée/perte de
; focus. Un seul champ peut avoir le focus à la fois (Windows) — l'id de son
; contrôle EST l'état de "quel champ est actif" (0 = aucun champ suivi).
; -----------------------------------------------------------------------------
Global $g_iInpFocusedField      = 0     ; id du champ suivi qui a le focus (0 = aucun)
Global $g_bInpFieldDirty        = False ; l'utilisateur a modifié le champ depuis qu'il a le focus
Global $g_bInpFieldClickFocused = False ; le focus est arrivé par un clic (bouton gauche enfoncé au moment du focus)

; --- Constantes de nature de champ (retour de Input_FieldKind) ---
Global Const $INP_FIELD_NONE   = 0
Global Const $INP_FIELD_BOX    = 1
Global Const $INP_FIELD_LAYER  = 2
Global Const $INP_FIELD_SEPPOS = 3

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
	GUIRegisterMsg($WM_LBUTTONDBLCLK, "Input_OnLButtonDblClk")
	GUIRegisterMsg($WM_RBUTTONDOWN, "Input_OnRButtonDown")
	GUIRegisterMsg($WM_COMMAND, "Input_OnCommand")

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
	Local $fTol = Input_PickTolMm()
	; Bande de préhension d'un bord : l'épaisseur EFFECTIVE (cf.
	; Box_EffectiveThickness) — nulle si la boîte de structure est désactivée,
	; auquel cas extérieur == intérieur (Project_BoxOuter) — mais jamais sous
	; la tolérance de visée, sans quoi un bord sans épaisseur ne serait plus
	; attrapable qu'au pixel près.
	Local $fT = Project_BoxGet($BOX_GENERATE_STRUCTURE) ? Project_BoxGet($BOX_THICKNESS) : 0
	If $fT < $fTol Then $fT = $fTol

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

; =============================================================================
; Champs suivis (Box/Layer/Séparateur) : saisie en direct, Tab, Entrée/perte de
; focus, et insertion de référence par clic sur le canevas pendant la saisie.
; Aucune logique métier ici : chaque aperçu délègue au métier (Zones.au3) et
; chaque validation finale réutilise les fonctions Apply* existantes de UI.au3.
; =============================================================================

; Nature d'un contrôle suivi ($INP_FIELD_*) et son index dans le tableau
; correspondant (box/layer), ou -1 pour le champ Position du séparateur.
Func Input_FieldKind($iCtrlId, ByRef $iIndex)
	For $i = 0 To $BOX_FIELD_COUNT - 1
		; Réglages "menu uniquement" (cf. UI_CreateBoxSection) : pas de contrôle
		; créé pour ces index, donc pas de champ suivi à reconnaître ici.
		If $i = $BOX_MAIN_SEP_ORIENT Or $i = $BOX_GENERATE_STRUCTURE Or _
				$i = $BOX_SHOW_DXF_LABELS Or $i = $BOX_SHOW_SEP_TOOLTIPS Then ContinueLoop
		If $g_aidUiBoxInputs[$i] = $iCtrlId Then
			$iIndex = $i
			Return $INP_FIELD_BOX
		EndIf
	Next
	For $i = 0 To $LAYER_FIELD_COUNT - 1
		If $i = $LAYER_COLOR Then ContinueLoop
		If $g_aidUiLayerInputs[$i] = $iCtrlId Then
			$iIndex = $i
			Return $INP_FIELD_LAYER
		EndIf
	Next
	If $iCtrlId = $g_idUiSepPosInput Then
		$iIndex = -1
		Return $INP_FIELD_SEPPOS
	EndIf
	$iIndex = -1
	Return $INP_FIELD_NONE
EndFunc   ;==>Input_FieldKind

Func Input_IsTrackedField($iCtrlId)
	Local $iIndex
	Return Input_FieldKind($iCtrlId, $iIndex) <> $INP_FIELD_NONE
EndFunc   ;==>Input_IsTrackedField

; -----------------------------------------------------------------------------
; WM_COMMAND : notifications des contrôles Edit suivis.
;   - EN_SETFOCUS  : mémorise le champ actif ; note si le focus arrive par un
;     clic (bouton gauche encore enfoncé) — condition de "saisie utilisateur".
;   - EN_KILLFOCUS : valide le champ (clamps/vérifications métier).
;   - EN_CHANGE    : aperçu en direct (dessin) + bulle de formule.
; -----------------------------------------------------------------------------
Func Input_OnCommand($hWnd, $iMsg, $wParam, $lParam)
	#forceref $hWnd, $iMsg, $lParam
	Local $iCtrlId = BitAND($wParam, 0xFFFF)
	Local $iNotify = BitShift($wParam, 16)

	Switch $iNotify
		Case $EN_SETFOCUS
			If Input_IsTrackedField($iCtrlId) Then
				$g_iInpFocusedField = $iCtrlId
				$g_bInpFieldDirty = False
				$g_bInpFieldClickFocused = _IsPressed($INP_VK_LBUTTON, $g_hInpUser32)
				; Haut/Bas doivent être INTERCEPTÉS (accélérateur GUI, cf.
				; UI_SetUpDownAccelActive) tant qu'un champ suivi a le focus —
				; sinon le contrôle Edit natif les traite en silence (déplace
				; le curseur d'un caractère) avant notre propre logique.
				UI_SetUpDownAccelActive(True)
				; Arme la capture Annuler : la PREMIÈRE écriture effective du
				; modèle pendant cette session de saisie poussera l'état
				; d'avant-frappe (cf. Undo_Arm/Undo_CaptureIfArmed).
				Undo_Arm()
			EndIf
		Case $EN_KILLFOCUS
			If $iCtrlId = $g_iInpFocusedField Then
				Input_CommitField($iCtrlId)
				$g_iInpFocusedField = 0
				$g_bInpFieldDirty = False
				$g_bInpFieldClickFocused = False
				UI_FormulaTipHide()
				UI_SetUpDownAccelActive(False)
				; Aucune écriture n'a eu lieu cette session (ex. Tab sans
				; modification) : ne pas laisser l'armement traîner pour une
				; session ultérieure sans rapport (cf. Undo_Arm).
				Undo_Disarm()
			EndIf
		Case $EN_CHANGE
			If Input_IsTrackedField($iCtrlId) Then
				$g_bInpFieldDirty = True
				Input_OnFieldChanged($iCtrlId)
			EndIf
	EndSwitch
	Return $GUI_RUNDEFMSG
EndFunc   ;==>Input_OnCommand

; Validation finale (Entrée ou perte de focus) : clamps/vérifications métier,
; réaffichage de la valeur réellement acceptée — réutilise les fonctions
; Apply* existantes (mêmes règles que les boutons "Appliquer").
Func Input_CommitField($iCtrlId)
	Local $iIndex
	Switch Input_FieldKind($iCtrlId, $iIndex)
		Case $INP_FIELD_BOX
			UI_ApplyBoxInputs()
		Case $INP_FIELD_LAYER
			UI_ApplyLayerInputs()
		Case $INP_FIELD_SEPPOS
			UI_ApplySeparatorPosition()
			UI_FormulaTipHide() ; la saisie est validée : plus la peine d'afficher l'aperçu
	EndSwitch
EndFunc   ;==>Input_CommitField

Func Input_OnFieldChanged($iCtrlId)
	Local $iIndex
	Switch Input_FieldKind($iCtrlId, $iIndex)
		Case $INP_FIELD_BOX
			Input_PreviewBoxField($iIndex)
		Case $INP_FIELD_LAYER
			Input_PreviewLayerField($iIndex)
		Case $INP_FIELD_SEPPOS
			Input_PreviewSepPos()
	EndSwitch
EndFunc   ;==>Input_OnFieldChanged

; Aperçu en direct d'un champ Boîte : n'écrit JAMAIS dans le contrôle en cours
; de frappe. Une valeur hors bornes est simplement ignorée (le modèle garde sa
; valeur précédente) — l'utilisateur continue de taper sans être perturbé.
Func Input_PreviewBoxField($iIndex)
	Local $sText = StringStripWS(GUICtrlRead($g_aidUiBoxInputs[$iIndex]), 3)
	If Not StringRegExp($sText, "^[-+]?[0-9]+([\.,][0-9]+)?$") Then Return
	Undo_CaptureIfArmed() ; état d'avant-frappe — une seule fois par session (cf. EN_SETFOCUS)
	If Not Project_BoxSet($iIndex, Number(StringReplace($sText, ",", "."))) Then Return
	Metier_OnBoxChanged()
	UI_RefreshSeparatorDerived()
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>Input_PreviewBoxField

Func Input_PreviewLayerField($iIndex)
	Local $sText = StringStripWS(GUICtrlRead($g_aidUiLayerInputs[$iIndex]), 3)
	If Not StringRegExp($sText, "^[-+]?[0-9]+([\.,][0-9]+)?$") Then Return
	Undo_CaptureIfArmed()
	If Not Project_LayerSet(UI_GetActiveLayer(), $iIndex, Number(StringReplace($sText, ",", "."))) Then Return
	UI_RefreshLayerRow(UI_GetActiveLayer())
	UI_MarkProjectModified()
	App_InvalidateView()
EndFunc   ;==>Input_PreviewLayerField

; Aperçu en direct du champ Position (nombre OU formule) : le dessin suit la
; saisie à chaque frappe, formule ou pas.
;   - un NOMBRE déplace réellement le séparateur — en LIBÉRANT d'abord une
;     éventuelle formule (même règle qu'à la validation, cf.
;     UI_ApplySeparatorPosition) : un séparateur piloté suit donc lui aussi la
;     frappe, au lieu d'attendre Entrée/perte de focus ;
;   - une FORMULE VALIDE est appliquée immédiatement (Metier_SetSeparatorFormula :
;     le séparateur devient piloté et se déplace en direct), avec la bulle de
;     traduction (valeurs courantes + résultat). Pendant la frappe la formule
;     change de forme à chaque caractère (référence incomplète, opérateur en
;     attente d'opérande…) : tant qu'elle est INVALIDE, rien n'est appliqué —
;     le séparateur garde sa position (et sa dernière formule appliquée).
;     Le résultat affiché par la bulle est le calcul BRUT : la position réelle
;     peut différer (clamp métier — écart 10 mm, sous-zone), elle reste
;     visible dans "Pos. effective".
Func Input_PreviewSepPos()
	Local $sInput = StringStripWS(GUICtrlRead($g_idUiSepPosInput), 3)
	If $sInput = "" Or Not Selection_HasSelection() Then
		UI_FormulaTipHide()
		Return
	EndIf

	Local $iId = Selection_GetId()
	Local $iRow = Project_SepFindById($iId)
	If $iRow = -1 Then Return

	If StringRegExp($sInput, "^[-+]?[0-9]+([\.,][0-9]+)?$") Then
		UI_FormulaTipHide()
		Undo_CaptureIfArmed()
		If Project_SepGet($iRow, $SEP_FORMULA) <> "" Then Metier_SetSeparatorFormula($iId, "")
		If Metier_MoveSeparator($iId, Number(StringReplace($sInput, ",", "."))) Then
			UI_RefreshSeparatorDerived()
			App_InvalidateView()
		EndIf
		Return
	EndIf

	; Pas un nombre pur : tentative de formule (incomplète pendant la frappe —
	; simplement ignorée tant qu'elle n'est pas valide, cf. Metier_FormulaValidate).
	If Metier_FormulaValidate($sInput, $iId) <> "" Then
		UI_FormulaTipHide()
		Return
	EndIf

	; Formule valide : appliquée EN DIRECT — même mutation qu'à la validation
	; (la validation ne fera que la re-poser à l'identique, sans effet).
	Undo_CaptureIfArmed()
	Metier_SetSeparatorFormula($iId, $sInput)
	UI_RefreshSeparatorDerived()
	App_InvalidateView()

	If Zones_FormulaHasVariable($sInput) Then
		Local $sTranslated, $fPreview
		If Zones_FormulaTranslate($sInput, $sTranslated) And Zones_FormulaPreviewEval($sInput, $fPreview) Then
			UI_FormulaTipShowAboveControl($g_idUiSepPosInput, $sTranslated & @CRLF & UI_FmtMm($fPreview))
		Else
			UI_FormulaTipHide()
		EndIf
	Else
		UI_FormulaTipHide()
	EndIf
EndFunc   ;==>Input_PreviewSepPos

; -----------------------------------------------------------------------------
; Ordre de tabulation : champs Boîte, puis champs Layer, puis Position du
; séparateur SI une sélection existe (section masquée sinon).
; -----------------------------------------------------------------------------
Func Input_BuildTabOrder(ByRef $aOrder)
	; Champs Boîte réellement présents dans le panneau : $BOX_FIELD_COUNT moins
	; les réglages "menu uniquement" (cf. UI_CreateBoxSection), sans contrôle créé.
	Local $iBoxFields = $BOX_FIELD_COUNT - 4 ; MainSepOrient + les 3 nouvelles options
	Local $iN = $iBoxFields + ($LAYER_FIELD_COUNT - 1) + (Selection_HasSelection() ? 1 : 0)
	Local $a[$iN]
	Local $k = 0
	For $i = 0 To $BOX_FIELD_COUNT - 1
		If $i = $BOX_MAIN_SEP_ORIENT Or $i = $BOX_GENERATE_STRUCTURE Or _
				$i = $BOX_SHOW_DXF_LABELS Or $i = $BOX_SHOW_SEP_TOOLTIPS Then ContinueLoop
		$a[$k] = $g_aidUiBoxInputs[$i]
		$k += 1
	Next
	For $i = 0 To $LAYER_FIELD_COUNT - 1
		If $i = $LAYER_COLOR Then ContinueLoop
		$a[$k] = $g_aidUiLayerInputs[$i]
		$k += 1
	Next
	If Selection_HasSelection() Then
		$a[$k] = $g_idUiSepPosInput
		$k += 1
	EndIf
	$aOrder = $a
EndFunc   ;==>Input_BuildTabOrder

; Déplace le focus vers le champ suivi suivant ($bBackward : précédent —
; SHIFT+Tab). La perte de focus du champ courant déclenche naturellement sa
; validation (EN_KILLFOCUS, cf. Input_OnCommand) : rien à valider ici.
Func Input_FocusNextField($bBackward)
	If $g_iInpFocusedField = 0 Then Return
	Local $aOrder
	Input_BuildTabOrder($aOrder)

	Local $iCur = -1
	For $i = 0 To UBound($aOrder) - 1
		If $aOrder[$i] = $g_iInpFocusedField Then
			$iCur = $i
			ExitLoop
		EndIf
	Next
	If $iCur = -1 Then Return

	Local $iNext = $bBackward ? $iCur - 1 : $iCur + 1
	If $iNext < 0 Then $iNext = UBound($aOrder) - 1
	If $iNext >= UBound($aOrder) Then $iNext = 0

	Local $hNext = GUICtrlGetHandle($aOrder[$iNext])
	_WinAPI_SetFocus($hNext)
	_GUICtrlEdit_SetSel($hNext, 0, -1) ; tout sélectionné, comme la navigation Tab native
EndFunc   ;==>Input_FocusNextField

; -----------------------------------------------------------------------------
; "Saisie utilisateur" (cf. cahier des charges) : le focus est dans un champ
; suivi ET (l'utilisateur l'a modifié depuis qu'il a le focus OU y a cliqué
; pour l'obtenir). Dans cet état, cliquer sur un séparateur/la boîte insère sa
; référence dans le champ au lieu de sélectionner (cf. Input_OnLButtonDown).
; -----------------------------------------------------------------------------
Func Input_IsActiveFieldEditing()
	Return $g_iInpFocusedField <> 0 And ($g_bInpFieldDirty Or $g_bInpFieldClickFocused)
EndFunc   ;==>Input_IsActiveFieldEditing

; Insère $sText à la position du curseur du champ suivi actif (remplace la
; sélection courante s'il y en a une) — comportement "référence de cellule".
Func Input_InsertFieldToken($sText)
	If $g_iInpFocusedField = 0 Then Return
	_GUICtrlEdit_ReplaceSel(GUICtrlGetHandle($g_iInpFocusedField), $sText)
EndFunc   ;==>Input_InsertFieldToken

; -----------------------------------------------------------------------------
; Cherche, dans $sText, le jeton touché par le curseur $iCaret (offset 0-based
; de caractères) : soit les CHIFFRES d'un jeton "sN.pos" (kind="var"), soit un
; nombre nu (kind="num") — priorité au jeton variable, puis au jeton le plus à
; GAUCHE en cas d'égalité (caret pile à la frontière entre deux jetons).
; Pose $iStart/$iEnd (span 0-based, $iEnd exclusif) et $sValue (texte du
; jeton — les chiffres seuls pour "var"). Retourne False si rien ne convient.
; -----------------------------------------------------------------------------
Func Input_FindTokenAtCursor($sText, $iCaret, ByRef $iStart, ByRef $iEnd, ByRef $sKind, ByRef $sValue)
	; --- Jetons "sN.pos" : le jeton ajustable est la suite de chiffres seule. ---
	Local $aFull = StringRegExp($sText, "(?i)s\d+\.pos", 3)
	If Not @error Then
		Local $iFrom = 1
		For $i = 0 To UBound($aFull) - 1
			Local $iPos = StringInStr($sText, $aFull[$i], 0, 1, $iFrom)
			If $iPos = 0 Then ContinueLoop
			$iFrom = $iPos + StringLen($aFull[$i])

			Local $iDigLen = StringLen($aFull[$i]) - 5 ; total − 's' − '.pos'
			Local $iS0 = $iPos ; 0-based début des chiffres (= position 1-based de 's')
			Local $iE0 = $iS0 + $iDigLen
			If $iCaret >= $iS0 And $iCaret <= $iE0 Then
				$iStart = $iS0
				$iEnd = $iE0
				$sKind = "var"
				$sValue = StringMid($sText, $iS0 + 1, $iDigLen)
				Return True
			EndIf
		Next
	EndIf

	; --- Nombres nus. Le signe +/- n'est inclus dans le jeton QUE s'il ne peut
	; pas s'agir de l'opérateur binaire entre deux termes ("10+11" : le "+"
	; suit un chiffre, donc "11" seul est le jeton — pas "+11", qui perdrait
	; l'opérateur au remplacement, ex. "10+11" -> "1012" ; "10 + 11" ou
	; "s1.pos+17" restent corrects pour la même raison : "+" y suit un espace/
	; une lettre, jamais un chiffre/point/parenthèse — cf. rapport utilisateur). ---
	Local $aNum = StringRegExp($sText, "(?i)(?<![0-9.\)a-z])[-+]?[0-9]+(?:\.[0-9]+)?", 3)
	If Not @error Then
		Local $iFrom = 1
		For $i = 0 To UBound($aNum) - 1
			Local $iPos = StringInStr($sText, $aNum[$i], 0, 1, $iFrom)
			If $iPos = 0 Then ContinueLoop
			$iFrom = $iPos + StringLen($aNum[$i])

			Local $iS0 = $iPos - 1
			Local $iE0 = $iS0 + StringLen($aNum[$i])
			If $iCaret >= $iS0 And $iCaret <= $iE0 Then
				$iStart = $iS0
				$iEnd = $iE0
				$sKind = "num"
				$sValue = $aNum[$i]
				Return True
			EndIf
		Next
	EndIf

	Return False
EndFunc   ;==>Input_FindTokenAtCursor

; -----------------------------------------------------------------------------
; Haut/Bas dans un champ suivi : incrémente/décrémente (pas = 1 mm, ou 10 mm
; avec SHIFT — cf. $g_idUiAccelShiftUp/Down) le nombre sous le curseur, ou
; l'index N d'un jeton "sN.pos" (s1 → s2 → s3…, borné à 1 au minimum).
; Réutilise le pipeline d'aperçu existant (Box/Layer/Position, y compris la
; bulle de formule) — même effet qu'une frappe au clavier.
; -----------------------------------------------------------------------------
Func Input_AdjustFieldAtCursor($bIncrement, $iStepMag = 1)
	If $g_iInpFocusedField = 0 Then Return
	Local $hEdit = GUICtrlGetHandle($g_iInpFocusedField)
	Local $sText = GUICtrlRead($g_iInpFocusedField)
	Local $aSel = _GUICtrlEdit_GetSel($hEdit)

	Local $iStart, $iEnd, $sKind, $sValue
	If Not Input_FindTokenAtCursor($sText, $aSel[0], $iStart, $iEnd, $sKind, $sValue) Then Return

	Local $sReplacement
	If $sKind = "var" Then
		Local $iN = Int(Number($sValue)) + ($bIncrement ? $iStepMag : -$iStepMag)
		If $iN < 1 Then $iN = 1
		$sReplacement = String($iN)
	Else
		; Jeton "num" collé à un opérateur +/- précédent sans espace (ex.
		; "100-1") : il ne porte que sa MAGNITUDE (cf. Input_FindTokenAtCursor,
		; le signe reste à l'opérateur — ambiguïté avec l'opérateur binaire).
		; La contribution réelle du terme est donc (magnitude × signe de
		; l'opérateur). Pour que UP/DOWN fasse toujours varier le RÉSULTAT de
		; +1/-1 (et pas juste le chiffre affiché), on inverse le pas appliqué
		; à la magnitude quand le terme est soustrait — sinon DOWN sur
		; "100-1" affichait "100-0" (résultat 100, en hausse) au lieu de
		; "100-2" (résultat 98, en baisse).
		Local $sPrevChar = ($iStart > 0) ? StringMid($sText, $iStart, 1) : ""
		Local $bGluedOp = ($sPrevChar = "+" Or $sPrevChar = "-")
		Local $iSignOp = ($bGluedOp And $sPrevChar = "-") ? -1 : 1
		Local $iStep = ($bIncrement ? $iStepMag : -$iStepMag) * $iSignOp
		$sReplacement = UI_FmtMm(Number($sValue) + $iStep)

		; Si la nouvelle magnitude est négative, on fusionne son signe avec
		; l'opérateur collé au lieu de les juxtaposer ("10+1" -> "10-1",
		; jamais "10+-1" ; un pas de plus redonne "10+1", jamais "10--1").
		If $bGluedOp Then
			Local $bNeg = (StringLeft($sReplacement, 1) = "-")
			If $bNeg Then $sReplacement = StringTrimLeft($sReplacement, 1)
			Local $sNewOp = "+"
			If ($sPrevChar = "-") And Not $bNeg Then $sNewOp = "-"
			If ($sPrevChar = "+") And $bNeg Then $sNewOp = "-"
			$iStart -= 1
			$sReplacement = $sNewOp & $sReplacement
		EndIf
	EndIf

	Local $sNewText = StringLeft($sText, $iStart) & $sReplacement & StringMid($sText, $iEnd + 1)
	_GUICtrlEdit_SetText($hEdit, $sNewText)
	Local $iNewCaret = $iStart + StringLen($sReplacement)
	_GUICtrlEdit_SetSel($hEdit, $iNewCaret, $iNewCaret)

	; Changement programmatique : EN_CHANGE n'est pas fiable ici, on rejoue
	; nous-mêmes le même effet qu'une frappe (aperçu en direct + dirty flag).
	$g_bInpFieldDirty = True
	Input_OnFieldChanged($g_iInpFocusedField)
EndFunc   ;==>Input_AdjustFieldAtCursor

; Sous une saisie utilisateur active (cf. Input_IsActiveFieldEditing) : insère
; dans le champ suivi la référence pointée par $lParam (séparateur "sN.pos",
; coin "b.", bord "b.l"/"b.w"). Retourne True si un jeton a été inséré (le
; point d'appel doit alors court-circuiter son propre traitement) ; False si
; le clic ne touche rien de référençable (le point d'appel retombe sur son
; comportement normal). Partagé entre le simple et le double clic.
Func Input_TryInsertFieldReference($lParam)
	Local $fWxRef = Camera_ScreenToWorldX(Input_LoWordSigned($lParam))
	Local $fWyRef = Camera_ScreenToWorldY(Input_HiWordSigned($lParam))
	Local $iRefId = Selection_HitTest($fWxRef, $fWyRef, Input_PickTolMm())
	If $iRefId <> -1 Then
		Input_InsertFieldToken("s" & $iRefId & ".pos")
		Return True
	EndIf

	Local $iRefEdgeX, $iRefEdgeY
	Local $iRefHits = Input_HitBoxEdges($fWxRef, $fWyRef, $iRefEdgeX, $iRefEdgeY)
	If $iRefHits = 2 Then
		; Coin : comportement inchangé, l'utilisateur complète (w/l/h/t).
		Input_InsertFieldToken("b.")
		Return True
	ElseIf $iRefEdgeX <> -1 Then
		; Bord Ouest/Est seul : il court le long de l'axe Y → la longueur.
		Input_InsertFieldToken("b.l")
		Return True
	ElseIf $iRefEdgeY <> -1 Then
		; Bord Nord/Sud seul : il court le long de l'axe X → la largeur.
		Input_InsertFieldToken("b.w")
		Return True
	EndIf
	Return False
EndFunc   ;==>Input_TryInsertFieldReference

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

	; Pendant une saisie utilisateur active (cf. Input_IsActiveFieldEditing),
	; un clic sur un séparateur OU un BORD de la boîte insère sa référence
	; dans le champ en cours d'édition AU LIEU de sélectionner/créer — et NE
	; PREND PAS le focus du canevas (le champ doit rester actif). Un clic
	; ailleurs (dans une sous-zone, ou hors de tout) retombe sur le
	; comportement normal ci-dessous, qui fait perdre le focus au champ et
	; termine donc la saisie (cf. Input_CommitField sur EN_KILLFOCUS).
	If Input_IsActiveFieldEditing() Then
		If Input_TryInsertFieldReference($lParam) Then Return 0
	EndIf

	; Réclame le focus clavier : sans ça, le focus reste bloqué sur le dernier
	; champ édité (ex. la formule de position) et Suppr se bloque silencieusement
	; (cf. le garde-fou "focus Edit" du polling clavier ci-dessous), même après
	; avoir cliqué pour sélectionner un autre séparateur sur le canevas.
	_WinAPI_SetFocus($hWnd)

	Local $fWx = Camera_ScreenToWorldX(Input_LoWordSigned($lParam))
	Local $fWy = Camera_ScreenToWorldY(Input_HiWordSigned($lParam))

	; Priorité à la sélection : on ne crée jamais SUR un séparateur existant.
	Local $iId = Selection_HitTest($fWx, $fWy, Input_PickTolMm())
	Local $bWasExisting = ($iId <> -1) ; pour ne pas empiler deux fois plus bas (cf. démarrage du drag)

	; Puis aux parois : drag d'un bord = redimensionnement d'un axe ;
	; drag d'un COIN = redimensionnement des deux axes à la fois.
	If $iId = -1 Then
		Local $iEdgeX, $iEdgeY
		If Input_HitBoxEdges($fWx, $fWy, $iEdgeX, $iEdgeY) > 0 Then
			Undo_PushSnapshot() ; état d'avant-glisser — un seul instantané pour tout le geste
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
		; Capturé AVANT de tenter la création (peut échouer — sous-zone trop
		; étroite —, auquel cas rien n'est empilé : cf. Undo_CaptureNow).
		Local $aPreCreate = Undo_CaptureNow()
		$iId = Metier_CreateSeparator($fWx, $fWy, $iOrient, $bGlobal, UI_GetActiveLayer())
		If $iId <> -1 Then
			Undo_PushCaptured($aPreCreate) ; couvre aussi le glisser qui suit immédiatement (même geste)
			UI_MarkProjectModified()
			App_InvalidateView() ; le modèle a changé, quoi qu'il arrive à la sélection
		EndIf
	EndIf

	Input_ApplySelection($iId)

	; Démarre le drag : le séparateur (sélectionné ou fraîchement créé) suit
	; la souris jusqu'au relâchement. La capture garantit la continuité même
	; quand le curseur sort du canvas. Instantané Annuler UNIQUEMENT si ce
	; séparateur existait déjà avant ce clic (sinon : déjà couvert ci-dessus,
	; par la capture de la création — un seul instantané pour create+glisser).
	If $iId <> -1 Then
		If $bWasExisting Then Undo_PushSnapshot()
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

	; Applique la dernière position mémorisée AVANT de clore le geste : la
	; coalescence (cf. $g_bInpDragPending) peut avoir un mouvement en attente.
	Input_ProcessPendingDrag()

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
; Double-clic gauche : édition rapide au clavier, sans passer par le panneau.
;   - sur un séparateur → focus + sélection totale du champ Position (le
;     simple clic qui précède le double-clic l'a déjà sélectionné, cf.
;     Input_OnLButtonDown — ici on ne fait qu'amener le focus clavier dessus) ;
;   - sur un bord de la boîte → focus + sélection totale du champ Largeur
;     (bords Ouest/Est) ou Longueur (bords Nord/Sud) ; un COIN (les deux bords
;     à la fois) édite la Largeur — choix arbitraire, l'autre axe n'est qu'un
;     Tab plus loin une fois le focus posé.
; Pendant une saisie utilisateur active (cf. Input_IsActiveFieldEditing), le
; double-clic se comporte comme le simple clic : insertion de référence, sans
; changer le champ ayant le focus (cf. Input_TryInsertFieldReference).
; -----------------------------------------------------------------------------
Func Input_OnLButtonDblClk($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam
	If $hWnd <> UI_GetCanvasHwnd() Then Return $GUI_RUNDEFMSG

	If Input_IsActiveFieldEditing() Then
		Input_TryInsertFieldReference($lParam)
		Return 0
	EndIf

	Local $fWx = Camera_ScreenToWorldX(Input_LoWordSigned($lParam))
	Local $fWy = Camera_ScreenToWorldY(Input_HiWordSigned($lParam))

	Local $iId = Selection_HitTest($fWx, $fWy, Input_PickTolMm())
	If $iId <> -1 Then
		Input_ApplySelection($iId)
		Input_FocusFieldSelectAll($g_idUiSepPosInput)
		Return 0
	EndIf

	Local $iEdgeX, $iEdgeY
	If Input_HitBoxEdges($fWx, $fWy, $iEdgeX, $iEdgeY) > 0 Then
		; Bord seul → le champ de l'axe qu'il borne ; coin (les deux à la fois,
		; $iEdgeX renseigné aussi) → Largeur par défaut.
		Local $iBoxField = ($iEdgeX = -1 And $iEdgeY <> -1) ? $BOX_LENGTH : $BOX_WIDTH
		Input_FocusFieldSelectAll($g_aidUiBoxInputs[$iBoxField])
	EndIf
	Return 0
EndFunc   ;==>Input_OnLButtonDblClk

; Donne le focus clavier à un champ suivi et sélectionne tout son contenu —
; même geste que la navigation Tab (cf. Input_FocusNextField) : prêt à
; retaper une valeur immédiatement après le double-clic.
Func Input_FocusFieldSelectAll($iCtrlId)
	Local $hCtrl = GUICtrlGetHandle($iCtrlId)
	_WinAPI_SetFocus($hCtrl)
	_GUICtrlEdit_SetSel($hCtrl, 0, -1)
EndFunc   ;==>Input_FocusFieldSelectAll

; -----------------------------------------------------------------------------
; Clic droit : sélection uniquement (cahier des charges) — jamais de création.
; -----------------------------------------------------------------------------
Func Input_OnRButtonDown($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam
	If $hWnd <> UI_GetCanvasHwnd() Then Return $GUI_RUNDEFMSG

	_WinAPI_SetFocus($hWnd) ; cf. Input_OnLButtonDown : évite que Suppr reste bloqué

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

	; --- Tab : navigue entre les champs suivis (SHIFT+Tab : sens inverse) ---
	Local $bTab = _IsPressed($INP_VK_TAB, $g_hInpUser32)
	If $bTab And Not $g_bInpPrevTab And $g_iInpFocusedField <> 0 Then
		Input_FocusNextField(_IsPressed($INP_VK_SHIFT, $g_hInpUser32))
	EndIf
	$g_bInpPrevTab = $bTab

	; --- Entrée : sort du mode édition du champ suivi actif. Le retrait de
	;     focus déclenche EN_KILLFOCUS, qui valide déjà le champ (cf.
	;     Input_OnCommand) — un seul point de commit, pas de duplication. ---
	Local $bReturn = _IsPressed($INP_VK_RETURN, $g_hInpUser32)
	If $bReturn And Not $g_bInpPrevReturn And $g_iInpFocusedField <> 0 Then
		_WinAPI_SetFocus(UI_GetCanvasHwnd())
	EndIf
	$g_bInpPrevReturn = $bReturn

	; Haut/Bas (incrément/décrément du champ suivi actif) : PAS de polling ici
	; — cf. UI_SetUpDownAccelActive/Input_OnUpDownAccel. Un simple polling ne
	; peut pas empêcher le contrôle Edit natif de réagir en même temps (une
	; flèche Haut/Bas y déplace silencieusement le curseur d'un caractère,
	; comme une flèche Droite/Gauche, AVANT même que ce polling ne s'exécute —
	; le jeton ajusté n'est alors plus celui sous le curseur affiché à
	; l'utilisateur). Seul un accélérateur GUI intercepte la touche AVANT
	; qu'elle n'atteigne le contrôle.
EndFunc   ;==>Input_PollKeys

; -----------------------------------------------------------------------------
; Déplacement souris :
;   - pan en temps réel pendant le drag milieu ;
;   - drag gauche (séparateur ou bord de boîte) : position simplement
;     MÉMORISÉE — appliquée par Input_ProcessPendingDrag au rythme de la
;     boucle principale (coalescence, cf. $g_bInpDragPending) ;
;   - sinon, suivi de la sous-zone survolée (retour visuel de création).
; -----------------------------------------------------------------------------
Func Input_OnMouseMove($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $wParam
	If $hWnd <> UI_GetCanvasHwnd() Then Return $GUI_RUNDEFMSG

	Local $iX = Input_LoWordSigned($lParam)
	Local $iY = Input_HiWordSigned($lParam)

	; La bulle de survol n'a de sens que hors manipulation (pan/drag) — sinon
	; elle resterait figée sur la dernière position pointée avant le drag.
	If $g_bInpPanning Or $g_iInpDragEdgeX <> -1 Or $g_iInpDragEdgeY <> -1 Or $g_iInpDragSepId <> -1 Then UI_HoverTipHide()

	If $g_bInpPanning Then
		Camera_PanByPixels($iX - $g_iInpLastX, $iY - $g_iInpLastY)
		App_InvalidateView()
	ElseIf $g_iInpDragEdgeX <> -1 Or $g_iInpDragEdgeY <> -1 Or $g_iInpDragSepId <> -1 Then
		; Drag en cours : on ne fait que MÉMORISER la position — le travail
		; réel (métier + panneau) est fait par Input_ProcessPendingDrag au
		; rythme de la boucle principale (cf. déclaration de $g_bInpDragPending).
		$g_iInpDragPendX = $iX
		$g_iInpDragPendY = $iY
		$g_bInpDragPending = True
	Else
		Local $fWx = Camera_ScreenToWorldX($iX)
		Local $fWy = Camera_ScreenToWorldY($iY)

		; Sous-zone sous le curseur (invalidation seulement si elle change).
		If Selection_SetHoverZone(Zones_FindAt($fWx, $fWy)) Then App_InvalidateView()

		Local $iSepHit = Selection_HitTest($fWx, $fWy, Input_PickTolMm())

		; Curseur : ↔/↕ au survol d'un séparateur (selon son orientation, comme
		; pour un bord de boîte — indique qu'il est déplaçable) ; sinon
		; redimensionnement au survol d'un bord/coin de la boîte. 13 = ↔,
		; 11 = ↕, 10/12 = diagonales.
		Local $iEdgeX = -1, $iEdgeY = -1
		If $iSepHit <> -1 Then
			Local $iHitRow = Project_SepFindById($iSepHit)
			Local $bVert = ($iHitRow <> -1) And (Project_SepGet($iHitRow, $SEP_ORIENT) = $SEP_ORIENT_V)
			Input_SetHoverCursor($bVert ? 13 : 11)
		Else
			Input_HitBoxEdges($fWx, $fWy, $iEdgeX, $iEdgeY)
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

		; Bulle de survol : nom du séparateur ("sN"), bord/coin de la boîte
		; ("b"), ou — dans une sous-zone — sa taille (toujours affichée au
		; survol, indépendamment du mode d'affichage centré, cf. Renderer.au3).
		Local $iZoneHover = Selection_GetHoverZone()
		If $iSepHit <> -1 Then
			Input_ShowHoverLabel("s" & $iSepHit, $hWnd, $iX, $iY)
		ElseIf $iEdgeX <> -1 Or $iEdgeY <> -1 Then
			Input_ShowHoverLabel("b", $hWnd, $iX, $iY)
		ElseIf $iZoneHover <> -1 Then
			Local $fZoneW = $g_aZones[$iZoneHover][$ZONE_X2] - $g_aZones[$iZoneHover][$ZONE_X1]
			Local $fZoneH = $g_aZones[$iZoneHover][$ZONE_Y2] - $g_aZones[$iZoneHover][$ZONE_Y1]
			Input_ShowHoverLabel(UI_FmtMm($fZoneW) & " × " & UI_FmtMm($fZoneH), $hWnd, $iX, $iY)
		Else
			UI_HoverTipHide()
		EndIf
	EndIf

	$g_iInpLastX = $iX
	$g_iInpLastY = $iY
	Return 0
EndFunc   ;==>Input_OnMouseMove

; -----------------------------------------------------------------------------
; Applique la dernière position de drag mémorisée (cf. $g_bInpDragPending) :
; déplacement métier clampé + rafraîchissement du panneau. Appelée par la
; boucle principale au rythme du rendu, et par Input_OnLButtonUp (flush final).
; -----------------------------------------------------------------------------
Func Input_ProcessPendingDrag()
	If Not $g_bInpDragPending Then Return
	$g_bInpDragPending = False

	Local $iX = $g_iInpDragPendX, $iY = $g_iInpDragPendY
	If $g_iInpDragEdgeX <> -1 Or $g_iInpDragEdgeY <> -1 Then
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
			; Metier_DragSeparator (pas Metier_MoveSeparator) : un séparateur
			; piloté par une formule "sN.pos [+ K]" simple se laisse glisser —
			; la formule est réécrite avec la nouvelle constante (cf. Zones.au3).
			If Metier_DragSeparator($g_iInpDragSepId, $fCursor - $g_fInpDragGrab) Then
				UI_RefreshSeparatorPosition() ; position ET formule éventuellement réécrite
				UI_MarkProjectModified()
				App_InvalidateView()
			EndIf
		EndIf
	EndIf
EndFunc   ;==>Input_ProcessPendingDrag

; Affiche la bulle de survol $sText près du curseur — ($iX, $iY) sont des
; coordonnées CLIENT canevas, converties en coordonnées écran pour la bulle
; (fenêtre popup indépendante, positionnée en absolu).
Func Input_ShowHoverLabel($sText, $hWnd, $iX, $iY)
	Local $tPt = DllStructCreate("long X;long Y")
	DllStructSetData($tPt, "X", $iX)
	DllStructSetData($tPt, "Y", $iY)
	_WinAPI_ClientToScreen($hWnd, $tPt)
	UI_HoverTipShow($sText, DllStructGetData($tPt, "X"), DllStructGetData($tPt, "Y"))
EndFunc   ;==>Input_ShowHoverLabel