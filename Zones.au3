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
Global Const $ZONES_MOVE_STEP_MM = 5.0    ; pas maximal d'un déplacement métier (mm)

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
	; Sous-zone initiale : l'intérieur complet de la boîte.
	ReDim $g_aZones[1][$ZONE_FIELD_COUNT]
	$g_aZones[0][$ZONE_X1] = Box_InteriorX($g_aPrjBox)
	$g_aZones[0][$ZONE_Y1] = Box_InteriorY($g_aPrjBox)
	$g_aZones[0][$ZONE_X2] = Box_InteriorX($g_aPrjBox) + Box_InteriorW($g_aPrjBox)
	$g_aZones[0][$ZONE_Y2] = Box_InteriorY($g_aPrjBox) + Box_InteriorH($g_aPrjBox)

	; Réapplique chaque découpe dans l'ordre de création.
	For $iRow = 0 To Project_SepCount() - 1
		_Zones_ApplySplit($iRow)
	Next

	Zones_RebuildIntersections()
EndFunc   ;==>Zones_Rebuild

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
	If $iOrient = $SEP_ORIENT_V Then
		$fMin = Box_InteriorX($g_aPrjBox)
		$fMax = $fMin + Box_InteriorW($g_aPrjBox)
	Else
		$fMin = Box_InteriorY($g_aPrjBox)
		$fMax = $fMin + Box_InteriorH($g_aPrjBox)
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
	$fPos = _Zones_Clamp($fPos, $fLo + $ZONES_MIN_GAP, $fHi - $ZONES_MIN_GAP)

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
Func _Zones_SetGroupPos($iRow, $fPos)
	Local $iGroup = Project_SepGet($iRow, $SEP_GROUP)
	Project_SepSet($iRow, $SEP_POS, $fPos)
	If $iGroup = $SEP_NO_GROUP Then Return
	For $i = 0 To Project_SepCount() - 1
		If Project_SepGet($i, $SEP_GROUP) = $iGroup Then Project_SepSet($i, $SEP_POS, $fPos)
	Next
EndFunc   ;==>_Zones_SetGroupPos

; -----------------------------------------------------------------------------
; Déplacement métier d'un séparateur (par identifiant) vers $fTarget (mm).
; - Clampé en continu dans la plage autorisée (sous-zone + marge 10 mm) ;
; - groupe-aware : tous les segments liés bougent d'un bloc ;
; - AVANCE PAR PETITS PAS avec recalcul des sous-zones à chaque pas : la
;   topologie évolue continûment (les portées des séparateurs perpendiculaires
;   s'ajustent au fur et à mesure), même pour une grande distance demandée
;   d'un coup (saisie directe d'une position dans le panneau Propriétés).
; Retourne True si la position a effectivement changé.
; -----------------------------------------------------------------------------
Func Metier_MoveSeparator($iId, $fTarget)
	Local $iRow = Project_SepFindById($iId)
	If $iRow = -1 Then Return False

	Local $bMoved = False
	For $iGuard = 1 To 400 ; garde-fou : 400 pas × 5 mm = 2 m de course maxi
		Local $fMin, $fMax
		Zones_GetMoveRange($iRow, $fMin, $fMax)
		If $fMin > $fMax Then ExitLoop ; aucun jeu disponible

		Local $fPos = Project_SepGet($iRow, $SEP_POS)
		Local $fDelta = _Zones_Clamp($fTarget, $fMin, $fMax) - $fPos
		If Abs($fDelta) <= $ZONES_EPS Then ExitLoop

		If $fDelta > $ZONES_MOVE_STEP_MM Then $fDelta = $ZONES_MOVE_STEP_MM
		If $fDelta < -$ZONES_MOVE_STEP_MM Then $fDelta = -$ZONES_MOVE_STEP_MM

		_Zones_SetGroupPos($iRow, $fPos + $fDelta)
		Zones_Rebuild()
		$bMoved = True
	Next
	Return $bMoved
EndFunc   ;==>Metier_MoveSeparator

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

; -----------------------------------------------------------------------------
; Après un changement de dimensions de la boîte : ramène chaque séparateur
; dans le nouvel intérieur (position ET ancre), puis recalcule les dérivées.
; Un redimensionnement est une refonte globale : les séparateurs conservent
; leur position absolue quand c'est possible, sinon ils sont clampés.
; -----------------------------------------------------------------------------
Func Metier_OnBoxChanged()
	Local $fIx1 = Box_InteriorX($g_aPrjBox)
	Local $fIy1 = Box_InteriorY($g_aPrjBox)
	Local $fIx2 = $fIx1 + Box_InteriorW($g_aPrjBox)
	Local $fIy2 = $fIy1 + Box_InteriorH($g_aPrjBox)

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
EndFunc   ;==>Metier_OnBoxChanged
