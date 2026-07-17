#include-once
#include "Project.au3"
#include "Zones.au3"

; =============================================================================
; DXF.au3 — Génération des pièces au format DXF (niveau 5 : export).
;
; Ne dépend QUE des données métier (Project/Zones) : jamais du renderer,
; jamais de l'UI. Format DXF R12 ASCII (POLYLINE fermées), unités : mm.
;
; --- Pièces générées -----------------------------------------------------------
; Structure (layer DXF "STRUCTURE") :
;   - fond : plaque pleine taille (Width × Length), encoches de pourtour pour
;     les tenons des côtés, trous pour les tenons des séparateurs ;
;   - 4 côtés (hauteur = boîte) : coins à queues droites (les côtés N/S sont
;     entaillés, les côtés E/O portent les languettes complémentaires),
;     tenons inférieurs traversant le fond, encoches supérieures au droit de
;     chaque séparateur qui rencontre le côté.
;
; Séparateurs (layers DXF "SEP_L00".."SEP_L29") :
;   - les segments ALIGNÉS d'un même groupe SHIFT sont fusionnés en UNE pièce
;     continue (décision métier) : c'est elle qui « croise » les autres ;
;   - encoches mi-bois aux croisements : encoche HAUTE sur l'horizontal
;     (profondeur : h≤v → h/2, sinon h−v/2), encoche BASSE sur le vertical
;     (profondeur : min(h,v)/2) ; à un contact en T, seule la pièce TRAVERSÉE
;     reçoit son encoche ;
;   - créneaux inférieurs : tenons traversants (hauteur = épaisseur du fond),
;     période = longueur + espacement du layer, motif centré ;
;   - extrémité contre une paroi : la pièce se prolonge de l'épaisseur de la
;     paroi avec une encoche de fixation en bas (profondeur = hauteur/2) ; la
;     languette haute restante plonge dans l'encoche supérieure du côté.
;
; Les positions des tenons/encoches qui doivent coïncider (tenons ↔ trous du
; fond, motifs des côtés ↔ pourtour du fond) sont calculées par les MÊMES
; fonctions avec les mêmes paramètres : correspondance garantie.
; =============================================================================

; --- Tolérance géométrique (mm) et mise en page ---
Global Const $DXF_EPS          = 0.01 ; comparaison de coordonnées monde
Global Const $DXF_GAP          = 15.0 ; espace entre pièces posées (mm)
Global Const $DXF_EDGE_MARGIN  = 5.0  ; marge minimale d'un motif au bord d'une pièce
Global Const $DXF_NOTCH_MARGIN = 2.0  ; garde entre un tenon et une encoche basse
Global Const $DXF_LABEL_H      = 8.0  ; hauteur du texte des étiquettes (mm)

; --- Runs : pièces de séparateur après fusion des segments alignés d'un groupe ---
Global Enum $DXFRUN_ORIENT, _  ; $SEP_ORIENT_V / $SEP_ORIENT_H
		$DXFRUN_POS, _         ; position de la ligne (mm)
		$DXFRUN_LAYER, _       ; layer matière (0..29)
		$DXFRUN_START, _       ; début de la pièce le long de la portée (mm)
		$DXFRUN_END, _         ; fin (mm)
		$DXFRUN_WALL1, _       ; True si l'extrémité START touche une paroi
		$DXFRUN_WALL2, _       ; True si l'extrémité END touche une paroi
		$DXFRUN_FIELD_COUNT

; --- Encoches d'intersection calculées sur les runs ---
Global Enum $DXFN_RUN, _       ; index du run porteur de l'encoche
		$DXFN_CENTER, _        ; centre de l'encoche le long de la portée (mm)
		$DXFN_WIDTH, _         ; largeur (= épaisseur de la pièce croisée)
		$DXFN_DEPTH, _         ; profondeur (mm)
		$DXFN_TOP, _           ; True = encoche haute, False = encoche basse
		$DXFN_FIELD_COUNT

; --- Tenons inférieurs des séparateurs (coordonnée monde le long de la portée) ---
Global Enum $DXFT_RUN, $DXFT_S0, $DXFT_S1, $DXFT_FIELD_COUNT

; --- État de travail de l'export (reconstruit à chaque appel) ---
Global $g_aDxfRuns[0][$DXFRUN_FIELD_COUNT]
Global $g_aDxfNotches[0][$DXFN_FIELD_COUNT]
Global $g_aDxfTenons[0][$DXFT_FIELD_COUNT]

; --- Mise en page (curseur de placement des pièces, rangées empilées en +Y) ---
Global $g_fDxfCurX = 0.0
Global $g_fDxfCurY = 0.0
Global $g_fDxfRowH = 0.0
Global $g_fDxfWrapW = 1200.0

; =============================================================================
; HELPERS GÉOMÉTRIQUES
; =============================================================================

Func _DXF_Min($a, $b)
	Return ($a < $b) ? $a : $b
EndFunc   ;==>_DXF_Min

Func _DXF_Max($a, $b)
	Return ($a > $b) ? $a : $b
EndFunc   ;==>_DXF_Max

; Profondeur d'une encoche haute (règle du cahier des charges, utilisée pour
; les séparateurs horizontaux ET les côtés) :
;   pièce ≤ autre → pièce/2 ; sinon → pièce − autre/2.
Func _DXF_TopNotchDepth($fPieceH, $fOtherH)
	If $fPieceH <= $fOtherH Then Return $fPieceH / 2
	Return $fPieceH - $fOtherH / 2
EndFunc   ;==>_DXF_TopNotchDepth

; --- Liste de points (contour d'une pièce) -------------------------------------
Func _DXF_PtInit(ByRef $aPts)
	ReDim $aPts[0][2]
EndFunc   ;==>_DXF_PtInit

Func _DXF_PtAdd(ByRef $aPts, $fX, $fY)
	Local $iN = UBound($aPts)
	ReDim $aPts[$iN + 1][2]
	$aPts[$iN][0] = $fX
	$aPts[$iN][1] = $fY
EndFunc   ;==>_DXF_PtAdd

; Tri par insertion d'une liste d'intervalles [s0|s1|…] sur la colonne 0.
; (Effectifs minuscules : la simplicité prime.)
Func _DXF_SortIntervals(ByRef $aInt)
	Local $iCols = UBound($aInt, 2)
	For $i = 1 To UBound($aInt) - 1
		For $j = $i To 1 Step -1
			If $aInt[$j][0] >= $aInt[$j - 1][0] Then ExitLoop
			For $k = 0 To $iCols - 1
				Local $vTmp = $aInt[$j][$k]
				$aInt[$j][$k] = $aInt[$j - 1][$k]
				$aInt[$j - 1][$k] = $vTmp
			Next
		Next
	Next
EndFunc   ;==>_DXF_SortIntervals

; -----------------------------------------------------------------------------
; Motif de créneaux centré sur [$fStart..$fEnd] (coordonnées monde) :
; n tenons de longueur $fLen séparés de $fGap, à au moins $fMargin des bords.
; Remplit $aOut[n][2] (s0, s1) et retourne n (0 si l'espace manque).
; -----------------------------------------------------------------------------
Func _DXF_PatternIntervals($fStart, $fEnd, $fLen, $fGap, $fMargin, ByRef $aOut)
	ReDim $aOut[0][2]
	Local $fUsable = ($fEnd - $fMargin) - ($fStart + $fMargin)
	If $fUsable < $fLen Then Return 0

	Local $iN = Int(($fUsable + $fGap) / ($fLen + $fGap))
	Local $fTotal = $iN * $fLen + ($iN - 1) * $fGap
	Local $fS = $fStart + $fMargin + ($fUsable - $fTotal) / 2

	ReDim $aOut[$iN][2]
	For $i = 0 To $iN - 1
		$aOut[$i][0] = $fS + $i * ($fLen + $fGap)
		$aOut[$i][1] = $aOut[$i][0] + $fLen
	Next
	Return $iN
EndFunc   ;==>_DXF_PatternIntervals

; -----------------------------------------------------------------------------
; Découpage des coins à queues droites : la hauteur des côtés est divisée en un
; nombre IMPAIR de segments alternés (~ longueur de créneau de la boîte).
; Segments pairs (0, 2, …) = matière des côtés N/S ; impairs = matière E/O.
; Remplit $aOut[k][2] avec les intervalles IMPAIRS (utilisés en entaille sur
; N/S et en languette sur E/O : mêmes intervalles, complémentarité garantie).
; -----------------------------------------------------------------------------
Func _DXF_CornerFingerIntervals($fHeight, $fFingerLen, ByRef $aOut)
	Local $iN = Int($fHeight / $fFingerLen + 0.5)
	If $iN < 3 Then $iN = 3
	If Mod($iN, 2) = 0 Then $iN += 1
	Local $fSeg = $fHeight / $iN

	Local $iCount = Int(($iN - 1) / 2) ; segments impairs : 1, 3, …, n-2
	ReDim $aOut[$iCount][2]
	For $i = 0 To $iCount - 1
		$aOut[$i][0] = (2 * $i + 1) * $fSeg
		$aOut[$i][1] = $aOut[$i][0] + $fSeg
	Next
	Return $iCount
EndFunc   ;==>_DXF_CornerFingerIntervals

; =============================================================================
; CONSTRUCTION DES DONNÉES D'EXPORT (runs, encoches, tenons)
; =============================================================================

; -----------------------------------------------------------------------------
; Fusionne les segments alignés d'un même groupe en runs (pièces continues).
; Un séparateur isolé est un run à lui seul. Les drapeaux WALL1/WALL2 indiquent
; si l'extrémité touche une paroi de la boîte (→ encoche de fixation).
; -----------------------------------------------------------------------------
Func _DXF_BuildRuns()
	ReDim $g_aDxfRuns[0][$DXFRUN_FIELD_COUNT]

	Local $fIx1 = Box_InteriorX($g_aPrjBox)
	Local $fIy1 = Box_InteriorY($g_aPrjBox)
	Local $fIx2 = $fIx1 + Box_InteriorW($g_aPrjBox)
	Local $fIy2 = $fIy1 + Box_InteriorH($g_aPrjBox)

	Local $iCount = Project_SepCount()
	Local $iFlagSize = ($iCount > 0) ? $iCount : 1 ; un subscript ne peut pas être une expression ternaire
	Local $aDone[$iFlagSize]

	For $i = 0 To $iCount - 1
		If $aDone[$i] Then ContinueLoop
		$aDone[$i] = True
		If Project_SepLength($i) <= $DXF_EPS Then ContinueLoop ; segment dégénéré

		; Collecte des portées : le segment, plus ceux de son groupe (un groupe
		; partage orientation et position par construction).
		Local $aSpans[1][2] = [[Project_SepGet($i, $SEP_SPAN1), Project_SepGet($i, $SEP_SPAN2)]]
		Local $iGroup = Project_SepGet($i, $SEP_GROUP)
		If $iGroup <> $SEP_NO_GROUP Then
			For $j = $i + 1 To $iCount - 1
				If $aDone[$j] Or Project_SepGet($j, $SEP_GROUP) <> $iGroup Then ContinueLoop
				$aDone[$j] = True
				If Project_SepLength($j) <= $DXF_EPS Then ContinueLoop
				Local $iK = UBound($aSpans)
				ReDim $aSpans[$iK + 1][2]
				$aSpans[$iK][0] = Project_SepGet($j, $SEP_SPAN1)
				$aSpans[$iK][1] = Project_SepGet($j, $SEP_SPAN2)
			Next
		EndIf
		_DXF_SortIntervals($aSpans)

		; Fusion des portées contiguës (elles se touchent exactement au droit
		; d'un séparateur perpendiculaire) → runs.
		Local $iOrient = Project_SepGet($i, $SEP_ORIENT)
		Local $fWallLo = ($iOrient = $SEP_ORIENT_V) ? $fIy1 : $fIx1
		Local $fWallHi = ($iOrient = $SEP_ORIENT_V) ? $fIy2 : $fIx2

		Local $fS = $aSpans[0][0], $fE = $aSpans[0][1]
		For $iK = 1 To UBound($aSpans) - 1
			If $aSpans[$iK][0] <= $fE + $DXF_EPS Then
				If $aSpans[$iK][1] > $fE Then $fE = $aSpans[$iK][1]
			Else
				_DXF_AddRun($iOrient, Project_SepGet($i, $SEP_POS), Project_SepGet($i, $SEP_LAYER), _
						$fS, $fE, $fWallLo, $fWallHi)
				$fS = $aSpans[$iK][0]
				$fE = $aSpans[$iK][1]
			EndIf
		Next
		_DXF_AddRun($iOrient, Project_SepGet($i, $SEP_POS), Project_SepGet($i, $SEP_LAYER), _
				$fS, $fE, $fWallLo, $fWallHi)
	Next
EndFunc   ;==>_DXF_BuildRuns

Func _DXF_AddRun($iOrient, $fPos, $iLayer, $fStart, $fEnd, $fWallLo, $fWallHi)
	Local $iN = UBound($g_aDxfRuns)
	ReDim $g_aDxfRuns[$iN + 1][$DXFRUN_FIELD_COUNT]
	$g_aDxfRuns[$iN][$DXFRUN_ORIENT] = $iOrient
	$g_aDxfRuns[$iN][$DXFRUN_POS] = $fPos
	$g_aDxfRuns[$iN][$DXFRUN_LAYER] = $iLayer
	$g_aDxfRuns[$iN][$DXFRUN_START] = $fStart
	$g_aDxfRuns[$iN][$DXFRUN_END] = $fEnd
	$g_aDxfRuns[$iN][$DXFRUN_WALL1] = (Abs($fStart - $fWallLo) <= $DXF_EPS)
	$g_aDxfRuns[$iN][$DXFRUN_WALL2] = (Abs($fEnd - $fWallHi) <= $DXF_EPS)
EndFunc   ;==>_DXF_AddRun

; -----------------------------------------------------------------------------
; Encoches d'intersection entre runs (décision métier) :
;   - croisement complet (les deux runs continuent de part et d'autre) :
;     mi-bois → encoche haute sur l'horizontal ET basse sur le vertical ;
;   - contact en T : seule la pièce TRAVERSÉE reçoit son encoche ;
;   - contact en L (deux extrémités) : aucune encoche.
; -----------------------------------------------------------------------------
Func _DXF_BuildNotches()
	ReDim $g_aDxfNotches[0][$DXFN_FIELD_COUNT]

	For $iV = 0 To UBound($g_aDxfRuns) - 1
		If $g_aDxfRuns[$iV][$DXFRUN_ORIENT] <> $SEP_ORIENT_V Then ContinueLoop
		For $iH = 0 To UBound($g_aDxfRuns) - 1
			If $g_aDxfRuns[$iH][$DXFRUN_ORIENT] <> $SEP_ORIENT_H Then ContinueLoop

			Local $fVx = $g_aDxfRuns[$iV][$DXFRUN_POS] ; X du vertical
			Local $fHy = $g_aDxfRuns[$iH][$DXFRUN_POS] ; Y de l'horizontal

			; Contact ?
			If $fVx < $g_aDxfRuns[$iH][$DXFRUN_START] - $DXF_EPS Then ContinueLoop
			If $fVx > $g_aDxfRuns[$iH][$DXFRUN_END] + $DXF_EPS Then ContinueLoop
			If $fHy < $g_aDxfRuns[$iV][$DXFRUN_START] - $DXF_EPS Then ContinueLoop
			If $fHy > $g_aDxfRuns[$iV][$DXFRUN_END] + $DXF_EPS Then ContinueLoop

			; Qui continue de part et d'autre du contact ?
			Local $bHCrosses = ($fVx > $g_aDxfRuns[$iH][$DXFRUN_START] + $DXF_EPS) _
					And ($fVx < $g_aDxfRuns[$iH][$DXFRUN_END] - $DXF_EPS)
			Local $bVCrosses = ($fHy > $g_aDxfRuns[$iV][$DXFRUN_START] + $DXF_EPS) _
					And ($fHy < $g_aDxfRuns[$iV][$DXFRUN_END] - $DXF_EPS)

			Local $fHh = Project_LayerGet($g_aDxfRuns[$iH][$DXFRUN_LAYER], $LAYER_HEIGHT)
			Local $fVh = Project_LayerGet($g_aDxfRuns[$iV][$DXFRUN_LAYER], $LAYER_HEIGHT)

			; L'horizontal est traversé → encoche HAUTE sur l'horizontal.
			If $bHCrosses Then _DXF_AddNotch($iH, $fVx, _
					Project_LayerGet($g_aDxfRuns[$iV][$DXFRUN_LAYER], $LAYER_THICKNESS), _
					_DXF_TopNotchDepth($fHh, $fVh), True)
			; Le vertical est traversé → encoche BASSE sur le vertical.
			If $bVCrosses Then _DXF_AddNotch($iV, $fHy, _
					Project_LayerGet($g_aDxfRuns[$iH][$DXFRUN_LAYER], $LAYER_THICKNESS), _
					_DXF_Min($fHh, $fVh) / 2, False)
		Next
	Next
EndFunc   ;==>_DXF_BuildNotches

Func _DXF_AddNotch($iRun, $fCenter, $fWidth, $fDepth, $bTop)
	Local $iN = UBound($g_aDxfNotches)
	ReDim $g_aDxfNotches[$iN + 1][$DXFN_FIELD_COUNT]
	$g_aDxfNotches[$iN][$DXFN_RUN] = $iRun
	$g_aDxfNotches[$iN][$DXFN_CENTER] = $fCenter
	$g_aDxfNotches[$iN][$DXFN_WIDTH] = $fWidth
	$g_aDxfNotches[$iN][$DXFN_DEPTH] = $fDepth
	$g_aDxfNotches[$iN][$DXFN_TOP] = $bTop
EndFunc   ;==>_DXF_AddNotch

; -----------------------------------------------------------------------------
; Tenons inférieurs de chaque run : motif du layer (période = longueur +
; espacement), centré sur la portée ; un tenon qui chevaucherait une encoche
; basse est simplement omis.
; -----------------------------------------------------------------------------
Func _DXF_BuildTenons()
	ReDim $g_aDxfTenons[0][$DXFT_FIELD_COUNT]

	For $iRun = 0 To UBound($g_aDxfRuns) - 1
		Local $iLayer = $g_aDxfRuns[$iRun][$DXFRUN_LAYER]
		Local $aInt[0][2]
		_DXF_PatternIntervals($g_aDxfRuns[$iRun][$DXFRUN_START], $g_aDxfRuns[$iRun][$DXFRUN_END], _
				Project_LayerGet($iLayer, $LAYER_FINGER_LEN), _
				Project_LayerGet($iLayer, $LAYER_FINGER_SPACING), $DXF_EDGE_MARGIN, $aInt)

		For $i = 0 To UBound($aInt) - 1
			If _DXF_TenonHitsBottomNotch($iRun, $aInt[$i][0], $aInt[$i][1]) Then ContinueLoop
			Local $iN = UBound($g_aDxfTenons)
			ReDim $g_aDxfTenons[$iN + 1][$DXFT_FIELD_COUNT]
			$g_aDxfTenons[$iN][$DXFT_RUN] = $iRun
			$g_aDxfTenons[$iN][$DXFT_S0] = $aInt[$i][0]
			$g_aDxfTenons[$iN][$DXFT_S1] = $aInt[$i][1]
		Next
	Next
EndFunc   ;==>_DXF_BuildTenons

Func _DXF_TenonHitsBottomNotch($iRun, $fS0, $fS1)
	For $i = 0 To UBound($g_aDxfNotches) - 1
		If $g_aDxfNotches[$i][$DXFN_RUN] <> $iRun Then ContinueLoop
		If $g_aDxfNotches[$i][$DXFN_TOP] Then ContinueLoop
		Local $fN0 = $g_aDxfNotches[$i][$DXFN_CENTER] - $g_aDxfNotches[$i][$DXFN_WIDTH] / 2 - $DXF_NOTCH_MARGIN
		Local $fN1 = $g_aDxfNotches[$i][$DXFN_CENTER] + $g_aDxfNotches[$i][$DXFN_WIDTH] / 2 + $DXF_NOTCH_MARGIN
		If $fS1 > $fN0 And $fS0 < $fN1 Then Return True
	Next
	Return False
EndFunc   ;==>_DXF_TenonHitsBottomNotch

; Encoches (haute OU basse) d'un run, en intervalles triés [s0|s1|profondeur].
Func _DXF_RunNotchIntervals($iRun, $bTop, ByRef $aOut)
	ReDim $aOut[0][3]
	For $i = 0 To UBound($g_aDxfNotches) - 1
		If $g_aDxfNotches[$i][$DXFN_RUN] <> $iRun Then ContinueLoop
		If ($g_aDxfNotches[$i][$DXFN_TOP] = True) <> ($bTop = True) Then ContinueLoop
		Local $iN = UBound($aOut)
		ReDim $aOut[$iN + 1][3]
		$aOut[$iN][0] = $g_aDxfNotches[$i][$DXFN_CENTER] - $g_aDxfNotches[$i][$DXFN_WIDTH] / 2
		$aOut[$iN][1] = $g_aDxfNotches[$i][$DXFN_CENTER] + $g_aDxfNotches[$i][$DXFN_WIDTH] / 2
		$aOut[$iN][2] = $g_aDxfNotches[$i][$DXFN_DEPTH]
	Next
	_DXF_SortIntervals($aOut)
EndFunc   ;==>_DXF_RunNotchIntervals

; Tenons d'un run, en intervalles triés [s0|s1].
Func _DXF_RunTenonIntervals($iRun, ByRef $aOut)
	ReDim $aOut[0][2]
	For $i = 0 To UBound($g_aDxfTenons) - 1
		If $g_aDxfTenons[$i][$DXFT_RUN] <> $iRun Then ContinueLoop
		Local $iN = UBound($aOut)
		ReDim $aOut[$iN + 1][2]
		$aOut[$iN][0] = $g_aDxfTenons[$i][$DXFT_S0]
		$aOut[$iN][1] = $g_aDxfTenons[$i][$DXFT_S1]
	Next
	_DXF_SortIntervals($aOut)
EndFunc   ;==>_DXF_RunTenonIntervals

; =============================================================================
; ÉCRITURE DXF (R12 ASCII)
; =============================================================================

Func _DXF_Num($fValue)
	Return StringFormat("%.3f", $fValue)
EndFunc   ;==>_DXF_Num

; Polyligne fermée sur un layer DXF, avec décalage de placement.
Func _DXF_Polyline(ByRef $sOut, ByRef $aPts, $sLayer, $fOffX, $fOffY)
	$sOut &= "0" & @CRLF & "POLYLINE" & @CRLF & "8" & @CRLF & $sLayer & @CRLF _
			 & "66" & @CRLF & "1" & @CRLF & "70" & @CRLF & "1" & @CRLF
	For $i = 0 To UBound($aPts) - 1
		$sOut &= "0" & @CRLF & "VERTEX" & @CRLF & "8" & @CRLF & $sLayer & @CRLF _
				 & "10" & @CRLF & _DXF_Num($aPts[$i][0] + $fOffX) & @CRLF _
				 & "20" & @CRLF & _DXF_Num($aPts[$i][1] + $fOffY) & @CRLF
	Next
	$sOut &= "0" & @CRLF & "SEQEND" & @CRLF
EndFunc   ;==>_DXF_Polyline

; Étiquette texte (repérage des pièces, layer "LABELS").
Func _DXF_Label(ByRef $sOut, $sText, $fX, $fY)
	$sOut &= "0" & @CRLF & "TEXT" & @CRLF & "8" & @CRLF & "LABELS" & @CRLF _
			 & "10" & @CRLF & _DXF_Num($fX) & @CRLF & "20" & @CRLF & _DXF_Num($fY) & @CRLF _
			 & "40" & @CRLF & _DXF_Num($DXF_LABEL_H) & @CRLF & "1" & @CRLF & $sText & @CRLF
EndFunc   ;==>_DXF_Label

; --- Mise en page : réserve un emplacement (rangées empilées vers +Y) ---------
Func _DXF_LayoutReset($fWrapW)
	$g_fDxfCurX = 0.0
	$g_fDxfCurY = 0.0
	$g_fDxfRowH = 0.0
	$g_fDxfWrapW = $fWrapW
EndFunc   ;==>_DXF_LayoutReset

Func _DXF_LayoutPlace($fW, $fH, ByRef $fPlaceX, ByRef $fPlaceY)
	If $g_fDxfCurX > 0 And $g_fDxfCurX + $fW > $g_fDxfWrapW Then
		$g_fDxfCurX = 0.0
		$g_fDxfCurY += $g_fDxfRowH + $DXF_GAP
		$g_fDxfRowH = 0.0
	EndIf
	$fPlaceX = $g_fDxfCurX
	$fPlaceY = $g_fDxfCurY
	$g_fDxfCurX += $fW + $DXF_GAP
	If $fH > $g_fDxfRowH Then $g_fDxfRowH = $fH
EndFunc   ;==>_DXF_LayoutPlace

; Borne englobante d'une liste de points.
Func _DXF_Bounds(ByRef $aPts, ByRef $fMinX, ByRef $fMinY, ByRef $fMaxX, ByRef $fMaxY)
	$fMinX = $aPts[0][0]
	$fMinY = $aPts[0][1]
	$fMaxX = $fMinX
	$fMaxY = $fMinY
	For $i = 1 To UBound($aPts) - 1
		If $aPts[$i][0] < $fMinX Then $fMinX = $aPts[$i][0]
		If $aPts[$i][0] > $fMaxX Then $fMaxX = $aPts[$i][0]
		If $aPts[$i][1] < $fMinY Then $fMinY = $aPts[$i][1]
		If $aPts[$i][1] > $fMaxY Then $fMaxY = $aPts[$i][1]
	Next
EndFunc   ;==>_DXF_Bounds

; Place une pièce (contour + trous éventuels + étiquette) et l'écrit.
; $aHoles : tableau de listes de points ? AutoIt ne le permet pas simplement —
; les trous sont passés sous forme de rectangles [x0|y0|x1|y1].
Func _DXF_EmitPiece(ByRef $sOut, ByRef $aPts, ByRef $aHoleRects, $sLayer, $sLabel)
	Local $fMinX, $fMinY, $fMaxX, $fMaxY
	_DXF_Bounds($aPts, $fMinX, $fMinY, $fMaxX, $fMaxY)

	; Réserve : la pièce + son étiquette au-dessus.
	Local $fPlaceX, $fPlaceY
	_DXF_LayoutPlace($fMaxX - $fMinX, ($fMaxY - $fMinY) + $DXF_LABEL_H + 4, $fPlaceX, $fPlaceY)
	Local $fOffX = $fPlaceX - $fMinX
	Local $fOffY = $fPlaceY - $fMinY

	_DXF_Polyline($sOut, $aPts, $sLayer, $fOffX, $fOffY)
	For $i = 0 To UBound($aHoleRects) - 1
		Local $aHole[4][2] = [[$aHoleRects[$i][0], $aHoleRects[$i][1]], _
				[$aHoleRects[$i][2], $aHoleRects[$i][1]], _
				[$aHoleRects[$i][2], $aHoleRects[$i][3]], _
				[$aHoleRects[$i][0], $aHoleRects[$i][3]]]
		_DXF_Polyline($sOut, $aHole, $sLayer, $fOffX, $fOffY)
	Next
	_DXF_Label($sOut, $sLabel, $fPlaceX + 2, $fPlaceY + ($fMaxY - $fMinY) + 3)
EndFunc   ;==>_DXF_EmitPiece

; =============================================================================
; CONSTRUCTION DES CONTOURS DE PIÈCES
; =============================================================================

; -----------------------------------------------------------------------------
; Bord inférieur générique (parcouru de gauche à droite, y=0) : émet les
; excursions [s0|s1|dy] (dy<0 = tenon vers le bas, dy>0 = encoche vers le
; haut), toutes STRICTEMENT à l'intérieur du segment parcouru.
; -----------------------------------------------------------------------------
Func _DXF_EmitBottomFeatures(ByRef $aPts, ByRef $aFeat)
	For $i = 0 To UBound($aFeat) - 1
		_DXF_PtAdd($aPts, $aFeat[$i][0], 0)
		_DXF_PtAdd($aPts, $aFeat[$i][0], $aFeat[$i][2])
		_DXF_PtAdd($aPts, $aFeat[$i][1], $aFeat[$i][2])
		_DXF_PtAdd($aPts, $aFeat[$i][1], 0)
	Next
EndFunc   ;==>_DXF_EmitBottomFeatures

; Bord supérieur (parcouru de droite à gauche, y=$fH) : encoches [s0|s1|prof].
Func _DXF_EmitTopFeatures(ByRef $aPts, ByRef $aFeat, $fH)
	For $i = UBound($aFeat) - 1 To 0 Step -1
		_DXF_PtAdd($aPts, $aFeat[$i][1], $fH)
		_DXF_PtAdd($aPts, $aFeat[$i][1], $fH - $aFeat[$i][2])
		_DXF_PtAdd($aPts, $aFeat[$i][0], $fH - $aFeat[$i][2])
		_DXF_PtAdd($aPts, $aFeat[$i][0], $fH)
	Next
EndFunc   ;==>_DXF_EmitTopFeatures

; -----------------------------------------------------------------------------
; Pièce d'un run de séparateur, en coordonnées locales :
;   x = (coordonnée monde le long de la portée) − start + (paroi ? épaisseur : 0)
;   y = 0 (bas) .. hauteur du layer.
; Extrémité contre une paroi : prolongement d'une épaisseur de paroi avec
; encoche de fixation en bas (profondeur hauteur/2) → languette haute.
; -----------------------------------------------------------------------------
Func _DXF_BuildSepPiece($iRun, ByRef $aPts)
	Local $iLayer = $g_aDxfRuns[$iRun][$DXFRUN_LAYER]
	Local $fH = Project_LayerGet($iLayer, $LAYER_HEIGHT)
	Local $fT = Project_BoxGet($BOX_THICKNESS)      ; épaisseur parois/fond
	Local $fStart = $g_aDxfRuns[$iRun][$DXFRUN_START]
	Local $bW1 = $g_aDxfRuns[$iRun][$DXFRUN_WALL1]
	Local $bW2 = $g_aDxfRuns[$iRun][$DXFRUN_WALL2]

	Local $fXOff = ($bW1 ? $fT : 0) - $fStart ; monde → local
	Local $fLp = ($g_aDxfRuns[$iRun][$DXFRUN_END] - $fStart) + ($bW1 ? $fT : 0) + ($bW2 ? $fT : 0)

	; Features du bord inférieur : tenons (−épaisseur du fond) + encoches basses.
	Local $aTen[0][2], $aBot[0][3], $aTop[0][3]
	_DXF_RunTenonIntervals($iRun, $aTen)
	_DXF_RunNotchIntervals($iRun, False, $aBot)
	_DXF_RunNotchIntervals($iRun, True, $aTop)

	Local $aFeat[UBound($aTen) + UBound($aBot)][3]
	For $i = 0 To UBound($aTen) - 1
		$aFeat[$i][0] = $aTen[$i][0] + $fXOff
		$aFeat[$i][1] = $aTen[$i][1] + $fXOff
		$aFeat[$i][2] = -$fT ; tenon traversant : hauteur = épaisseur du fond
	Next
	For $i = 0 To UBound($aBot) - 1
		Local $iK = UBound($aTen) + $i
		$aFeat[$iK][0] = $aBot[$i][0] + $fXOff
		$aFeat[$iK][1] = $aBot[$i][1] + $fXOff
		$aFeat[$iK][2] = $aBot[$i][2] ; encoche basse : excursion vers le haut
	Next
	_DXF_SortIntervals($aFeat)

	; Encoches hautes en coordonnées locales.
	Local $aTopLoc[UBound($aTop)][3]
	For $i = 0 To UBound($aTop) - 1
		$aTopLoc[$i][0] = $aTop[$i][0] + $fXOff
		$aTopLoc[$i][1] = $aTop[$i][1] + $fXOff
		$aTopLoc[$i][2] = $aTop[$i][2]
	Next

	; --- Contour (sens horaire écran / anti-horaire mathématique) ---
	_DXF_PtInit($aPts)
	; Coin bas-gauche, avec encoche de fixation si paroi.
	If $bW1 Then
		_DXF_PtAdd($aPts, 0, $fH / 2)
		_DXF_PtAdd($aPts, $fT, $fH / 2)
		_DXF_PtAdd($aPts, $fT, 0)
	Else
		_DXF_PtAdd($aPts, 0, 0)
	EndIf
	; Bord inférieur (tenons + encoches basses).
	_DXF_EmitBottomFeatures($aPts, $aFeat)
	; Coin bas-droit, avec encoche de fixation si paroi.
	If $bW2 Then
		_DXF_PtAdd($aPts, $fLp - $fT, 0)
		_DXF_PtAdd($aPts, $fLp - $fT, $fH / 2)
		_DXF_PtAdd($aPts, $fLp, $fH / 2)
	Else
		_DXF_PtAdd($aPts, $fLp, 0)
	EndIf
	; Bord droit, bord supérieur (encoches hautes), bord gauche.
	_DXF_PtAdd($aPts, $fLp, $fH)
	_DXF_EmitTopFeatures($aPts, $aTopLoc, $fH)
	_DXF_PtAdd($aPts, 0, $fH)
EndFunc   ;==>_DXF_BuildSepPiece

; -----------------------------------------------------------------------------
; Pièce d'un côté. $bTabs : False = côtés N/S (entailles aux extrémités),
; True = côtés E/O (languettes complémentaires). $aSlots : encoches supérieures
; [s0|s1|prof] en coordonnées locales. $aTenons : tenons inférieurs [s0|s1].
; -----------------------------------------------------------------------------
Func _DXF_BuildSidePiece($fLen, $fHs, $fT, $fTFloor, $bTabs, ByRef $aFingers, ByRef $aSlots, ByRef $aTenons, ByRef $aPts)
	; Tenons → features du bord inférieur (excursion −épaisseur du fond).
	Local $aFeat[UBound($aTenons)][3]
	For $i = 0 To UBound($aTenons) - 1
		$aFeat[$i][0] = $aTenons[$i][0]
		$aFeat[$i][1] = $aTenons[$i][1]
		$aFeat[$i][2] = -$fTFloor
	Next

	; Excursion des extrémités : entaille vers l'intérieur (N/S) ou languette
	; vers l'extérieur (E/O), toutes strictement entre bas et haut.
	Local $fOff = $bTabs ? $fT : -$fT

	_DXF_PtInit($aPts)
	_DXF_PtAdd($aPts, 0, 0)
	_DXF_EmitBottomFeatures($aPts, $aFeat)
	_DXF_PtAdd($aPts, $fLen, 0)
	; Bord droit (montant) : queues droites.
	For $i = 0 To UBound($aFingers) - 1
		_DXF_PtAdd($aPts, $fLen, $aFingers[$i][0])
		_DXF_PtAdd($aPts, $fLen + $fOff, $aFingers[$i][0])
		_DXF_PtAdd($aPts, $fLen + $fOff, $aFingers[$i][1])
		_DXF_PtAdd($aPts, $fLen, $aFingers[$i][1])
	Next
	_DXF_PtAdd($aPts, $fLen, $fHs)
	; Bord supérieur (droite → gauche) : encoches des séparateurs.
	_DXF_EmitTopFeatures($aPts, $aSlots, $fHs)
	_DXF_PtAdd($aPts, 0, $fHs)
	; Bord gauche (descendant) : queues droites (miroir).
	For $i = UBound($aFingers) - 1 To 0 Step -1
		_DXF_PtAdd($aPts, 0, $aFingers[$i][1])
		_DXF_PtAdd($aPts, -$fOff, $aFingers[$i][1])
		_DXF_PtAdd($aPts, -$fOff, $aFingers[$i][0])
		_DXF_PtAdd($aPts, 0, $aFingers[$i][0])
	Next
EndFunc   ;==>_DXF_BuildSidePiece

; Encoches supérieures d'un côté : pour chaque run qui rencontre ce côté,
; intervalle local [s0|s1|prof]. $iOrientRun : orientation des runs concernés ;
; $iWallField : quelle extrémité du run touche CE côté ; $fSOffset : conversion
; position monde → coordonnée locale du côté.
Func _DXF_SideSlots($iOrientRun, $iWallField, $fSOffset, $fHs, ByRef $aOut)
	ReDim $aOut[0][3]
	For $i = 0 To UBound($g_aDxfRuns) - 1
		If $g_aDxfRuns[$i][$DXFRUN_ORIENT] <> $iOrientRun Then ContinueLoop
		If Not $g_aDxfRuns[$i][$iWallField] Then ContinueLoop
		Local $iLayer = $g_aDxfRuns[$i][$DXFRUN_LAYER]
		Local $fTk = Project_LayerGet($iLayer, $LAYER_THICKNESS)
		Local $iN = UBound($aOut)
		ReDim $aOut[$iN + 1][3]
		$aOut[$iN][0] = $g_aDxfRuns[$i][$DXFRUN_POS] + $fSOffset - $fTk / 2
		$aOut[$iN][1] = $g_aDxfRuns[$i][$DXFRUN_POS] + $fSOffset + $fTk / 2
		$aOut[$iN][2] = _DXF_TopNotchDepth($fHs, Project_LayerGet($iLayer, $LAYER_HEIGHT))
	Next
	_DXF_SortIntervals($aOut)
EndFunc   ;==>_DXF_SideSlots

; =============================================================================
; EXPORT COMPLET
; =============================================================================

; Nom du layer DXF d'un layer matière.
Func _DXF_SepLayerName($iLayer)
	Return StringFormat("SEP_L%02d", $iLayer)
EndFunc   ;==>_DXF_SepLayerName

; -----------------------------------------------------------------------------
; Génère le fichier DXF complet. Retourne True si le fichier est écrit.
; -----------------------------------------------------------------------------
Func DXF_Export($sPath)
	Local $fW = Project_BoxGet($BOX_WIDTH)
	Local $fL = Project_BoxGet($BOX_LENGTH)
	Local $fHs = Project_BoxGet($BOX_HEIGHT)
	Local $fT = Project_BoxGet($BOX_THICKNESS)
	Local $fFl = Project_BoxGet($BOX_FINGER_LEN)
	Local $fFs = Project_BoxGet($BOX_FINGER_SPACING)

	; --- Données d'export (dérivées du modèle métier) ---
	_DXF_BuildRuns()
	_DXF_BuildNotches()
	_DXF_BuildTenons()
	_DXF_LayoutReset(_DXF_Max(1200, $fW + $fL + 2 * $DXF_GAP))

	Local $sEnt = "" ; entités accumulées

	; --- Motifs partagés structure : calculés UNE fois, utilisés par les côtés
	;     ET par le pourtour du fond (correspondance garantie) ---
	Local $aFingers[0][2] ; queues droites des coins (intervalles en hauteur)
	_DXF_CornerFingerIntervals($fHs, $fFl, $aFingers)
	Local $aTenNS[0][2] ; tenons des côtés N/S (s = X monde, longueur W)
	_DXF_PatternIntervals($fT + $DXF_EDGE_MARGIN, $fW - $fT - $DXF_EDGE_MARGIN, $fFl, $fFs, 0, $aTenNS)
	Local $aTenEW[0][2] ; tenons des côtés E/O (s local, longueur L−2t)
	_DXF_PatternIntervals($DXF_EDGE_MARGIN, ($fL - 2 * $fT) - $DXF_EDGE_MARGIN, $fFl, $fFs, 0, $aTenEW)

	; --- Fond : contour W×L avec encoches de pourtour + trous des séparateurs ---
	Local $aPts[0][2]
	_DXF_BuildFloorOutline($fW, $fL, $fT, $aTenNS, $aTenEW, $aPts)
	Local $aHoles[0][4]
	_DXF_FloorHoles($aHoles)
	_DXF_EmitPiece($sEnt, $aPts, $aHoles, "STRUCTURE", "FOND")

	; --- Côtés ---
	Local $aNoHoles[0][4]
	Local $aSlots[0][3]

	; Nord (y monde = 0) : les séparateurs VERTICAUX dont la portée commence à
	; la paroi nord ; s local = X monde.
	_DXF_SideSlots($SEP_ORIENT_V, $DXFRUN_WALL1, 0, $fHs, $aSlots)
	_DXF_BuildSidePiece($fW, $fHs, $fT, $fT, False, $aFingers, $aSlots, $aTenNS, $aPts)
	_DXF_EmitPiece($sEnt, $aPts, $aNoHoles, "STRUCTURE", "COTE NORD")

	; Sud (y monde = L) : portée des verticaux finissant à la paroi sud.
	_DXF_SideSlots($SEP_ORIENT_V, $DXFRUN_WALL2, 0, $fHs, $aSlots)
	_DXF_BuildSidePiece($fW, $fHs, $fT, $fT, False, $aFingers, $aSlots, $aTenNS, $aPts)
	_DXF_EmitPiece($sEnt, $aPts, $aNoHoles, "STRUCTURE", "COTE SUD")

	; Ouest (x monde = 0) : horizontaux commençant à la paroi ouest ;
	; s local = Y monde − épaisseur (le côté E/O court entre les côtés N/S).
	_DXF_SideSlots($SEP_ORIENT_H, $DXFRUN_WALL1, -$fT, $fHs, $aSlots)
	_DXF_BuildSidePiece($fL - 2 * $fT, $fHs, $fT, $fT, True, $aFingers, $aSlots, $aTenEW, $aPts)
	_DXF_EmitPiece($sEnt, $aPts, $aNoHoles, "STRUCTURE", "COTE OUEST")

	; Est (x monde = W) : horizontaux finissant à la paroi est.
	_DXF_SideSlots($SEP_ORIENT_H, $DXFRUN_WALL2, -$fT, $fHs, $aSlots)
	_DXF_BuildSidePiece($fL - 2 * $fT, $fHs, $fT, $fT, True, $aFingers, $aSlots, $aTenEW, $aPts)
	_DXF_EmitPiece($sEnt, $aPts, $aNoHoles, "STRUCTURE", "COTE EST")

	; --- Séparateurs (une pièce par run, sur le layer DXF de leur matière) ---
	Local $aUsed[$LAYERS_COUNT] ; layers matière réellement utilisés (table DXF)
	For $iRun = 0 To UBound($g_aDxfRuns) - 1
		_DXF_BuildSepPiece($iRun, $aPts)
		Local $iLayer = $g_aDxfRuns[$iRun][$DXFRUN_LAYER]
		$aUsed[$iLayer] = True
		_DXF_EmitPiece($sEnt, $aPts, $aNoHoles, _DXF_SepLayerName($iLayer), _
				StringFormat("SEP %d (%s)", $iRun + 1, _
				Separator_OrientName($g_aDxfRuns[$iRun][$DXFRUN_ORIENT])))
	Next

	; --- Assemblage du fichier : en-tête + table des layers + entités ---
	Local $s = "0" & @CRLF & "SECTION" & @CRLF & "2" & @CRLF & "HEADER" & @CRLF _
			 & "9" & @CRLF & "$ACADVER" & @CRLF & "1" & @CRLF & "AC1009" & @CRLF _
			 & "0" & @CRLF & "ENDSEC" & @CRLF
	$s &= "0" & @CRLF & "SECTION" & @CRLF & "2" & @CRLF & "TABLES" & @CRLF _
			 & "0" & @CRLF & "TABLE" & @CRLF & "2" & @CRLF & "LAYER" & @CRLF _
			 & "70" & @CRLF & "32" & @CRLF
	$s &= _DXF_LayerDef("STRUCTURE", 7) & _DXF_LayerDef("LABELS", 8)
	For $i = 0 To $LAYERS_COUNT - 1
		If $aUsed[$i] Then $s &= _DXF_LayerDef(_DXF_SepLayerName($i), Mod($i, 6) + 1)
	Next
	$s &= "0" & @CRLF & "ENDTAB" & @CRLF & "0" & @CRLF & "ENDSEC" & @CRLF
	$s &= "0" & @CRLF & "SECTION" & @CRLF & "2" & @CRLF & "ENTITIES" & @CRLF _
			 & $sEnt & "0" & @CRLF & "ENDSEC" & @CRLF & "0" & @CRLF & "EOF" & @CRLF

	Local $hFile = FileOpen($sPath, 2)
	If $hFile = -1 Then Return False
	FileWrite($hFile, $s)
	FileClose($hFile)
	Return True
EndFunc   ;==>DXF_Export

Func _DXF_LayerDef($sName, $iColor)
	Return "0" & @CRLF & "LAYER" & @CRLF & "2" & @CRLF & $sName & @CRLF _
			 & "70" & @CRLF & "0" & @CRLF & "62" & @CRLF & $iColor & @CRLF _
			 & "6" & @CRLF & "CONTINUOUS" & @CRLF
EndFunc   ;==>_DXF_LayerDef

; -----------------------------------------------------------------------------
; Contour du fond : W×L avec encoches de pourtour (profondeur = épaisseur des
; parois) recevant les tenons des 4 côtés. Coordonnées locales = monde.
; -----------------------------------------------------------------------------
Func _DXF_BuildFloorOutline($fW, $fL, $fT, ByRef $aTenNS, ByRef $aTenEW, ByRef $aPts)
	_DXF_PtInit($aPts)

	; Bord nord (y=0, gauche → droite) : encoches vers +Y.
	_DXF_PtAdd($aPts, 0, 0)
	For $i = 0 To UBound($aTenNS) - 1
		_DXF_PtAdd($aPts, $aTenNS[$i][0], 0)
		_DXF_PtAdd($aPts, $aTenNS[$i][0], $fT)
		_DXF_PtAdd($aPts, $aTenNS[$i][1], $fT)
		_DXF_PtAdd($aPts, $aTenNS[$i][1], 0)
	Next
	; Bord est (x=W, montant) : encoches vers −X ; s local E/O → Y monde = s + t.
	_DXF_PtAdd($aPts, $fW, 0)
	For $i = 0 To UBound($aTenEW) - 1
		_DXF_PtAdd($aPts, $fW, $aTenEW[$i][0] + $fT)
		_DXF_PtAdd($aPts, $fW - $fT, $aTenEW[$i][0] + $fT)
		_DXF_PtAdd($aPts, $fW - $fT, $aTenEW[$i][1] + $fT)
		_DXF_PtAdd($aPts, $fW, $aTenEW[$i][1] + $fT)
	Next
	; Bord sud (y=L, droite → gauche) : encoches vers −Y.
	_DXF_PtAdd($aPts, $fW, $fL)
	For $i = UBound($aTenNS) - 1 To 0 Step -1
		_DXF_PtAdd($aPts, $aTenNS[$i][1], $fL)
		_DXF_PtAdd($aPts, $aTenNS[$i][1], $fL - $fT)
		_DXF_PtAdd($aPts, $aTenNS[$i][0], $fL - $fT)
		_DXF_PtAdd($aPts, $aTenNS[$i][0], $fL)
	Next
	; Bord ouest (x=0, descendant) : encoches vers +X.
	_DXF_PtAdd($aPts, 0, $fL)
	For $i = UBound($aTenEW) - 1 To 0 Step -1
		_DXF_PtAdd($aPts, 0, $aTenEW[$i][1] + $fT)
		_DXF_PtAdd($aPts, $fT, $aTenEW[$i][1] + $fT)
		_DXF_PtAdd($aPts, $fT, $aTenEW[$i][0] + $fT)
		_DXF_PtAdd($aPts, 0, $aTenEW[$i][0] + $fT)
	Next
EndFunc   ;==>_DXF_BuildFloorOutline

; -----------------------------------------------------------------------------
; Trous du fond : un rectangle par tenon de séparateur, exactement aux
; coordonnées monde du tenon (les créneaux générés correspondent par
; construction : mêmes intervalles $g_aDxfTenons).
; -----------------------------------------------------------------------------
Func _DXF_FloorHoles(ByRef $aHoles)
	ReDim $aHoles[UBound($g_aDxfTenons)][4]
	For $i = 0 To UBound($g_aDxfTenons) - 1
		Local $iRun = $g_aDxfTenons[$i][$DXFT_RUN]
		Local $fPos = $g_aDxfRuns[$iRun][$DXFRUN_POS]
		Local $fTk = Project_LayerGet($g_aDxfRuns[$iRun][$DXFRUN_LAYER], $LAYER_THICKNESS)
		If $g_aDxfRuns[$iRun][$DXFRUN_ORIENT] = $SEP_ORIENT_H Then
			$aHoles[$i][0] = $g_aDxfTenons[$i][$DXFT_S0]
			$aHoles[$i][1] = $fPos - $fTk / 2
			$aHoles[$i][2] = $g_aDxfTenons[$i][$DXFT_S1]
			$aHoles[$i][3] = $fPos + $fTk / 2
		Else
			$aHoles[$i][0] = $fPos - $fTk / 2
			$aHoles[$i][1] = $g_aDxfTenons[$i][$DXFT_S0]
			$aHoles[$i][2] = $fPos + $fTk / 2
			$aHoles[$i][3] = $g_aDxfTenons[$i][$DXFT_S1]
		EndIf
	Next
EndFunc   ;==>_DXF_FloorHoles
