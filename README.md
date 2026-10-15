# InstaController

**InstaController** est une solution complète de reverse-engineering et de patch natif Android pour l'application officielle Instagram. Elle neutralise l'ensemble des publicités, formats sponsorisés et suggestions algorithmiques intrusives, tout en réordonnant le plateau des Stories selon les priorités de l'utilisateur.

---

## 🚀 Fonctionnalités Principales

1. **Éradication Totale des Publicités & Suggestions dans le Fil d'Actualité** :
   - Élimination des publications commanditées (`is_sponsored`, tags publicitaires Pando `injected`, `A1I`, `A15`, `A3C`).
   - Suppression des blocs d'utilisateurs suggérés (`suggested_users`, `netego`, `BLOKS_NETEGO`).
   - Neutralisation des métadonnées de throttling et de ciblage publicitaire au niveau racine (`A05`, `A0E`, `A0K`).

2. **Tri Intelligent des Stories (`reels_tray`)** :
   - Suppression intégrale des stories sponsorisées et des suggestions de comptes non suivis.
   - Réorganisation automatique : **Favoris > Non-vues (ordre chronologique) > Vues**.

3. **Lancement Natif Instantané (Bypass du Trampoline)** :
   - Redirection directe de `com.instagram.android.activity.MainTabActivity` vers `InstagramMainActivity` dans le manifeste (`AndroidManifest.xml`), éliminant l'écran blanc et les vérifications de signature bloquantes de `LauncherActivity`.

4. **Architecture ReVanced Multi-DEX & Sécurité Fail-Safe** :
   - Tous les hooks d'interception dans [`InstaControllerHook.kt`](revanced-extension/src/main/kotlin/com/instacontroller/extension/InstaControllerHook.kt) sont protégés par des blocs `try/catch` atomiques : l'application ne plante jamais, même en cas de modification de structure par Meta.

---

## 🏗️ Architecture du Projet

```text
NoInsta/
├── core-filter/                  # Moteur Kotlin pur de filtrage et scoring (JSON/Objets)
├── revanced-extension/           # Pont d'extension Smali / Dex ReVanced (InstaControllerHook)
│   ├── build.gradle.kts          # Tâche d8 multi-dex intégrant kotlin-stdlib dans classes24.dex
│   └── src/main/kotlin/          # Implémentation du hook et fingerprints
├── android-sandbox/              # Bac à sable WebView mobile avec HUD temps réel (Phases 1 & 2)
├── area-watcher/                 # Scanner de veille automatisée propulsé par REA (Reverse Engineer Anything)
│   └── anchor_watcher.py         # Détecteur d'ancres textuelles (feed_items, reels_tray, etc.)
├── apk_workspace/
│   ├── instagram_base.apk        # APK officiel source
│   ├── instagram_patched.apk     # APK final signé et patché (prêt au déploiement)
│   ├── AndroidManifest.xml       # Manifeste binaire patché (direct targetActivity)
│   └── dex_patches/              # Bytecode Smali injecté (classes.dex, classes3.dex, classes5.dex)
└── scripts/
    ├── apply_patch.sh            # Script d'assemblage et déploiement tout-en-un
    └── patcher.py                # Injection multi-dex, zipalign et signature apksigner
```

---

## 🛠️ Compilation & Déploiement

### Prérequis
- **Java 21** (`export JAVA_HOME=/opt/homebrew/opt/openjdk@21`)
- **Android Build-Tools 34.0.0+** (`zipalign`, `apksigner`)
- Smartphone Android connecté en ADB avec débogage USB actif.

### Commande unique de compilation et d'installation
```bash
./scripts/apply_patch.sh --deploy
```

Cette commande exécute automatiquement :
1. La compilation de `:core-filter` et `:revanced-extension` avec D8 (génération de `classes24.dex` avec runtime Kotlin).
2. L'injection des DEX Smali patchés et du manifeste dans l'archive.
3. L'alignement 4-octets `zipalign`.
4. La signature cryptographique avec `apksigner` (Debug Keystore).
5. L'installation over-the-air via `adb install -r`.
6. Le lancement direct de l'application sur le smartphone.
7. Le scan d'ancres avec **Area-Watcher** pour assurer la compatibilité continue.

---

## 📱 Statut de Validation

- **Appareil cible de validation** : Samsung Galaxy A13 5G (`SM-A136W`, Android 13 One UI).
- **Session active** : Version officielle v450.0.0.50.77.
- **Résultat** : Démarrage instantané depuis le lanceur Samsung One UI, affichage fluide, 0 publicité résiduelle dans le fil et les stories.
