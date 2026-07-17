#include-once
#include "Project.au3"
#include "Zones.au3"

; =============================================================================
; ProjectIO.au3 — Sauvegarde / chargement du projet (niveau 5 : persistance).
;
; Ne dépend QUE des données métier (Project/Zones) : jamais du renderer,
; jamais de l'UI. Les dialogues de fichiers restent côté UI ; ce module ne
; reçoit que des chemins.
;
; Format : fichier texte .bfp à sections, compatible IniRead (lisible, diffable,
; versionné). Seules les DONNÉES SOURCES sont sauvegardées : les dérivées
; (sous-zones, portées, intersections) sont recalculées au chargement par
; Zones_Rebuild — le chargement recrée ainsi exactement le projet.
;
;   [BoxForge]
;   Version=1
;   [Box]
;   Width=400 … (un champ par ligne)
;   [Layers]
;   L00=RRGGBB|épaisseur|hauteur|créneau long.|créneau espac.
;   [Separators]
;   Count=n / NextId / NextGroup
;   S0=id|groupe|orientation|position|ancre|layer
;
; Chargement défensif : tout est analysé et validé dans des tampons locaux ;
; le projet courant n'est remplacé que si le fichier ENTIER est valide.
; =============================================================================

Global Const $IO_FILE_VERSION = 1
Global Const $IO_FILE_EXT     = "bfp"

; Chemin du projet courant ("" = jamais enregistré).
Global $g_sIoProjectPath = ""

Func ProjectIO_GetPath()
	Return $g_sIoProjectPath
EndFunc   ;==>ProjectIO_GetPath

Func ProjectIO_SetPath($sPath)
	$g_sIoProjectPath = $sPath
EndFunc   ;==>ProjectIO_SetPath

; Nom de fichier du projet pour le titre de la fenêtre.
Func ProjectIO_GetDisplayName()
	If $g_sIoProjectPath = "" Then Return "sans titre"
	Return StringRegExpReplace($g_sIoProjectPath, "^.*\\", "")
EndFunc   ;==>ProjectIO_GetDisplayName

; =============================================================================
; SAUVEGARDE
; =============================================================================

; -----------------------------------------------------------------------------
; Écrit le projet complet dans $sPath. Retourne True si le fichier est écrit.
; Le contenu est construit en mémoire puis écrit en UNE passe (pas de fichier
; à moitié écrit si une section échoue).
; -----------------------------------------------------------------------------
Func ProjectIO_SaveTo($sPath)
	Local $s = "[BoxForge]" & @CRLF
	$s &= "Version=" & $IO_FILE_VERSION & @CRLF

	; --- Boîte ---
	$s &= "[Box]" & @CRLF
	$s &= "Width=" & Project_BoxGet($BOX_WIDTH) & @CRLF
	$s &= "Length=" & Project_BoxGet($BOX_LENGTH) & @CRLF
	$s &= "Height=" & Project_BoxGet($BOX_HEIGHT) & @CRLF
	$s &= "Thickness=" & Project_BoxGet($BOX_THICKNESS) & @CRLF
	$s &= "FingerLen=" & Project_BoxGet($BOX_FINGER_LEN) & @CRLF
	$s &= "FingerSpacing=" & Project_BoxGet($BOX_FINGER_SPACING) & @CRLF

	; --- Layers (couleur en hexadécimal, dimensions en clair) ---
	$s &= "[Layers]" & @CRLF
	For $i = 0 To $LAYERS_COUNT - 1
		$s &= StringFormat("L%02d=", $i) & Hex(Project_LayerGet($i, $LAYER_COLOR), 6) _
				 & "|" & Project_LayerGet($i, $LAYER_THICKNESS) _
				 & "|" & Project_LayerGet($i, $LAYER_HEIGHT) _
				 & "|" & Project_LayerGet($i, $LAYER_FINGER_LEN) _
				 & "|" & Project_LayerGet($i, $LAYER_FINGER_SPACING) & @CRLF
	Next

	; --- Séparateurs (données sources uniquement : les portées sont dérivées) ---
	$s &= "[Separators]" & @CRLF
	$s &= "Count=" & Project_SepCount() & @CRLF
	$s &= "NextId=" & $g_iPrjSepNextId & @CRLF
	$s &= "NextGroup=" & $g_iPrjSepNextGroup & @CRLF
	For $i = 0 To Project_SepCount() - 1
		; La formule est en dernière position ; ses caractères autorisés
		; excluent "|" et les sauts de ligne (validée à la saisie).
		$s &= "S" & $i & "=" & Project_SepGet($i, $SEP_ID) _
				 & "|" & Project_SepGet($i, $SEP_GROUP) _
				 & "|" & Project_SepGet($i, $SEP_ORIENT) _
				 & "|" & Project_SepGet($i, $SEP_POS) _
				 & "|" & Project_SepGet($i, $SEP_ANCHOR) _
				 & "|" & Project_SepGet($i, $SEP_LAYER) _
				 & "|" & Project_SepGet($i, $SEP_FORMULA) & @CRLF
	Next

	Local $hFile = FileOpen($sPath, 2) ; écrasement
	If $hFile = -1 Then Return False
	FileWrite($hFile, $s)
	FileClose($hFile)

	$g_sIoProjectPath = $sPath
	Return True
EndFunc   ;==>ProjectIO_SaveTo

; =============================================================================
; CHARGEMENT
; =============================================================================

; Lit une valeur numérique strictement positive. Pose @error si invalide.
Func _ProjectIO_ReadPositive($sPath, $sSection, $sKey)
	Local $sValue = IniRead($sPath, $sSection, $sKey, "")
	Local $fValue = Number($sValue)
	If $sValue = "" Or $fValue <= 0 Then Return SetError(1, 0, 0)
	Return $fValue
EndFunc   ;==>_ProjectIO_ReadPositive

; -----------------------------------------------------------------------------
; Charge le projet depuis $sPath. Retourne True si le projet a été remplacé.
; En cas de fichier invalide, le projet courant reste INTACT.
; -----------------------------------------------------------------------------
Func ProjectIO_LoadFrom($sPath)
	If IniRead($sPath, "BoxForge", "Version", "") <> String($IO_FILE_VERSION) Then Return False

	; --- Boîte → tampon local ---
	Local $aBox[$BOX_FIELD_COUNT]
	Local $aBoxKeys[$BOX_FIELD_COUNT]
	$aBoxKeys[$BOX_WIDTH] = "Width"
	$aBoxKeys[$BOX_LENGTH] = "Length"
	$aBoxKeys[$BOX_HEIGHT] = "Height"
	$aBoxKeys[$BOX_THICKNESS] = "Thickness"
	$aBoxKeys[$BOX_FINGER_LEN] = "FingerLen"
	$aBoxKeys[$BOX_FINGER_SPACING] = "FingerSpacing"
	For $i = 0 To $BOX_FIELD_COUNT - 1
		$aBox[$i] = _ProjectIO_ReadPositive($sPath, "Box", $aBoxKeys[$i])
		If @error Then Return False
	Next
	; Cohérence minimale : un intérieur non vide doit exister.
	Local $fMinDim = ($aBox[$BOX_WIDTH] < $aBox[$BOX_LENGTH]) ? $aBox[$BOX_WIDTH] : $aBox[$BOX_LENGTH]
	If $aBox[$BOX_THICKNESS] * 2 >= $fMinDim Then Return False

	; --- Layers → tampon local ---
	Local $aLayers[$LAYERS_COUNT][$LAYER_FIELD_COUNT]
	For $i = 0 To $LAYERS_COUNT - 1
		Local $aParts = StringSplit(IniRead($sPath, "Layers", StringFormat("L%02d", $i), ""), "|")
		If $aParts[0] <> $LAYER_FIELD_COUNT Then Return False
		If Not StringRegExp($aParts[1], "^[0-9A-Fa-f]{6}$") Then Return False
		$aLayers[$i][$LAYER_COLOR] = Dec($aParts[1])
		$aLayers[$i][$LAYER_THICKNESS] = Number($aParts[2])
		$aLayers[$i][$LAYER_HEIGHT] = Number($aParts[3])
		$aLayers[$i][$LAYER_FINGER_LEN] = Number($aParts[4])
		$aLayers[$i][$LAYER_FINGER_SPACING] = Number($aParts[5])
		For $j = 1 To $LAYER_FIELD_COUNT - 1 ; toute dimension d'usinage > 0
			If $aLayers[$i][$j] <= 0 Then Return False
		Next
	Next

	; --- Séparateurs → tampon local ---
	Local $iCount = Number(IniRead($sPath, "Separators", "Count", "-1"))
	If $iCount < 0 Then Return False
	Local $aSeps[$iCount][$SEP_FIELD_COUNT]
	Local $iMaxId = 0, $iMaxGroup = 0
	For $i = 0 To $iCount - 1
		$aParts = StringSplit(IniRead($sPath, "Separators", "S" & $i, ""), "|")
		; 6 parts : ancien format (sans formule) ; 7 : format courant.
		If $aParts[0] <> 6 And $aParts[0] <> 7 Then Return False

		Local $iId = Int(Number($aParts[1]))
		Local $iGroup = Int(Number($aParts[2]))
		Local $iOrient = Int(Number($aParts[3]))
		Local $iLayer = Int(Number($aParts[6]))
		If $iId <= 0 Or $iGroup < 0 Then Return False
		If $iOrient <> $SEP_ORIENT_V And $iOrient <> $SEP_ORIENT_H Then Return False
		If $iLayer < 0 Or $iLayer >= $LAYERS_COUNT Then Return False

		$aSeps[$i][$SEP_ID] = $iId
		$aSeps[$i][$SEP_GROUP] = $iGroup
		$aSeps[$i][$SEP_ORIENT] = $iOrient
		$aSeps[$i][$SEP_POS] = Number($aParts[4])
		$aSeps[$i][$SEP_ANCHOR] = Number($aParts[5])
		$aSeps[$i][$SEP_LAYER] = $iLayer
		$aSeps[$i][$SEP_SPAN1] = 0 ; dérivé : recalculé par Zones_Rebuild
		$aSeps[$i][$SEP_SPAN2] = 0
		; Formule : uniquement si ses caractères sont sûrs (défense en
		; profondeur avant toute évaluation), sinon position libre.
		$aSeps[$i][$SEP_FORMULA] = ""
		If $aParts[0] = 7 Then
			If Not StringRegExp(Zones_FormulaStripTokens($aParts[7]), "[^0-9\.\s\+\-\*\/\(\)]") Then _
					$aSeps[$i][$SEP_FORMULA] = $aParts[7]
		EndIf

		If $iId > $iMaxId Then $iMaxId = $iId
		If $iGroup > $iMaxGroup Then $iMaxGroup = $iGroup
	Next

	; --- Tout est valide : remplacement du projet courant ---
	$g_aPrjBox = $aBox
	$g_aPrjLayers = $aLayers
	Project_BoxSetOrg(0, 0) ; l'origine n'est jamais persistée (invariant)
	Project_SepReset()
	ReDim $g_aPrjSeps[$iCount][$SEP_FIELD_COUNT]
	For $i = 0 To $iCount - 1
		For $j = 0 To $SEP_FIELD_COUNT - 1
			$g_aPrjSeps[$i][$j] = $aSeps[$i][$j]
		Next
	Next

	; Compteurs : valeurs du fichier, bornées par le contenu réel (robustesse
	; face à un fichier édité à la main).
	$g_iPrjSepNextId = Int(Number(IniRead($sPath, "Separators", "NextId", "0")))
	If $g_iPrjSepNextId <= $iMaxId Then $g_iPrjSepNextId = $iMaxId + 1
	$g_iPrjSepNextGroup = Int(Number(IniRead($sPath, "Separators", "NextGroup", "0")))
	If $g_iPrjSepNextGroup <= $iMaxGroup Then $g_iPrjSepNextGroup = $iMaxGroup + 1

	; Recalcul des données dérivées : recrée exactement l'état du projet.
	; Les positions sauvegardées satisfont déjà les formules ; la propagation
	; est relancée par sécurité (fichier édité à la main, anciennes versions).
	Zones_Rebuild()
	Metier_ApplyFormulas()

	$g_sIoProjectPath = $sPath
	Return True
EndFunc   ;==>ProjectIO_LoadFrom
