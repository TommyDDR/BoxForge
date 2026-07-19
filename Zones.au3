#include-once
#include "Project.au3"

; =============================================================================
; Zones.au3 — Gestion métier (niveau 2) : sous-zones, intersections,
; contraintes, et opérations de haut niveau sur les séparateurs
; (création, déplacement, suppression).
;
; Aucune GDI, aucun DXF, aucune UI.
;
; --- Modèle "guillotine" -----------------------------------------------------
; L'intérieur de la boîte est découpé en SOUS-ZONES rectangulaires. Chaque
; séparateur, à la création, découpe entièrement UNE sous-zone (celle qui
; contient son point d'ancrage). Les sous-zones sont des DONNÉES DÉRIVÉES :
; après chaque mutation, Zones_Rebuild() les recalcule en réappliquant les
; découpes dans l'ordre de création (ordre des lignes de $g_aPrjSeps).
;
; Ce recalcul redonne aussi à chaque séparateur sa portée (Span1/Span2 =
; étendue de la sous-zone découpée) : quand une frontière bouge, les
; extrémités des séparateurs qui s'appuyaient dessus suivent naturellement.
;
; L'ancre est re-normalisée au MILIEU de la portée après chaque recalcul.
; Combiné au déplacement PAR PETITS PAS (Metier_MoveSeparator), cela garantit
; que l'ancre reste dans la bonne sous-zone même quand une frontière voisine
; se déplace : la topologie évolue continûment, jamais par saut.
;
; --- Contraintes ---------------------------------------------------------------
; - Deux séparateurs parallèles ne peuvent jamais être plus proches que
;   $ZONES_MIN_GAP (10 mm) — parois de la boîte comprises.
; - Un séparateur ne sort jamais de sa sous-zone : son déplacement est clampé
;   entre les frontières parallèles adjacentes (± la marge).
; - Les segments d'un même groupe (création SHIFT) partagent leur position et
;   se déplacent ensemble : le clamp est l'INTERSECTION des plages de tous
;   les segments du groupe.
; =============================================================================

; --- Champs de la structure Sous-zone (rectangle intérieur, mm) ---
Global Enum $ZONE_X1, $ZONE_Y1, $ZONE_X2, $ZONE_Y2, $ZONE_FIELD_COUNT

; --- Champs de la structure Intersection (contact entre un séparateur
;     vertical et un horizontal ; recalculée par Zones_Rebuild) ---
Global Enum $ISECT_V_ID, _     ; identifiant du séparateur vertical
		$ISECT_H_ID, _         ; identifiant du séparateur horizontal
		$ISECT_X, _            ; position X du contact (mm)
		$ISECT_Y, _            ; position Y du contact (mm)
		$ISECT_FIELD_COUNT

; --- Données dérivées du projet courant ---
Global $g_aZones[0][$ZONE_FIELD_COUNT]
Global $g_aIsects[0][$ISECT_FIELD_COUNT]

; --- Contraintes et tolérances ---
Global Const $ZONES_MIN_GAP      = 10.0   ; écart minimal entre séparateurs (mm)
Global Const $ZONES_EPS          = 0.0005 ; tolérance de comparaison flottante (mm)
Global Const $ZONES_MOVE_STEP_MM = 5.0    ; pas minimal d'un déplacement métier (mm)
Global Const $ZONES_MOVE_MAX_STEPS = 40   ; pas répartis sur un déplacement d'un coup

; --- Helpers numériques locaux -------------------------------------------------
Func _Zones_Clamp($fValue, $fLo, $fHi)
	If $fValue < $fLo Then Return $fLo
	If $fValue > $fHi Then Return $fHi
	Return $fValue
EndFunc   ;==>_Zones_Clamp

; =============================================================================
; SOUS-ZONES (recalcul)
; =============================================================================

; -----------------------------------------------------------------------------
; Recalcule TOUTES les données dérivées : sous-zones, portées des séparateurs,
; ancres (re-normalisées au milieu de portée), intersections.
; À appeler après toute mutation du modèle (création, déplacement, suppression,
; changement de dimensions de la boîte, chargement de projet).
; -----------------------------------------------------------------------------
Func Zones_Rebuild()
	_Zones_RebuildZonesOnly()
	Zones_RebuildIntersections()
EndFunc   ;==>Zones_Rebuild

; Partie coûteuse (O(n²)) de Zones_Rebuild SANS les intersections : utilisée
; pour les pas intermédiaires d'un déplacement (_Metier_MoveOne), où les
; intersections ($g_aIsects, données de reporting seulement) n'ont pas besoin
; d'être à jour à chaque pas — l'appelant de haut niveau les refait une seule
; fois à la fin du déplacement.
Func _Zones_RebuildZonesOnly()
	; Sous-zone initiale : l'intérieur complet de la boîte.
	Local $fIx1, $fIy1, $fIx2, $fIy2
	Project_BoxInterior($fIx1, $fIy1, $fIx2, $fIy2)
	ReDim $g_aZones[1][$ZONE_FIELD_COUNT]
	$g_aZones[0][$ZONE_X1] = $fIx1
	$g_aZones[0][$ZONE_Y1] = $fIy1
	$g_aZones[0][$ZONE_X2] = $fIx2
	$g_aZones[0][$ZONE_Y2] = $fIy2

	; Réapplique chaque découpe dans l'ordre de création.
	For $iRow = 0 To Project_SepCount() - 1
		_Zones_ApplySplit($iRow)
	Next
EndFunc   ;==>_Zones_RebuildZonesOnly

Func Zones_Count()
	Return UBound($g_aZones)
EndFunc   ;==>Zones_Count

; -----------------------------------------------------------------------------
; Sous-zone contenant STRICTEMENT le point ($fX, $fY). -1 si aucune.
; Strict (à $ZONES_EPS près) : un point posé sur une frontière n'appartient à
; aucune zone — les ancres et positions clampées en restent toujours éloignées.
; -----------------------------------------------------------------------------
Func Zones_FindAt($fX, $fY)
	For $i = 0 To UBound($g_aZones) - 1
		If $fX > $g_aZones[$i][$ZONE_X1] + $ZONES_EPS And $fX < $g_aZones[$i][$ZONE_X2] - $ZONES_EPS _
				And $fY > $g_aZones[$i][$ZONE_Y1] + $ZONES_EPS And $fY < $g_aZones[$i][$ZONE_Y2] - $ZONES_EPS Then
			Return $i
		EndIf
	Next
	Return -1
EndFunc   ;==>Zones_FindAt

; -----------------------------------------------------------------------------
; Découpe par le séparateur $iRow de la sous-zone contenant son ancre :
;   - la sous-zone est scindée en deux le long de Pos ;
;   - la portée du séparateur (Span1/Span2) = étendue de la sous-zone découpée ;
;   - l'ancre est re-normalisée au milieu de la portée.
; -----------------------------------------------------------------------------
Func _Zones_ApplySplit($iRow)
	Local $iOrient = Project_SepGet($iRow, $SEP_ORIENT)
	Local $fPos = Project_SepGet($iRow, $SEP_POS)
	Local $fAnchor = Project_SepGet($iRow, $SEP_ANCHOR)

	; Point d'ancrage : (Pos, Anchor) pour un vertical, (Anchor, Pos) sinon.
	Local $iZone
	If $iOrient = $SEP_ORIENT_V Then
		$iZone = Zones_FindAt($fPos, $fAnchor)
	Else
		$iZone = Zones_FindAt($fAnchor, $fPos)
	EndIf

	If $iZone = -1 Then
		; Incohérence (créations/déplacements clampés : ne doit pas arriver).
		; Portée dégénérée → segment invisible, sans effet sur les zones.
		Project_SepSet($iRow, $SEP_SPAN1, $fPos)
		Project_SepSet($iRow, $SEP_SPAN2, $fPos)
		Return
	EndIf

	; Nouvelle sous-zone : copie de la zone découpée…
	Local $iNew = UBound($g_aZones)
	ReDim $g_aZones[$iNew + 1][$ZONE_FIELD_COUNT]
	For $j = 0 To $ZONE_FIELD_COUNT - 1
		$g_aZones[$iNew][$j] = $g_aZones[$iZone][$j]
	Next

	; … puis scission le long de l'axe : l'existante garde le côté "avant Pos",
	; la nouvelle reçoit le côté "après Pos".
	If $iOrient = $SEP_ORIENT_V Then
		Project_SepSet($iRow, $SEP_SPAN1, $g_aZones[$iZone][$ZONE_Y1])
		Project_SepSet($iRow, $SEP_SPAN2, $g_aZones[$iZone][$ZONE_Y2])
		$g_aZones[$iZone][$ZONE_X2] = $fPos
		$g_aZones[$iNew][$ZONE_X1] = $fPos
	Else
		Project_SepSet($iRow, $SEP_SPAN1, $g_aZones[$iZone][$ZONE_X1])
		Project_SepSet($iRow, $SEP_SPAN2, $g_aZones[$iZone][$ZONE_X2])
		$g_aZones[$iZone][$ZONE_Y2] = $fPos
		$g_aZones[$iNew][$ZONE_Y1] = $fPos
	EndIf

	; Ancre re-normalisée au milieu de la portée (cf. en-tête du module).
	Project_SepSet($iRow, $SEP_ANCHOR, _
			(Project_SepGet($iRow, $SEP_SPAN1) + Project_SepGet($iRow, $SEP_SPAN2)) / 2)
EndFunc   ;==>_Zones_ApplySplit

; Milieu d'une sous-zone le long de la PORTÉE d'un séparateur d'orientation
; $iOrient (utilisé comme ancre à la création).
Func _Zones_ZoneMidAnchor($iZone, $iOrient)
	If $iOrient = $SEP_ORIENT_V Then
		Return ($g_aZones[$iZone][$ZONE_Y1] + $g_aZones[$iZone][$ZONE_Y2]) / 2
	EndIf
	Return ($g_aZones[$iZone][$ZONE_X1] + $g_aZones[$iZone][$ZONE_X2]) / 2
EndFunc   ;==>_Zones_ZoneMidAnchor

; =============================================================================
; INTERSECTIONS (données dérivées pour les propriétés et l'export DXF)
; =============================================================================

; -----------------------------------------------------------------------------
; Recense tous les contacts entre séparateurs verticaux et horizontaux :
; V.Pos dans la portée du H ET H.Pos dans la portée du V (extrémités incluses).
; -----------------------------------------------------------------------------
Func Zones_RebuildIntersections()
	ReDim $g_aIsects[0][$ISECT_FIELD_COUNT]

	For $iV = 0 To Project_SepCount() - 1
		If Project_SepGet($iV, $SEP_ORIENT) <> $SEP_ORIENT_V Then ContinueLoop
		For $iH = 0 To Project_SepCount() - 1
			If Project_SepGet($iH, $SEP_ORIENT) <> $SEP_ORIENT_H Then ContinueLoop

			Local $fVx = Project_SepGet($iV, $SEP_POS)
			Local $fHy = Project_SepGet($iH, $SEP_POS)
			If $fVx < Project_SepGet($iH, $SEP_SPAN1) - $ZONES_EPS Then ContinueLoop
			If $fVx > Project_SepGet($iH, $SEP_SPAN2) + $ZONES_EPS Then ContinueLoop
			If $fHy < Project_SepGet($iV, $SEP_SPAN1) - $ZONES_EPS Then ContinueLoop
			If $fHy > Project_SepGet($iV, $SEP_SPAN2) + $ZONES_EPS Then ContinueLoop

			Local $iNew = UBound($g_aIsects)
			ReDim $g_aIsects[$iNew + 1][$ISECT_FIELD_COUNT]
			$g_aIsects[$iNew][$ISECT_V_ID] = Project_SepGet($iV, $SEP_ID)
			$g_aIsects[$iNew][$ISECT_H_ID] = Project_SepGet($iH, $SEP_ID)
			$g_aIsects[$iNew][$ISECT_X] = $fVx
			$g_aIsects[$iNew][$ISECT_Y] = $fHy
		Next
	Next
EndFunc   ;==>Zones_RebuildIntersections

Func Zones_IntersectionCount()
	Return UBound($g_aIsects)
EndFunc   ;==>Zones_IntersectionCount

; =============================================================================
; CONTRAINTES (plages de déplacement)
; =============================================================================

; -----------------------------------------------------------------------------
; Frontières parallèles adjacentes au séparateur $iRow, SANS la marge :
; pour chaque sous-zone qui touche le séparateur (recouvrement de portée),
; la frontière opposée de cette zone borne le déplacement de ce côté.
; -----------------------------------------------------------------------------
Func Zones_GetSepBounds($iRow, ByRef $fMin, ByRef $fMax)
	Local $iOrient = Project_SepGet($iRow, $SEP_ORIENT)
	Local $fPos = Project_SepGet($iRow, $SEP_POS)
	Local $fS1 = Project_SepGet($iRow, $SEP_SPAN1)
	Local $fS2 = Project_SepGet($iRow, $SEP_SPAN2)

	; Bornes par défaut : les parois intérieures de la boîte.
	Local $fIx1, $fIy1, $fIx2, $fIy2
	Project_BoxInterior($fIx1, $fIy1, $fIx2, $fIy2)
	If $iOrient = $SEP_ORIENT_V Then
		$fMin = $fIx1
		$fMax = $fIx2
	Else
		$fMin = $fIy1
		$fMax = $fIy2
	EndIf

	For $i = 0 To UBound($g_aZones) - 1
		; Bornes de la zone le long de l'axe du séparateur / de sa portée.
		Local $fAxis1, $fAxis2, $fAlong1, $fAlong2
		If $iOrient = $SEP_ORIENT_V Then
			$fAxis1 = $g_aZones[$i][$ZONE_X1]
			$fAxis2 = $g_aZones[$i][$ZONE_X2]
			$fAlong1 = $g_aZones[$i][$ZONE_Y1]
			$fAlong2 = $g_aZones[$i][$ZONE_Y2]
		Else
			$fAxis1 = $g_aZones[$i][$ZONE_Y1]
			$fAxis2 = $g_aZones[$i][$ZONE_Y2]
			$fAlong1 = $g_aZones[$i][$ZONE_X1]
			$fAlong2 = $g_aZones[$i][$ZONE_X2]
		EndIf

		; La zone doit recouvrir la portée du séparateur (pas juste la toucher).
		Local $fLo = ($fS1 > $fAlong1) ? $fS1 : $fAlong1
		Local $fHi = ($fS2 < $fAlong2) ? $fS2 : $fAlong2
		If $fHi - $fLo <= $ZONES_EPS Then ContinueLoop

		; Zone collée à gauche/en haut : sa frontière opposée borne $fMin.
		If Abs($fAxis2 - $fPos) <= $ZONES_EPS And $fAxis1 > $fMin Then $fMin = $fAxis1
		; Zone collée à droite/en bas : sa frontière opposée borne $fMax.
		If Abs($fAxis1 - $fPos) <= $ZONES_EPS And $fAxis2 < $fMax Then $fMax = $fAxis2
	Next
EndFunc   ;==>Zones_GetSepBounds

; -----------------------------------------------------------------------------
; Plage de déplacement autorisée (marge de 10 mm incluse) pour le séparateur
; $iRow. Si le séparateur appartient à un groupe, la plage est l'INTERSECTION
; des plages de tous les segments du groupe (ils bougent d'un bloc).
; Peut retourner $fMin > $fMax : aucun déplacement possible.
; -----------------------------------------------------------------------------
Func Zones_GetMoveRange($iRow, ByRef $fMin, ByRef $fMax)
	Zones_GetSepBounds($iRow, $fMin, $fMax)

	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)
	If $iGroup <> $SEP_NO_GROUP Then
		For $i = 0 To Project_SepCount() - 1
			If $i = $iRow Then ContinueLoop
			If Project_SepGet($i, $SEP_GROUP) <> $iGroup Then ContinueLoop
			Local $fLo, $fHi
			Zones_GetSepBounds($i, $fLo, $fHi)
			If $fLo > $fMin Then $fMin = $fLo
			If $fHi < $fMax Then $fMax = $fHi
		Next
	EndIf

	$fMin += $ZONES_MIN_GAP
	$fMax -= $ZONES_MIN_GAP
EndFunc   ;==>Zones_GetMoveRange

; =============================================================================
; OPÉRATIONS MÉTIER (création / déplacement / suppression / projet)
; =============================================================================

; -----------------------------------------------------------------------------
; Nouveau projet complet : données + recalcul des dérivées.
; -----------------------------------------------------------------------------
Func Metier_NewProject()
	Project_New()
	Zones_Rebuild()
EndFunc   ;==>Metier_NewProject

; -----------------------------------------------------------------------------
; Création d'un séparateur au point monde ($fWx, $fWy) :
;   - $iOrient  : $SEP_ORIENT_V (clic) ou $SEP_ORIENT_H (CTRL+clic) ;
;   - $bGlobal  : False → ne traverse que la sous-zone cliquée ;
;                 True (SHIFT) → traverse TOUTES les sous-zones : un segment
;                 par sous-zone, tous liés par un même groupe ;
;   - $iLayer   : layer des segments créés.
; La position est clampée dans la sous-zone cliquée (marge 10 mm) ; en mode
; global, seules les sous-zones offrant la marge des deux côtés reçoivent un
; segment (la ligne "saute" les couloirs trop étroits).
; Retourne l'identifiant du segment de la sous-zone cliquée, ou -1 si la
; création est impossible (hors zones, ou sous-zone trop étroite).
; -----------------------------------------------------------------------------
Func Metier_CreateSeparator($fWx, $fWy, $iOrient, $bGlobal, $iLayer)
	Local $iZone = Zones_FindAt($fWx, $fWy)
	If $iZone = -1 Then Return -1

	; Bornes de la sous-zone cliquée le long de l'axe de position.
	Local $fLo, $fHi
	If $iOrient = $SEP_ORIENT_V Then
		$fLo = $g_aZones[$iZone][$ZONE_X1]
		$fHi = $g_aZones[$iZone][$ZONE_X2]
	Else
		$fLo = $g_aZones[$iZone][$ZONE_Y1]
		$fHi = $g_aZones[$iZone][$ZONE_Y2]
	EndIf

	; Sous-zone trop étroite : impossible d'y placer un séparateur en
	; respectant l'écart minimal des deux côtés.
	If $fHi - $fLo < 2 * $ZONES_MIN_GAP Then Return -1

	Local $fPos = ($iOrient = $SEP_ORIENT_V) ? $fWx : $fWy
	$fPos = Round(_Zones_Clamp($fPos, $fLo + $ZONES_MIN_GAP, $fHi - $ZONES_MIN_GAP), 2)

	Local $iId = -1
	If Not $bGlobal Then
		$iId = Project_SepAdd($SEP_NO_GROUP, $iOrient, $fPos, _Zones_ZoneMidAnchor($iZone, $iOrient), $iLayer)
	Else
		; Création globale : un segment par sous-zone traversée par la ligne.
		; Itération sur un instantané des zones AVANT découpe (chaque segment
		; vise une sous-zone distincte : l'ordre d'ajout est indifférent).
		Local $iGroup = Project_SepAllocGroupId()
		For $i = 0 To UBound($g_aZones) - 1
			Local $fZLo, $fZHi
			If $iOrient = $SEP_ORIENT_V Then
				$fZLo = $g_aZones[$i][$ZONE_X1]
				$fZHi = $g_aZones[$i][$ZONE_X2]
			Else
				$fZLo = $g_aZones[$i][$ZONE_Y1]
				$fZHi = $g_aZones[$i][$ZONE_Y2]
			EndIf
			If $fPos < $fZLo + $ZONES_MIN_GAP Then ContinueLoop
			If $fPos > $fZHi - $ZONES_MIN_GAP Then ContinueLoop

			Local $iNewId = Project_SepAdd($iGroup, $iOrient, $fPos, _Zones_ZoneMidAnchor($i, $iOrient), $iLayer)
			If $i = $iZone Then $iId = $iNewId ; segment de la sous-zone cliquée
		Next
	EndIf

	Zones_Rebuild()
	Return $iId
EndFunc   ;==>Metier_CreateSeparator

; Applique une position à un séparateur ET à tous les segments de son groupe.
; Toute position écrite au modèle est arrondie au centième de millimètre.
Func _Zones_SetGroupPos($iRow, $fPos)
	$fPos = Round($fPos, 2)
	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)
	Project_SepSet($iRow, $SEP_POS, $fPos)
	If $iGroup = $SEP_NO_GROUP Then Return
	For $i = 0 To Project_SepCount() - 1
		If Project_SepGet($i, $SEP_GROUP) = $iGroup Then Project_SepSet($i, $SEP_POS, $fPos)
	Next
EndFunc   ;==>_Zones_SetGroupPos

; -----------------------------------------------------------------------------
; Après un déplacement EN UN SEUL PAS (cf. $bSingleStep de _Metier_MoveOne) du
; séparateur $iRow (et de son groupe) depuis $fOldPos : fait suivre les ancres
; des séparateurs PERPENDICULAIRES dont la portée s'appuyait sur lui.
; Le déplacement par petits pas garantit cette cohérence naturellement (l'ancre,
; re-normalisée au milieu de portée à chaque pas, ne peut pas être enjambée par
; un pas borné) ; en un seul pas, un grand delta peut passer PAR-DESSUS une
; ancre restée en place : au recalcul, le perpendiculaire serait rattaché à la
; sous-zone de l'AUTRE côté (un horizontal à droite d'un vertical "sautait" à
; sa gauche lors d'un drag rapide). On déplace donc l'extrémité d'appui de
; chaque ancre AVANT le recalcul : le perpendiculaire reste du même côté,
; quelle que soit l'amplitude du pas.
; À appeler APRÈS l'écriture de la nouvelle position, AVANT le recalcul des
; sous-zones (les portées lues ici sont encore celles d'avant le déplacement).
; -----------------------------------------------------------------------------
Func _Zones_FollowAbuttingAnchors($iRow, $fOldPos)
	Local $iOrient = Project_SepGet($iRow, $SEP_ORIENT)
	Local $fNewPos = Project_SepGet($iRow, $SEP_POS)
	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)

	For $i = 0 To Project_SepCount() - 1
		If Project_SepGet($i, $SEP_ORIENT) = $iOrient Then ContinueLoop

		; Une extrémité de la portée du perpendiculaire sur l'ANCIENNE position…
		Local $fS1 = Project_SepGet($i, $SEP_SPAN1)
		Local $fS2 = Project_SepGet($i, $SEP_SPAN2)
		Local $bAtS1 = (Abs($fS1 - $fOldPos) <= $ZONES_EPS)
		If Not $bAtS1 And Abs($fS2 - $fOldPos) > $ZONES_EPS Then ContinueLoop

		; … et sa ligne croise la portée d'un des segments déplacés (deux
		; parallèles non liés peuvent partager la même position avec des
		; portées disjointes : ne pas confondre leurs appuis).
		Local $fPerpPos = Project_SepGet($i, $SEP_POS)
		Local $bTouches = False
		For $j = 0 To Project_SepCount() - 1
			If $j <> $iRow And ($iGroup = $SEP_NO_GROUP Or Project_SepGet($j, $SEP_GROUP) <> $iGroup) Then ContinueLoop
			If $fPerpPos < Project_SepGet($j, $SEP_SPAN1) - $ZONES_EPS Then ContinueLoop
			If $fPerpPos > Project_SepGet($j, $SEP_SPAN2) + $ZONES_EPS Then ContinueLoop
			$bTouches = True
			ExitLoop
		Next
		If Not $bTouches Then ContinueLoop

		; L'extrémité d'appui suit le déplacement : ancre re-posée au milieu
		; de la portée attendue (même normalisation que _Zones_ApplySplit).
		If $bAtS1 Then
			Project_SepSet($i, $SEP_ANCHOR, ($fNewPos + $fS2) / 2)
		Else
			Project_SepSet($i, $SEP_ANCHOR, ($fS1 + $fNewPos) / 2)
		EndIf
	Next
EndFunc   ;==>_Zones_FollowAbuttingAnchors

; -----------------------------------------------------------------------------
; PRIMITIVE de déplacement d'un séparateur (par identifiant) vers $fTarget.
; C'est le SEUL chemin qui change une position : le drag, la saisie directe,
; les groupes SHIFT et la propagation des formules passent tous par ici.
; - Clampé en continu dans la plage autorisée (sous-zone + marge 10 mm) ;
; - groupe-aware : tous les segments liés bougent d'un bloc ;
; - AVANCE PAR PETITS PAS avec recalcul des sous-zones à chaque pas : la
;   topologie évolue continûment (les portées des séparateurs perpendiculaires
;   s'ajustent au fur et à mesure), même pour une grande distance demandée
;   d'un coup (saisie directe, formule).
;   Le pas est ADAPTATIF ($ZONES_MOVE_STEP_MM minimum, distance totale répartie
;   sur $ZONES_MOVE_MAX_STEPS sinon) : un petit déplacement (drag souris normal)
;   garde la granularité fine d'origine, un grand déplacement d'un coup (grand
;   mouvement de drag, formule) est réparti sur un nombre borné de pas — sans
;   quoi jusqu'à 400 recalculs complets de sous-zones (coût O(n²) chacun)
;   s'enchaîneraient dans un seul événement souris et gèleraient l'UI.
;   Les intersections ($g_aIsects) ne sont recalculées qu'une fois à la fin
;   (simple donnée de reporting, inutile de la tenir à jour à chaque pas).
; $bSingleStep (drag souris EN DIRECT, cf. Metier_DragSeparator) : saute la
;   subdivision — un seul clamp + un seul recalcul, quelle que soit la
;   distance demandée. La granularité vient déjà de la cadence des
;   WM_MOUSEMOVE (un appel = un pas réel) ; subdiviser EN PLUS à l'intérieur
;   de chaque appel revenait à multiplier jusqu'à 40 recalculs O(n²) par
;   événement — pendant un drag rapide (grands déltas écran → grands déltas
;   monde entre deux WM_MOUSEMOVE), ce coût se répétait à CHAQUE événement et
;   le traitement prenait du retard sur la souris (gel qui grossit puis
;   "rattrape" d'un coup). Les portées perpendiculaires qui n'ont pas eu le
;   temps de suivre progressivement se remettent à jour au prochain
;   WM_MOUSEMOVE de toute façon.
; NE propage PAS les formules (voir Metier_MoveSeparator / ApplyFormulas).
; Retourne True si la position a effectivement changé.
; -----------------------------------------------------------------------------
Func _Metier_MoveOne($iId, $fTarget, $bSingleStep = False)
	Local $iRow = Project_SepFindById($iId)
	If $iRow = -1 Then Return False

	; La cible est alignée sur la granularité du modèle (centième) : une cible
	; plus fine serait inatteignable — la position, arrondie à l'écriture,
	; resterait à jamais à plus de $ZONES_EPS de la cible et la boucle
	; épuiserait son garde-fou en recalculs inutiles (freeze au drag).
	$fTarget = Round($fTarget, 2)

	If $bSingleStep Then
		Local $fMin, $fMax
		Zones_GetMoveRange($iRow, $fMin, $fMax)
		If $fMin > $fMax Then Return False ; aucun jeu disponible

		Local $fPos = Project_SepGet($iRow, $SEP_POS)
		Local $fClamped = _Zones_Clamp($fTarget, $fMin, $fMax)
		If Abs($fClamped - $fPos) <= $ZONES_EPS Then Return False

		_Zones_SetGroupPos($iRow, $fClamped)
		If Abs(Project_SepGet($iRow, $SEP_POS) - $fPos) <= $ZONES_EPS Then Return False ; absorbé par l'arrondi
		_Zones_FollowAbuttingAnchors($iRow, $fPos)
		_Zones_RebuildZonesOnly()
		Zones_RebuildIntersections()
		Return True
	EndIf

	Local $fStep = Abs($fTarget - Project_SepGet($iRow, $SEP_POS)) / $ZONES_MOVE_MAX_STEPS
	If $fStep < $ZONES_MOVE_STEP_MM Then $fStep = $ZONES_MOVE_STEP_MM

	Local $bMoved = False
	For $iGuard = 1 To 400 ; garde-fou absolu
		Local $fMin, $fMax
		Zones_GetMoveRange($iRow, $fMin, $fMax)
		If $fMin > $fMax Then ExitLoop ; aucun jeu disponible

		Local $fPos = Project_SepGet($iRow, $SEP_POS)
		Local $fDelta = _Zones_Clamp($fTarget, $fMin, $fMax) - $fPos
		If Abs($fDelta) <= $ZONES_EPS Then ExitLoop

		If $fDelta > $fStep Then $fDelta = $fStep
		If $fDelta < -$fStep Then $fDelta = -$fStep

		_Zones_SetGroupPos($iRow, $fPos + $fDelta)
		; Pas absorbé par l'arrondi : position inchangée, ne pas recalculer ni
		; prétendre avoir bougé (l'appelant s'appuie sur ce retour pour sortir).
		If Abs(Project_SepGet($iRow, $SEP_POS) - $fPos) <= $ZONES_EPS Then ExitLoop
		_Zones_RebuildZonesOnly()
		$bMoved = True
	Next
	If $bMoved Then Zones_RebuildIntersections()
	Return $bMoved
EndFunc   ;==>_Metier_MoveOne

; -----------------------------------------------------------------------------
; Déplacement UTILISATEUR d'un séparateur : refusé si sa position est pilotée
; par une formule (le séparateur est verrouillé — effacer la formule pour le
; libérer) ; sinon déplacement clampé ENTRELACÉ avec la propagation des
; formules : un séparateur piloté qui borne le pilote s'écarte en suivant sa
; formule, et le pilote peut alors continuer — le pilote "pousse" ses pilotés
; jusqu'à la cible ou jusqu'à un vrai blocage (paroi, séparateur libre).
; $bSingleStep (drag souris EN DIRECT, cf. Metier_DragSeparator) : un seul
; passage (un clamp + un recalcul), pas de boucle de progression — même
; raison qu'au même paramètre de _Metier_MoveOne, qu'il propage ici : la
; cadence des WM_MOUSEMOVE fournit déjà la granularité, ré-itérer EN PLUS à
; l'intérieur d'un seul événement ne fait que multiplier les recalculs O(n²)
; sans rien gagner en fluidité (le rattrapage se fait de toute façon à
; l'événement suivant).
; -----------------------------------------------------------------------------
Func Metier_MoveSeparator($iId, $fTarget, $bSingleStep = False)
	Local $iRow = Project_SepFindById($iId)
	If $iRow = -1 Then Return False
	If Project_SepGet($iRow, $SEP_FORMULA) <> "" Then Return False ; piloté

	; Même granularité que le modèle : le test de convergence ci-dessous
	; compare à une position arrondie au centième.
	$fTarget = Round($fTarget, 2)

	; Met d'abord les pilotés à leur place : l'un d'eux peut être collé au
	; pilote alors que sa formule l'attend plus loin (il libère le passage).
	Metier_ApplyFormulas()

	Local $bMoved = False
	For $iGuard = 1 To ($bSingleStep ? 1 : 100)
		If Not _Metier_MoveOne($iId, $fTarget, $bSingleStep) Then ExitLoop ; plus aucun progrès
		$bMoved = True
		Metier_ApplyFormulas() ; les pilotés suivent / s'écartent

		$iRow = Project_SepFindById($iId)
		If Abs(Project_SepGet($iRow, $SEP_POS) - $fTarget) <= $ZONES_EPS Then ExitLoop
	Next
	Return $bMoved
EndFunc   ;==>Metier_MoveSeparator

; -----------------------------------------------------------------------------
; True si $sFormula est EXACTEMENT de la forme "VAR", "VAR + K" ou "VAR - K"
; (une seule variable — référence "sN.pos" OU variable boîte "b.w/l/h/t" ou
; "w/l/h/t" nue —, constante additive optionnelle) — pose $sVarToken (le texte
; exact de la variable, à réinjecter tel quel dans la formule réécrite) et
; $fVarValue (sa valeur COURANTE). Utilisé par Metier_DragSeparator : toute
; formule plus riche (plusieurs variables, multiplication…) n'est PAS reconnue
; ici et reste verrouillée au drag (cf. Metier_MoveSeparator).
; -----------------------------------------------------------------------------
Func Zones_FormulaIsLinearVar($sFormula, ByRef $sVarToken, ByRef $fVarValue, ByRef $fOffset)
	Local $aM = StringRegExp($sFormula, "(?i)^\s*(s\d+\.pos|b\.[wlht]|[wlht])\s*([+\-]\s*[0-9]+(?:\.[0-9]+)?)?\s*$", 3)
	If @error Then Return False
	$sVarToken = $aM[0]
	If Not _Zones_FormulaEval($sVarToken, $fVarValue) Then Return False ; référence morte (sN supprimé)
	$fOffset = (UBound($aM) > 1 And $aM[1] <> "") ? Number(StringReplace($aM[1], " ", "")) : 0
	Return True
EndFunc   ;==>Zones_FormulaIsLinearVar

; -----------------------------------------------------------------------------
; Déplacement PAR GLISSEMENT SOURIS d'un séparateur : contrairement à
; Metier_MoveSeparator (saisie directe), un séparateur piloté par une formule
; "VAR [+ K]" simple (cf. Zones_FormulaIsLinearVar — "sN.pos" ou une variable
; boîte) n'est plus verrouillé — le glisser est autorisé et la constante K de
; la formule est réécrite pour refléter la nouvelle position (le pilotage par
; VAR est conservé). Toute formule plus complexe reste verrouillée
; (comportement inchangé pour ces cas). La saisie directe d'un nombre dans le
; champ Position continue, elle, de LIBÉRER la formule (cf.
; UI_ApplySeparatorPosition et Input_PreviewSepPos) — comportement distinct,
; volontairement inchangé.
; -----------------------------------------------------------------------------
Func Metier_DragSeparator($iId, $fTarget)
	Local $iRow = Project_SepFindById($iId)
	If $iRow = -1 Then Return False

	Local $sFormula = Project_SepGet($iRow, $SEP_FORMULA)
	If $sFormula = "" Then Return Metier_MoveSeparator($iId, $fTarget, True)

	Local $sVarToken, $fVarValue, $fOffset
	If Not Zones_FormulaIsLinearVar($sFormula, $sVarToken, $fVarValue, $fOffset) Then Return False ; verrouillé

	; Déplace directement via la primitive bas niveau (pas de garde "piloté" —
	; seul Metier_MoveSeparator l'a) : un seul pas, comme pour un séparateur
	; libre (cf. $bSingleStep de _Metier_MoveOne) — appelé à chaque
	; WM_MOUSEMOVE, la granularité vient déjà de la souris.
	If Not _Metier_MoveOne($iId, $fTarget, True) Then Return False

	; Réécrit la formule avec la constante correspondant à la position
	; réellement atteinte (après clamp), pour la ligne ET son groupe (même
	; partage que Metier_SetSeparatorFormula).
	$iRow = Project_SepFindById($iId)
	Local $fNewOffset = Project_SepGet($iRow, $SEP_POS) - $fVarValue
	Local $sNewFormula = $sVarToken
	If Abs($fNewOffset) > $ZONES_EPS Then
		$sNewFormula &= ($fNewOffset > 0 ? " + " & _Zones_FmtToken($fNewOffset) : " - " & _Zones_FmtToken(-$fNewOffset))
	EndIf

	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)
	For $i = 0 To Project_SepCount() - 1
		If $i = $iRow Or ($iGroup <> $SEP_NO_GROUP And Project_SepGet($i, $SEP_GROUP) = $iGroup) Then
			Project_SepSet($i, $SEP_FORMULA, $sNewFormula)
		EndIf
	Next

	Metier_ApplyFormulas() ; propage aux séparateurs qui dépendent de celui-ci
	Return True
EndFunc   ;==>Metier_DragSeparator

; =============================================================================
; FORMULES DE POSITION
;
; Une position peut être PILOTÉE par une formule arithmétique référençant
; d'autres séparateurs par identifiant : "s1.pos + 20" (insensible à la
; casse), et les dimensions INTÉRIEURES de la boîte :
;   b.w ou w → largeur intérieure  (Width  − 2 × épaisseur)
;   b.l ou l → longueur intérieure (Length − 2 × épaisseur)
;   b.h ou h → hauteur intérieure  (Height − épaisseur du fond)
;   b.t ou t → épaisseur du matériau de la structure
; Les positions étant relatives au coin intérieur de la boîte (origine 0,0),
; "w / 2" place un séparateur vertical au milieu de l'intérieur.
; Caractères autorisés : chiffres, point décimal, espaces, + - * / ( ) et
; ces jetons — rien d'autre (l'évaluation refuse tout le reste : aucune
; injection possible via Execute).
;
; Un séparateur piloté ne se déplace plus à la souris ni à la saisie ; il
; suit ses références (clampé par les contraintes habituelles). La
; propagation évalue les formules en ordre de dépendances ; les références
; circulaires sont refusées à la saisie, et une formule devenue inévaluable
; (référence supprimée) laisse simplement la position en l'état.
; Les segments d'un groupe SHIFT partagent la même formule (objet unique).
; =============================================================================

; Identifiants référencés par une formule (tableau de nombres, peut être vide).
Func _Zones_FormulaRefs($sFormula, ByRef $aIds)
	Local $aM = StringRegExp($sFormula, "(?i)s(\d+)\.pos", 3)
	If @error Then
		ReDim $aIds[0]
		Return 0
	EndIf
	ReDim $aIds[UBound($aM)]
	For $i = 0 To UBound($aM) - 1
		$aIds[$i] = Int(Number($aM[$i]))
	Next
	Return UBound($aIds)
EndFunc   ;==>_Zones_FormulaRefs

; Retire tous les jetons reconnus d'une formule : ce qui reste doit être de
; l'arithmétique pure. Partagé par la validation et le chargement de projet.
Func Zones_FormulaStripTokens($sFormula)
	Local $s = StringRegExpReplace($sFormula, "(?i)s\d+\.pos", "")
	$s = StringRegExpReplace($s, "(?i)\bb\.[wlht]\b", "")
	$s = StringRegExpReplace($s, "(?i)\b[wlht]\b", "")
	Return $s
EndFunc   ;==>Zones_FormulaStripTokens

; -----------------------------------------------------------------------------
; Évalue une formule. Retourne True et pose $fOut, ou False si la formule est
; inévaluable (référence absente, syntaxe, caractère interdit).
; -----------------------------------------------------------------------------
Func _Zones_FormulaEval($sFormula, ByRef $fOut)
	; Substitution des jetons sN.pos par la position courante du séparateur.
	Local $aIds[0]
	_Zones_FormulaRefs($sFormula, $aIds)
	Local $sExpr = $sFormula
	For $i = 0 To UBound($aIds) - 1
		Local $iRow = Project_SepFindById($aIds[$i])
		If $iRow = -1 Then Return False
		$sExpr = StringRegExpReplace($sExpr, "(?i)s" & $aIds[$i] & "\.pos", _
				StringFormat("%.6f", Project_SepGet($iRow, $SEP_POS)))
	Next

	; Variables de la boîte : dimensions INTÉRIEURES (voir en-tête).
	; Les formes préfixées "b.x" sont substituées AVANT les formes nues
	; (sinon \bw\b matcherait le w de "b.w").
	Local $fT = $g_aPrjBox[$BOX_THICKNESS]
	Local $sW = StringFormat("%.6f", $g_aPrjBox[$BOX_WIDTH] - 2 * $fT)
	Local $sL = StringFormat("%.6f", $g_aPrjBox[$BOX_LENGTH] - 2 * $fT)
	Local $sH = StringFormat("%.6f", $g_aPrjBox[$BOX_HEIGHT] - $fT)
	Local $sT = StringFormat("%.6f", $fT)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bb\.w\b", $sW)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bb\.l\b", $sL)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bb\.h\b", $sH)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bb\.t\b", $sT)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bw\b", $sW)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bl\b", $sL)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bh\b", $sH)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bt\b", $sT)

	; Défense en profondeur : expression purement arithmétique, sinon refus
	; (Execute est puissant — on ne lui passe JAMAIS de texte non filtré).
	If Not StringRegExp($sExpr, "^[0-9\.\s\+\-\*\/\(\)]+$") Then Return False

	Local $vResult = Execute($sExpr)
	If @error Or Not IsNumber($vResult) Then Return False
	$fOut = $vResult
	Return True
EndFunc   ;==>_Zones_FormulaEval

; Ensemble "soi-même" pour la détection de cycle : le segment et tous les
; co-membres de son groupe (ils partagent position et formule).
Func _Zones_SelfIds($iId, ByRef $aSelf)
	ReDim $aSelf[1]
	$aSelf[0] = $iId
	Local $iRow = Project_SepFindById($iId)
	If $iRow = -1 Then Return
	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)
	If $iGroup = $SEP_NO_GROUP Then Return
	For $i = 0 To Project_SepCount() - 1
		If Project_SepGet($i, $SEP_GROUP) = $iGroup And Project_SepGet($i, $SEP_ID) <> $iId Then
			ReDim $aSelf[UBound($aSelf) + 1]
			$aSelf[UBound($aSelf) - 1] = Project_SepGet($i, $SEP_ID)
		EndIf
	Next
EndFunc   ;==>_Zones_SelfIds

Func _Zones_IdInList($iId, ByRef $aList)
	For $i = 0 To UBound($aList) - 1
		If $aList[$i] = $iId Then Return True
	Next
	Return False
EndFunc   ;==>_Zones_IdInList

; Parcours des dépendances : True si, en suivant les formules existantes
; depuis $sFormula, on retombe sur $iSelfId (ou un co-membre de son groupe).
Func _Zones_FormulaReachesSelf($sFormula, $iSelfId)
	Local $aSelf[0]
	_Zones_SelfIds($iSelfId, $aSelf)

	Local $aStack[0], $aVisited[0]
	_Zones_FormulaRefs($sFormula, $aStack)

	While UBound($aStack) > 0
		Local $iId = $aStack[UBound($aStack) - 1]
		ReDim $aStack[UBound($aStack) - 1]

		If _Zones_IdInList($iId, $aSelf) Then Return True
		If _Zones_IdInList($iId, $aVisited) Then ContinueLoop
		ReDim $aVisited[UBound($aVisited) + 1]
		$aVisited[UBound($aVisited) - 1] = $iId

		Local $iRow = Project_SepFindById($iId)
		If $iRow = -1 Then ContinueLoop
		Local $aRefs[0]
		_Zones_FormulaRefs(Project_SepGet($iRow, $SEP_FORMULA), $aRefs)
		For $i = 0 To UBound($aRefs) - 1
			ReDim $aStack[UBound($aStack) + 1]
			$aStack[UBound($aStack) - 1] = $aRefs[$i]
		Next
	WEnd
	Return False
EndFunc   ;==>_Zones_FormulaReachesSelf

; -----------------------------------------------------------------------------
; Validation d'une formule pour le séparateur $iSelfId.
; Retourne "" si acceptable, sinon un message d'erreur pour l'utilisateur.
; -----------------------------------------------------------------------------
Func Metier_FormulaValidate($sFormula, $iSelfId)
	If $sFormula = "" Then Return "" ; effacement : toujours permis

	; Caractères : une fois les jetons retirés, seule l'arithmétique reste.
	If StringRegExp(Zones_FormulaStripTokens($sFormula), "[^0-9\.\s\+\-\*\/\(\)]") Then _
			Return "Caractères non autorisés. Attendu : nombres, + - * / ( ), sN.pos et " & _
			"les variables boîte w, l, h, t (ou b.w, b.l, b.h, b.t) — dimensions intérieures."

	; Références existantes ?
	Local $aIds[0]
	_Zones_FormulaRefs($sFormula, $aIds)
	For $i = 0 To UBound($aIds) - 1
		If Project_SepFindById($aIds[$i]) = -1 Then _
				Return "Séparateur s" & $aIds[$i] & " introuvable."
	Next

	; Auto-référence / cycle (le groupe compte comme soi-même).
	If _Zones_FormulaReachesSelf($sFormula, $iSelfId) Then _
			Return "Référence circulaire : cette formule dépend (directement ou non) de ce séparateur."

	; Évaluation à blanc.
	Local $fVal
	If Not _Zones_FormulaEval($sFormula, $fVal) Then Return "Formule invalide."
	Return ""
EndFunc   ;==>Metier_FormulaValidate

; -----------------------------------------------------------------------------
; True si la formule référence au moins une variable (séparateur ou boîte) —
; utilisé par l'UI pour savoir si l'aperçu de saisie doit afficher la bulle
; de traduction (une formule purement numérique n'a rien à traduire).
; -----------------------------------------------------------------------------
Func Zones_FormulaHasVariable($sFormula)
	If StringRegExp($sFormula, "(?i)s\d+\.pos") Then Return True
	If StringRegExp($sFormula, "(?i)\bb\.[wlht]\b") Then Return True
	If StringRegExp($sFormula, "(?i)\b[wlht]\b") Then Return True
	Return False
EndFunc   ;==>Zones_FormulaHasVariable

; Formate une valeur pour l'affichage dans une formule traduite : 2 décimales
; maximum, sans zéros inutiles (même règle que UI_FmtMm, dupliquée ici pour ne
; pas faire dépendre ce module métier de l'UI — cf. règle de niveaux en tête).
Func _Zones_FmtToken($fValue)
	Local $s = StringFormat("%.2f", $fValue)
	$s = StringRegExpReplace($s, "0+$", "")
	Return StringRegExpReplace($s, "\.$", "")
EndFunc   ;==>_Zones_FmtToken

; -----------------------------------------------------------------------------
; Traduit une formule en substituant ses jetons par leurs valeurs COURANTES,
; formatées lisiblement (pas d'évaluation arithmétique : les opérateurs restent
; en clair) — utilisé par l'UI pour l'aperçu affiché pendant la saisie
; ("s1.pos + 20" → "120 + 20"). Retourne True et pose $sOut, ou False si une
; référence est introuvable.
; -----------------------------------------------------------------------------
Func Zones_FormulaTranslate($sFormula, ByRef $sOut)
	Local $aIds[0]
	_Zones_FormulaRefs($sFormula, $aIds)
	Local $sExpr = $sFormula
	For $i = 0 To UBound($aIds) - 1
		Local $iRow = Project_SepFindById($aIds[$i])
		If $iRow = -1 Then Return False
		$sExpr = StringRegExpReplace($sExpr, "(?i)s" & $aIds[$i] & "\.pos", _
				_Zones_FmtToken(Project_SepGet($iRow, $SEP_POS)))
	Next

	Local $fT = $g_aPrjBox[$BOX_THICKNESS]
	Local $sW = _Zones_FmtToken($g_aPrjBox[$BOX_WIDTH] - 2 * $fT)
	Local $sL = _Zones_FmtToken($g_aPrjBox[$BOX_LENGTH] - 2 * $fT)
	Local $sH = _Zones_FmtToken($g_aPrjBox[$BOX_HEIGHT] - $fT)
	Local $sT = _Zones_FmtToken($fT)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bb\.w\b", $sW)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bb\.l\b", $sL)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bb\.h\b", $sH)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bb\.t\b", $sT)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bw\b", $sW)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bl\b", $sL)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bh\b", $sH)
	$sExpr = StringRegExpReplace($sExpr, "(?i)\bt\b", $sT)

	$sOut = $sExpr
	Return True
EndFunc   ;==>Zones_FormulaTranslate

; Évalue une formule SANS rien modifier au modèle (aperçu de saisie) : simple
; enveloppe publique de l'évaluateur privé, pour l'UI (Input.au3).
Func Zones_FormulaPreviewEval($sFormula, ByRef $fOut)
	Return _Zones_FormulaEval($sFormula, $fOut)
EndFunc   ;==>Zones_FormulaPreviewEval

; -----------------------------------------------------------------------------
; Pose (ou efface : "") la formule de position d'un séparateur — et de tous
; les segments de son groupe —, puis propage. Retourne "" ou le message
; d'erreur de validation (dans ce cas rien n'est modifié).
; -----------------------------------------------------------------------------
Func Metier_SetSeparatorFormula($iId, $sFormula)
	Local $iRow = Project_SepFindById($iId)
	If $iRow = -1 Then Return "Séparateur introuvable."

	Local $sErr = Metier_FormulaValidate($sFormula, $iId)
	If $sErr <> "" Then Return $sErr

	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)
	For $i = 0 To Project_SepCount() - 1
		If $i = $iRow Or ($iGroup <> $SEP_NO_GROUP And Project_SepGet($i, $SEP_GROUP) = $iGroup) Then
			Project_SepSet($i, $SEP_FORMULA, $sFormula)
		EndIf
	Next

	Metier_ApplyFormulas()
	Return ""
EndFunc   ;==>Metier_SetSeparatorFormula

; -----------------------------------------------------------------------------
; Propagation : évalue toutes les formules en ordre de dépendances, et
; RÉPÈTE jusqu'à stabilisation. La répétition est nécessaire quand des
; séparateurs se bornent mutuellement pendant le mouvement : chaque passe
; les rapproche de leur cible (celui qui bloque s'écarte à la passe
; suivante), jusqu'au point fixe.
; Chaque application passe par la primitive de déplacement clampé : une
; formule ne peut JAMAIS violer les contraintes (écart 10 mm, sous-zone).
; Les formules inévaluables et les cycles résiduels laissent la position
; en l'état.
; -----------------------------------------------------------------------------
Func Metier_ApplyFormulas()
	For $iPass = 1 To 100 ; garde-fou (chaînes pathologiques)
		If Not _Metier_ApplyFormulasPass() Then ExitLoop
	Next
EndFunc   ;==>Metier_ApplyFormulas

; Une passe complète d'évaluation. Retourne True si au moins une position
; a effectivement changé (une passe supplémentaire est alors utile).
Func _Metier_ApplyFormulasPass()
	Local $iCount = Project_SepCount()
	If $iCount = 0 Then Return False
	Local $bChanged = False
	Local $aResolved[$iCount]

	; Résolus d'office : les séparateurs à position libre.
	For $i = 0 To $iCount - 1
		$aResolved[$i] = (Project_SepGet($i, $SEP_FORMULA) = "")
	Next

	; Passes successives jusqu'à stabilité (ordre topologique implicite).
	Local $bProgress = True
	While $bProgress
		$bProgress = False
		For $i = 0 To $iCount - 1
			If $aResolved[$i] Then ContinueLoop

			; Toutes les références sont-elles résolues ?
			Local $aIds[0]
			_Zones_FormulaRefs(Project_SepGet($i, $SEP_FORMULA), $aIds)
			Local $bReady = True
			For $j = 0 To UBound($aIds) - 1
				Local $iRefRow = Project_SepFindById($aIds[$j])
				If $iRefRow = -1 Then ContinueLoop ; référence morte : évaluation échouera proprement
				If Not $aResolved[$iRefRow] Then
					$bReady = False
					ExitLoop
				EndIf
			Next
			If Not $bReady Then ContinueLoop

			; Évaluation puis déplacement clampé (le groupe entier suit).
			Local $fTarget
			If _Zones_FormulaEval(Project_SepGet($i, $SEP_FORMULA), $fTarget) Then
				If _Metier_MoveOne(Project_SepGet($i, $SEP_ID), $fTarget) Then $bChanged = True
			EndIf

			; Le segment et ses co-membres de groupe sont stabilisés.
			Local $iGroup = Project_SepGet($i, $SEP_GROUP)
			For $j = 0 To $iCount - 1
				If $j = $i Or ($iGroup <> $SEP_NO_GROUP And Project_SepGet($j, $SEP_GROUP) = $iGroup) Then
					$aResolved[$j] = True
				EndIf
			Next
			$bProgress = True
		Next
	WEnd
	Return $bChanged
EndFunc   ;==>_Metier_ApplyFormulasPass

; -----------------------------------------------------------------------------
; Suppression métier : un séparateur groupé emporte TOUT son groupe (les
; segments liés se comportent comme un seul objet).
; Retourne le nombre de segments supprimés.
; -----------------------------------------------------------------------------
Func Metier_DeleteSeparator($iId)
	Local $iRow = Project_SepFindById($iId)
	If $iRow = -1 Then Return 0

	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)
	Local $iDeleted = 0

	If $iGroup = $SEP_NO_GROUP Then
		Project_SepDeleteRow($iRow)
		$iDeleted = 1
	Else
		; Parcours à rebours : les index restent valides pendant la purge.
		For $i = Project_SepCount() - 1 To 0 Step -1
			If Project_SepGet($i, $SEP_GROUP) = $iGroup Then
				Project_SepDeleteRow($i)
				$iDeleted += 1
			EndIf
		Next
	EndIf

	Zones_Rebuild()
	Return $iDeleted
EndFunc   ;==>Metier_DeleteSeparator

; --- Bords de la boîte (drag de redimensionnement) ------------------------------
; Noms en coordonnées MONDE : N = bord extérieur Y minimal (y=−t au repos),
; S = bord Y maximal, W = bord X minimal, E = bord X maximal. (À l'écran,
; l'axe Y étant inversé, le bord N apparaît en bas.)
Global Const $METIER_EDGE_W = 0
Global Const $METIER_EDGE_E = 1
Global Const $METIER_EDGE_N = 2
Global Const $METIER_EDGE_S = 3

; -----------------------------------------------------------------------------
; Redimensionne la boîte en amenant le bord $iEdge à la coordonnée monde
; $fWorldPos (arrondie au centième). Le bord OPPOSÉ reste fixe :
;   - bords E/S : la dimension change, l'origine ne bouge pas ;
;   - bords O/N : l'ORIGINE suit le curseur (coordonnées négatives permises
;     pendant la manipulation) — les séparateurs, en coordonnées monde,
;     restent naturellement solidaires du bord fixe.
; Le recalage en (0,0) n'a lieu qu'au relâchement (Metier_EndBoxResize).
; Retourne True si quelque chose a effectivement changé.
; -----------------------------------------------------------------------------
Func Metier_ResizeBoxEdge($iEdge, $fWorldPos)
	$fWorldPos = Round($fWorldPos, 2)
	; Dimension minimale : les deux parois + une sous-zone exploitable.
	Local $fMinDim = 2 * $g_aPrjBox[$BOX_THICKNESS] + 2 * $ZONES_MIN_GAP
	Local $fT = $g_aPrjBox[$BOX_THICKNESS]
	Local $fOx1, $fOy1, $fOx2, $fOy2 ; les bords dragués sont les bords EXTÉRIEURS
	Project_BoxOuter($fOx1, $fOy1, $fOx2, $fOy2)

	Local $bChanged = False
	Switch $iEdge
		Case $METIER_EDGE_E
			Local $fNewW = Round(_Zones_Clamp($fWorldPos - $fOx1, $fMinDim, 1e9), 2)
			If Abs($fNewW - $g_aPrjBox[$BOX_WIDTH]) > $ZONES_EPS Then $bChanged = Project_BoxSet($BOX_WIDTH, $fNewW)

		Case $METIER_EDGE_S
			Local $fNewL = Round(_Zones_Clamp($fWorldPos - $fOy1, $fMinDim, 1e9), 2)
			If Abs($fNewL - $g_aPrjBox[$BOX_LENGTH]) > $ZONES_EPS Then $bChanged = Project_BoxSet($BOX_LENGTH, $fNewL)

		Case $METIER_EDGE_W
			; Bord fixe : $fOx2. L'origine (coin intérieur) suit le bord dragué.
			Local $fNewOx1 = Round(_Zones_Clamp($fWorldPos, -1e9, $fOx2 - $fMinDim), 2)
			If Abs($fNewOx1 - $fOx1) > $ZONES_EPS And Project_BoxSet($BOX_WIDTH, Round($fOx2 - $fNewOx1, 2)) Then
				Project_BoxSetOrg(Round($fNewOx1 + $fT, 2), Project_BoxOrgY())
				$bChanged = True
			EndIf

		Case $METIER_EDGE_N
			; Bord fixe : $fOy2. L'origine (coin intérieur) suit le bord dragué.
			Local $fNewOy1 = Round(_Zones_Clamp($fWorldPos, -1e9, $fOy2 - $fMinDim), 2)
			If Abs($fNewOy1 - $fOy1) > $ZONES_EPS And Project_BoxSet($BOX_LENGTH, Round($fOy2 - $fNewOy1, 2)) Then
				Project_BoxSetOrg(Project_BoxOrgX(), Round($fNewOy1 + $fT, 2))
				$bChanged = True
			EndIf
	EndSwitch

	If $bChanged Then Metier_OnBoxChanged() ; clamp des séparateurs + dérivées
	Return $bChanged
EndFunc   ;==>Metier_ResizeBoxEdge

; -----------------------------------------------------------------------------
; Fin d'un drag de bord : recale la boîte en (0,0). Tout le contenu (monde)
; est décalé du même delta — visuellement rien ne bouge si l'appelant décale
; aussi la caméra de ($fShiftX, $fShiftY) : c'est la grille qui se recale.
; Retourne True si un recalage a eu lieu.
; -----------------------------------------------------------------------------
Func Metier_EndBoxResize(ByRef $fShiftX, ByRef $fShiftY)
	$fShiftX = -Project_BoxOrgX()
	$fShiftY = -Project_BoxOrgY()
	If Abs($fShiftX) <= $ZONES_EPS And Abs($fShiftY) <= $ZONES_EPS Then
		$fShiftX = 0
		$fShiftY = 0
		Return False
	EndIf

	For $i = 0 To Project_SepCount() - 1
		; Pour un vertical : Pos = X, Anchor = Y ; pour un horizontal l'inverse.
		Local $bVert = (Project_SepGet($i, $SEP_ORIENT) = $SEP_ORIENT_V)
		Local $iFieldX = $bVert ? $SEP_POS : $SEP_ANCHOR
		Local $iFieldY = $bVert ? $SEP_ANCHOR : $SEP_POS
		Project_SepSet($i, $iFieldX, Round(Project_SepGet($i, $iFieldX) + $fShiftX, 2))
		Project_SepSet($i, $iFieldY, Round(Project_SepGet($i, $iFieldY) + $fShiftY, 2))
	Next
	Project_BoxSetOrg(0, 0)

	Metier_OnBoxChanged()
	Return True
EndFunc   ;==>Metier_EndBoxResize

; -----------------------------------------------------------------------------
; Après un changement de dimensions de la boîte : ramène chaque séparateur
; dans le nouvel intérieur (position ET ancre), puis recalcule les dérivées.
; Un redimensionnement est une refonte globale : les séparateurs conservent
; leur position absolue quand c'est possible, sinon ils sont clampés.
; -----------------------------------------------------------------------------
Func Metier_OnBoxChanged()
	Local $fIx1, $fIy1, $fIx2, $fIy2
	Project_BoxInterior($fIx1, $fIy1, $fIx2, $fIy2)

	For $i = 0 To Project_SepCount() - 1
		If Project_SepGet($i, $SEP_ORIENT) = $SEP_ORIENT_V Then
			Project_SepSet($i, $SEP_POS, _Zones_Clamp(Project_SepGet($i, $SEP_POS), _
					$fIx1 + $ZONES_MIN_GAP, $fIx2 - $ZONES_MIN_GAP))
			Project_SepSet($i, $SEP_ANCHOR, _Zones_Clamp(Project_SepGet($i, $SEP_ANCHOR), _
					$fIy1 + $ZONES_EPS * 2, $fIy2 - $ZONES_EPS * 2))
		Else
			Project_SepSet($i, $SEP_POS, _Zones_Clamp(Project_SepGet($i, $SEP_POS), _
					$fIy1 + $ZONES_MIN_GAP, $fIy2 - $ZONES_MIN_GAP))
			Project_SepSet($i, $SEP_ANCHOR, _Zones_Clamp(Project_SepGet($i, $SEP_ANCHOR), _
					$fIx1 + $ZONES_EPS * 2, $fIx2 - $ZONES_EPS * 2))
		EndIf
	Next

	Zones_Rebuild()
	Metier_ApplyFormulas() ; les positions ont pu être clampées/décalées
EndFunc   ;==>Metier_OnBoxChanged
