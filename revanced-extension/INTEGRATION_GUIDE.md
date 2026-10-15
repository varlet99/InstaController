# Guide d'Intégration ReVanced pour InstaController

Ce guide détaille l'injection du pont `:revanced-extension` et du moteur `:core-filter` dans l'application officielle d'Instagram Android.

---

## 1. Artefacts Produits par la Phase 4

- **Extension Bytecode** : `revanced-extension/build/libs/revanced-extension-1.0.0-SNAPSHOT.jar`
- **Bytecode DEX Android (prêt à l'injection)** : `revanced-extension/build/libs/classes.dex`
  - Contient :
    - `Lcom/instacontroller/extension/InstaControllerHook;`
    - `Lcom/instacontroller/extension/InstaControllerPatch;`
    - `Lcom/instacontroller/core/InstagramFilter;`
    - `Lcom/instacontroller/core/PriorityStoryScorer;`
    - `Lcom/instacontroller/core/StoryScorer;`

---

## 2. Points d'Injection Smali (Fingerprints)

### A. Endpoint Timeline (`/api/v1/feed/timeline/`)
Localiser dans le code décompilé la méthode de désérialisation identifiée par l'ancre `"feed_items"` ou `"is_sponsored"` (détectable automatiquement via `area-watcher/anchor_watcher.py`).

**Injection Smali :**
```smali
# Interception de la String JSON brute de réponse avant parsing
invoke-static {v0}, Lcom/instacontroller/extension/InstaControllerHook;->filterTimeline(Ljava/lang/String;)Ljava/lang/String;
move-result-object v0
```

### B. Endpoint Stories Tray (`/api/v1/feed/reels_tray/`)
Localiser la méthode de désérialisation du plateau de stories identifiée par l'ancre `"reels_tray"` ou `"ranked_position"`.

**Injection Smali :**
```smali
# Réordonnancement selon la liste de priorités (Favoris > Actifs > Vus)
invoke-static {v0}, Lcom/instacontroller/extension/InstaControllerHook;->filterStories(Ljava/lang/String;)Ljava/lang/String;
move-result-object v0
```

---

## 3. Méthode d'Intégration ReVanced CLI

### Option 1 : Via ReVanced CLI et Patcher
```bash
# 1. Compiler les artefacts InstaController
./gradlew :revanced-extension:assemble

# 2. Lancer ReVanced CLI avec le patch
revanced-cli patch \
    --patch-bundle revanced-extension/build/libs/revanced-extension-1.0.0-SNAPSHOT.jar \
    --include "InstaController Ad & Stories Filter" \
    --out instagram-patched.apk \
    instagram-base.apk
```

### Option 2 : Injection Directe Smali & Dex Merge (Rapide & sans framework externe)
```bash
# 1. Décompresser l'APK cible
apktool d instagram.apk -o instagram_src

# 2. Ajouter le DEX dans l'APK (renommer classes.dex en classesN.dex suivant)
# Ex: si l'APK compte classes.dex jusqu'à classes6.dex, copier vers classes7.dex :
cp revanced-extension/build/libs/classes.dex instagram_src/classes7.dex

# 3. Insérer l'instruction invoke-static dans la méthode identifiée par area-watcher

# 4. Recompiler et aligner l'APK
apktool b instagram_src -o instagram_mod.apk
zipalign -p -f 4 instagram_mod.apk instagram_aligned.apk
apksigner sign --ks ~/.android/debug.keystore --ks-pass pass:android instagram_aligned.apk

# 5. Déployer sur le Samsung Galaxy A13 5G
adb -s R5CT12FJ7EM install -r instagram_aligned.apk
```

---

## 4. Propriétés Fail-Safe & Tolérance aux Pannes
Toutes les méthodes de `InstaControllerHook` encapsulent leurs traitements dans un bloc `try / catch (Throwable)`. En cas d'incohérence ou de mutation soudaine du format JSON par Meta, le hook logue l'événement et retourne immédiatement la charge brute non modifiée sans jamais provoquer de crash de l'application cliente.
