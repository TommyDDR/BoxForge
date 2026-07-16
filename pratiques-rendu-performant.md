# Pratiques de rendu 2D performant (AutoIt + GDI+ / GDI)

Synthèse de tout ce qui a été mis en place dans TeacherStory pour obtenir un rendu
fluide, sans scintillement, à plusieurs centaines de FPS en pur CPU (AutoIt + GDI+).
Objectif : servir de base pour démarrer un nouveau projet directement avec la bonne
architecture, sans repayer l'apprentissage.

Les ordres de grandeur cités ont été mesurés sur la machine de dev du projet
(profiler intégré) ; ils restent de bons repères relatifs sur n'importe quel PC.

---

## 1. Architecture générale : la chaîne de buffers

Principe : **on ne dessine JAMAIS directement dans la fenêtre pendant la frame.**
Tout est composé offscreen, puis présenté en un seul blit. C'est ça (et le
paragraphe anti-scintillement §2) qui garantit zéro flicker.

```
assets PNG (convertis PARGB au chargement)
        │
        ▼
caches de couches (scène statique, mobilier, HUD, UI…)   ← reconstruits rarement
        │
        ▼
backbuffer logique = DIB section 32bpp dans un memory DC ← composé chaque frame
        │  (GDI+ Graphics créé sur ce DC)
        ▼
Render_Present() : un seul StretchBlt memDC → DC fenêtre (SRCCOPY)
```

### Création des cibles (au démarrage)

```autoit
$hPresentDC = _WinAPI_GetDC($hGui)
$hMemDC     = _WinAPI_CreateCompatibleDC($hPresentDC)
; DIB section 32bpp au lieu d'un DDB : GDI+ dessine directement en mémoire
; sans conversion de format, et StretchBlt reste rapide.
$hLogicalBitmap = _WinAPI_CreateDIB($iLogicalWidth, $iLogicalHeight)
_WinAPI_SelectObject($hMemDC, $hLogicalBitmap)
$hLogicalGfx = _GDIPlus_GraphicsCreateFromHDC($hMemDC)
_WinAPI_SetStretchBltMode($hPresentDC, $COLORONCOLOR)
```

Points clés :
- **DIB section 32bpp** (pas un DDB, pas un bitmap GDI+ pur) : GDI+ écrit
  directement les pixels, et le blit GDI vers l'écran reste un memcpy.
- Le `Graphics` GDI+ est créé **sur le memory DC** : même surface pour la
  composition GDI+ et la présentation GDI, zéro copie intermédiaire.
- `SetStretchBltMode(COLORONCOLOR)` : pas de dithering/halftone au scale final
  (essentiel en pixel art, et plus rapide).

### Présentation (chaque frame, en dernier)

```autoit
Func Render_Present()
    _WinAPI_StretchBlt($hPresentDC, 0, 0, $iWindowWidth, $iWindowHeight, _
            $hMemDC, 0, 0, $iLogicalWidth, $iLogicalHeight, $SRCCOPY)
EndFunc
```

Un seul appel, plein écran, SRCCOPY. Coût mesuré ≈ 0,14 ms en résolution
logique ~936×518. C'est aussi ici que se fait l'upscale résolution logique →
taille de fenêtre.

---

## 2. Anti-scintillement (les deux gestes indispensables)

1. **Intercepter `WM_ERASEBKGND` et renvoyer 1** — sinon Windows efface le fond
   de la fenêtre avant chaque repaint et on voit clignoter :

```autoit
GUIRegisterMsg($WM_ERASEBKGND, Game_WMEraseBkgnd)

Func Game_WMEraseBkgnd($hWnd, $iMsg, $wParam, $lParam)
    Return 1 ; "déjà effacé" : on repeint tout nous-mêmes
EndFunc
```

2. **Un seul blit de présentation par frame** (cf. §1). Jamais deux dessins
   successifs visibles à l'écran : tout ce qui doit se superposer se superpose
   dans le backbuffer.

Avec ces deux points, pas besoin de `WS_EX_COMPOSITED` ni d'astuces exotiques.

---

## 3. Réglages GDI+ systématiques (sur CHAQUE Graphics créé)

À appliquer sur le backbuffer ET sur chaque graphics de cache. Un graphics GDI+
fraîchement créé est en mode "qualité" lent ; pour du pixel art on veut :

```autoit
_GDIPlus_GraphicsSetInterpolationMode($hGfx, 5)  ; NearestNeighbor (pixel art net)
_GDIPlus_GraphicsSetPixelOffsetMode($hGfx, 2)    ; Half : aligne les pixels, pas de bavure d'1/2px
_GDIPlus_GraphicsSetSmoothingMode($hGfx, 0)      ; pas d'antialiasing des formes
_GDIPlus_GraphicsSetTextRenderingHint($hGfx, $TEXT_RENDER_HINT) ; hint texte constant partout
```

Faire un helper ou copier ce bloc **à chaque création de graphics**, sinon un
cache reconstruit "oublie" les modes et devient flou ET lent.

Exception ponctuelle : repasser `SmoothingMode` à 2 (antialias) le temps de
dessiner une forme vectorielle ronde (jauges, pastilles), puis **le remettre à 0**.

---

## 4. Formats de pixel : tout en 32bpp PARGB (prémultiplié)

**Le piège n°1 de GDI+ :** un bitmap `32bppARGB` (non prémultiplié) est
**~3× plus lent au DrawImage** qu'un `32bppPARGB`, car GDI+ prémultiplie chaque
pixel à chaque dessin.

- **Conversion au chargement** de tous les assets :

```autoit
Func Render_LoadImage($sPath)
    Local $hImage = _GDIPlus_ImageLoadFromFile($sFullPath)
    ; PNG chargé = ARGB. On clone en PARGB une fois pour toutes.
    Local $hPremultiplied = _GDIPlus_BitmapCloneArea($hImage, 0, 0, $iW, $iH, $GDIP_PXF32PARGB)
    _GDIPlus_ImageDispose($hImage)
    Return $hPremultiplied
EndFunc
```

- **Tous les bitmaps intermédiaires** (caches, calques, compositions) créés en
  PARGB : `_GDIPlus_BitmapCreateFromScan0($iW, $iH, $GDIP_PXF32PARGB)`.
- Quand on doit manipuler les pixels au CPU, `LockBits` en demandant
  explicitement `$GDIP_PXF32ARGB` : GDI+ convertit au lock, le reste du code
  travaille en ARGB classique sans autre adaptation.

---

## 5. CompositingMode SourceCopy pour les blits opaques

Le blend per-pixel (SourceOver) est le mode par défaut. Quand la source est
**opaque plein cadre** (fond de scène, calque UI plein écran), passer en
SourceCopy transforme le blend en copie directe :

```autoit
_GDIPlus_GraphicsSetCompositingMode($hLogicalGfx, 1) ; SourceCopy
_GDIPlus_GraphicsDrawImage($hLogicalGfx, $hStaticBitmap, $iOffsetX, $iOffsetY)
_GDIPlus_GraphicsSetCompositingMode($hLogicalGfx, 0) ; restaurer SourceOver !
```

Toujours restaurer le mode 0 juste après, sinon tout ce qui suit perd son alpha.

---

## 6. Résolution logique fixe + échelles entières

- Le jeu se rend dans une **résolution logique constante** ; la fenêtre peut
  faire une autre taille, l'upscale a lieu au `StretchBlt` final. Tout le code
  de jeu ignore la taille réelle de la fenêtre.
- Échelles **entières** dérivées de constantes (`$WORLD_RENDER_SCALE`,
  `$HUD_LOGICAL_SCALE = Int($GAME_VIEW_WIDTH / $HUD_SOURCE_WIDTH)`) : le pixel
  art reste net, pas d'interpolation intermédiaire.
- Helpers de conversion centralisés (jamais de multiplication inline dispersée) :
  `Render_WorldToScreenX/Y`, `Render_ScaledOffset` (troncature simple),
  `Render_ScaledSize` (clampé à 1 min pour ne jamais dessiner en taille 0),
  `Render_HudScaled`.

### Piège : `Int()` tronque vers zéro

`Int(x + 0.5)` n'est PAS un arrondi pour x négatif (il arrondit vers le haut).
La caméra peut devenir négative (reconstruction du cache à marge, petites
salles) → le décor en cache se décale d'1 pixel par rapport aux dessins
par-frame. Arrondi **signé** obligatoire pour snapper la caméra :

```autoit
Func Render_GetSnappedCameraX()
    Local $fCamera = $g_tCamera[$CAMERA_X]
    If $fCamera >= 0 Then Return Int($fCamera + 0.5)
    Return Int($fCamera - 0.5)
EndFunc
```

Et **toute** conversion monde→écran passe par la caméra snappée : un même
arrondi partout, sinon deux couches dessinées via deux chemins divergent d'1 px.

---

## 7. Caches de couches : le cœur des performances

Règle d'or : **le coût par frame doit être proportionnel à ce qui change**, pas
à ce qui est affiché. Tout ce qui est stable est pré-composé dans un bitmap et
re-blitté (un DrawImage plein écran ≈ 0,14 ms, contre plusieurs ms de re-dessin).

### 7.1 Cache de scène statique À MARGE (le plus gros gain : traveling 67→360 fps)

Le décor complet est rendu dans un bitmap **plus grand que l'écran**
(marge monde `PAD_X = 128`, `PAD_Y = 64`) :

- **Rendu du cache** : on recule temporairement la caméra de la marge et on
  élargit les bornes logiques (largeur/hauteur logiques += 2×marge), on dessine
  tout le décor avec le pipeline normal (WorldToScreen + culling remplissent
  naturellement le bitmap élargi), puis on restaure caméra et bornes. On mémorise
  la caméra d'origine du rebuild.
- **Chaque frame** : delta = caméra actuelle − caméra du rebuild. Tant que
  `|delta| <= marge`, on se contente de **blitter le cache avec un offset**
  (`-(PAD + delta)` converti en pixels écran). Un pan de caméra ne coûte donc
  rien de plus que l'affichage immobile.
- **Rebuild uniquement** quand on sort de la marge, ou quand la clé de contenu
  change (type de scène, salle active, flags "dirty" posés par les mutations du
  décor).

Le foreground (couche devant les acteurs) suit le même offset dans son propre
bitmap plein écran PARGB.

### 7.2 Calques intermédiaires pour l'ordre de profondeur

Quand des éléments animés par frame (personnages) doivent s'intercaler ENTRE des
éléments statiques, découper le statique en calques A/B (bitmaps PARGB
transparents, effacés à `0x00000000`, reconstruits avec le statique) :
`fond statique → acteurs → calque mobilier B → effets`. L'ordre z est conservé
sans redessiner le mobilier.

Cas particulier "mur qui masque le personnage" : composite PARGB dédié dont la
clé de cache est **l'offset relatif personnage↔mur** (pas la position absolue) —
le cache survit ainsi aux pans de caméra.

### 7.3 Caches à clé (keyed caches) pour le HUD et l'UI

Patron générique appliqué au HUD, aux overlays (carte de survol, fiche détail)
et à chaque écran plein écran :

```autoit
; 1. Construire une clé BON MARCHÉ (concat de scalaires déjà en mémoire)
Local $sKey = $iHp & "|" & $iTours & "|" & $iSkillCount & "|" & ...
; 2. Si la clé n'a pas changé : re-blitter le bitmap cache, terminé.
; 3. Sinon : redessiner le cache, mémoriser la clé, puis blitter.
```

- La clé doit se calculer en **microsecondes** (lire des variables, pas appeler
  de la logique coûteuse) — sinon la clé coûte plus cher que ce qu'elle évite.
- Le bitmap de cache est dessiné **en coordonnées locales** (y=0) puis blitté à
  sa position écran : il reste valable si l'élément bouge.
- Écrans statiques plein écran (menus, bilans) : la page entière vit dans un
  cache blitté en SourceCopy chaque frame ; les éléments réactifs (survol,
  bouton, popup) sont dessinés **hors cache par-dessus** — le survol ne
  reconstruit jamais la page.
- Attention aux écrans qui recouvrent l'UI sans toucher sa clé : forcer une
  invalidation de l'UI en dessous tant qu'ils sont affichés, sinon au retour
  seule la zone de jeu est redessinée et l'overlay "fantôme" reste visible.

### 7.4 Mémoïsation des calculs de logique appelés par le rendu

Le rendu ne doit jamais appeler de la logique coûteuse par frame (validation de
compétences ≈ 0,5 ms/appel, appelée 5-6×/frame par les glows et le survol → mémo
obligatoire). Patron gagnant, utilisé 3 fois dans le projet :

> **clé scalaire bon marché + filet périodique (12 frames)**
> Le mémo n'alimente que le VISUEL ; les clics/actions revalident en direct.

Le filet périodique force un recalcul toutes les N frames même à clé identique :
il rattrape les mutations qui auraient échappé à la clé.

**Piège documenté (4 régressions)** : toute mutation d'état qui ne passe pas par
l'invalidation explicite du mémo devient invisible jusqu'à N frames. Fatal si un
consommateur lit la valeur **dans la même frame** que la mutation. Règle : après
toute mutation du domaine mémoïsé, invalider AVANT le premier lecteur.

---

## 8. Éviter les chemins lents de GDI+

Mesures sur machine de dev — hiérarchie à retenir :

| Opération | Coût |
|---|---|
| DrawImage PARGB plein écran (~936×518) | ≈ 0,14 ms |
| DrawImage avec `ImageAttributes` (matrice couleur) | ≈ **0,2 ms par draw** (chemin lent) |
| DrawImage bitmap ARGB non prémultiplié | ≈ 3× le coût PARGB |
| Appel de fonction AutoIt + garde | ≈ 2 µs |
| Lecture d'un élément de tableau | ≈ 0,35 µs |

Conséquences pratiques :

- **Jamais de matrice couleur par frame.** Teintes, fades, variantes alpha :
  les **pré-rendre une fois** en bitmaps PARGB et blitter la variante. Pour un
  fondu continu, quantifier (ex. 16 niveaux d'alpha pré-rendus pour les glows
  pulsés) — l'œil ne voit pas la différence, le CPU si.
- Ne pas créer/détruire fonts, brushes, pens, StringFormat par frame : les
  objets partagés vivent en globals créés au démarrage ; les ponctuels sont
  créés/disposés localement uniquement dans du code de (re)construction de
  cache, pas dans le chemin chaud.
- Le texte GDI+ est cher : il vit dans les caches à clé (§7.3), jamais redessiné
  à l'identique. Pour les compteurs qui changent souvent, une bitmap font
  (glyphes blittés) est bien plus rapide que MeasureString/DrawString.

---

## 9. Traitements par pixel : machine code natif

Quand un traitement par pixel est inévitable (memset de gros buffers, application
d'alpha d'un masque, teinte, niveaux de gris, application de glow), une boucle
AutoIt par pixel est rédhibitoire. Solution du projet : **procédures x86/x64
pré-assemblées** injectées en mémoire :

```autoit
Local $bProc = Binary("0x...")  ; opcodes x64 ou x86 selon @AutoItX64
Local $aProc = DllCall("kernel32.dll", "ptr", "VirtualAlloc", "ptr", 0, _
        "ulong_ptr", BinaryLen($bProc), "dword", 0x1000, "dword", 0x0040) ; MEM_COMMIT, PAGE_EXECUTE_READWRITE
DllStructSetData(DllStructCreate("byte[" & BinaryLen($bProc) & "]", $aProc[0]), 1, $bProc)
; appel : DllCallAddress sur $aProc[0], sur les pixels obtenus via LockBits
; libération au shutdown : VirtualFree(..., 0x4000) ; MEM_RELEASE
```

Enchaînement type : `_GDIPlus_BitmapLockBits` (format ARGB explicite) → appel du
proc natif sur `Scan0`/`Stride` → `UnlockBits`. Chaque proc a son
`Ensure...Proc()` (création lazy) et son `Release...Proc()` enregistré au
registre de disposers (§11). Prévoir les deux variantes 32/64 bits.

---

## 10. Boucle de jeu et cadence

```autoit
While $bRunning
    $hFrameTimer = TimerInit()
    Input_Handle()
    Game_Update()      ; logique, dt en ms ($ENGINE_DELTA_MS)
    Render_Frame()     ; composition + Render_Present()
    Game_SyncFrame($hFrameTimer)
WEnd

Func Game_SyncFrame($hFrameTimer)
    Local $iSleep = Floor($GAME_FRAME_MS - TimerDiff($hFrameTimer))
    If $iSleep > 0 Then _HighPrecisionSleep($iSleep * 1000, $hDllNtdll) ; NtDelayExecution
EndFunc
```

- `Sleep()` AutoIt a une granularité ~15 ms : inutilisable pour cadencer.
  **`NtDelayExecution`** (ntdll) donne une précision sub-milliseconde.
- Cible FPS très haute (500) = la boucle est en pratique non bridée ; la marge
  de FPS EST la métrique de perf (toute régression se voit immédiatement).
- **Input batché** : 1 seul `GetKeyboardState` (1 DllCall) par frame, lu ensuite
  en mémoire — au lieu de N appels `_IsPressed` (≈ 11 µs chacun).
- **Hit-tests de survol conditionnés** : ne recalculer que si la souris ou la
  caméra a bougé, sur clic, ou via le filet périodique — pas chaque frame.

### Profiler intégré dès le premier jour

Sections chronométrées (`Perf_Begin/Perf_End`) autour de chaque grande étape
(input, update, ui, scène, statique, acteurs, foreground, hud, overlays, blit,
present), affichées dans le titre de la fenêtre via une touche debug. C'est ce
qui permet de mesurer chaque optimisation au lieu de la supposer. Coût nul
quand désactivé.

---

## 11. Cycle de vie des ressources GDI+ : registre de disposers

Fuite silencieuse garantie si la libération repose sur une liste manuelle dans
le shutdown. Mécanisme du projet :

```autoit
; À LA CRÉATION de tout nouveau cache GDI+ :
Render_RegisterDisposer("Mon_DisposeXxx")   ; dedup intégré

; Au shutdown :
Func Render_RunDisposers()
    For $i = 0 To UBound($g_aDisposers) - 1
        Call($g_aDisposers[$i])
    Next
EndFunc
```

Contrat de chaque disposer :
- **Idempotent** : `If $h <> 0 Then ... ; $h = 0` — appelable deux fois sans casse.
- **Indépendant de l'ordre** : chaque cache libère son propre couple
  graphics+bitmap (toujours disposer le Graphics AVANT son Bitmap).
- Le pattern "recreate" (`Create...` commence par appeler `Dispose...`) permet de
  reconstruire un cache sans fuite.

---

## 12. Checklist de démarrage d'un nouveau projet

Dans l'ordre, avant toute feature :

1. **Fenêtre** : `GUICreate`, `GUISetBkColor`, `GUIRegisterMsg($WM_ERASEBKGND, → Return 1)`.
2. **Cibles de rendu** : DIB section 32bpp + memory DC + `_GDIPlus_GraphicsCreateFromHDC`,
   `SetStretchBltMode(COLORONCOLOR)` sur le DC fenêtre.
3. **Bloc de modes GDI+** (interpolation 5 / pixel offset 2 / smoothing 0 / text hint)
   appliqué à ce graphics et à tout graphics créé ensuite.
4. **`Render_Present()`** = un unique StretchBlt SRCCOPY, appelé en fin de `Render_Frame()`.
5. **Chargeur d'assets** avec conversion PARGB systématique ; tout
   `BitmapCreateFromScan0` en `$GDIP_PXF32PARGB`.
6. **Résolution logique fixe** + helpers d'échelle centralisés + caméra snappée
   à arrondi signé.
7. **Boucle** : timer de frame + `NtDelayExecution`, delta ms exposé à la logique,
   input batché (1 `GetKeyboardState`/frame).
8. **Profiler par sections** (touche debug, affichage dans le titre) — dès le début.
9. **Registre de disposers** + règle "register-on-create" pour tout cache GDI+.
10. Dès le premier décor : **cache de scène statique à marge** (§7.1) ; dès la
    première UI : **cache à clé scalaire** (§7.3).

Et les trois interdits qui coûtent le plus cher s'ils s'installent :
- ❌ `ImageAttributes`/matrice couleur dans le chemin par frame (pré-rendre les variantes).
- ❌ Bitmap ARGB non prémultiplié blitté par frame (tout en PARGB).
- ❌ Logique coûteuse appelée depuis le rendu sans mémo (clé scalaire + filet périodique,
  invalidation explicite AVANT le premier lecteur après chaque mutation).
