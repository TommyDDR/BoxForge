#include-once
; =============================================================================
; App.au3 — État applicatif transversal et constantes de l'application.
;
; Niveau : transversal (aucune dépendance GDI+, aucune dépendance UI).
; Ce module ne doit JAMAIS inclure un autre module du projet : tout le monde
; peut l'inclure sans risque de dépendance circulaire.
; =============================================================================

Global Const $APP_NAME    = "BoxForge"
Global Const $APP_VERSION = "0.9.0"

; -----------------------------------------------------------------------------
; Drapeau "la vue doit être recomposée" (dirty flag).
;
; Règle : toute mutation visible (caméra, modèle, sélection, redimensionnement)
; appelle App_InvalidateView(). La boucle principale consomme le drapeau et ne
; redessine QUE dans ce cas : le coût par frame est proportionnel à ce qui
; change, pas à ce qui est affiché (cf. pratiques-rendu-performant.md §7).
; -----------------------------------------------------------------------------
Global $g_bAppViewDirty = True

; Marque la vue comme obsolète : un rendu sera effectué au prochain tour de boucle.
Func App_InvalidateView()
	$g_bAppViewDirty = True
EndFunc   ;==>App_InvalidateView

; Retourne True si un rendu est nécessaire, et réarme le drapeau.
Func App_ConsumeViewDirty()
	If Not $g_bAppViewDirty Then Return False
	$g_bAppViewDirty = False
	Return True
EndFunc   ;==>App_ConsumeViewDirty

; -----------------------------------------------------------------------------
; Drapeau "le projet comporte des modifications non enregistrées".
; Posé par l'UI après chaque mutation du modèle (même règle que le dirty de
; vue : le métier ignore la persistance), consommé par Enregistrer/Ouvrir/
; Nouveau/Quitter pour la confirmation et l'astérisque du titre.
; -----------------------------------------------------------------------------
Global $g_bAppProjectModified = False

; Change l'état "modifié". Retourne True si l'état a effectivement changé
; (l'appelant ne met à jour le titre de la fenêtre que dans ce cas).
Func App_SetProjectModified($bModified)
	If $g_bAppProjectModified = $bModified Then Return False
	$g_bAppProjectModified = $bModified
	Return True
EndFunc   ;==>App_SetProjectModified

Func App_IsProjectModified()
	Return $g_bAppProjectModified
EndFunc   ;==>App_IsProjectModified
