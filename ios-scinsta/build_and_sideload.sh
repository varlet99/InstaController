#!/usr/bin/env bash
set -e

# ==============================================================================
# InstaController - Pipeline de Compilation, Injection Mach-O & Déploiement iOS
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SDK_PATH="${ROOT_DIR}/tools/sdks/iPhoneOS16.5.sdk"
INSERT_DYLIB_BIN="${ROOT_DIR}/tools/insert_dylib"

if ! command -v insert_dylib &>/dev/null && [ -f "${INSERT_DYLIB_BIN}" ]; then
    export PATH="$(dirname "${INSERT_DYLIB_BIN}"):${PATH}"
fi

echo "=================================================================="
echo " [InstaController iOS] Initialisation de la Phase 5 (SCInsta)"
echo "=================================================================="

# 1. Vérification de l'environnement et des outils
if [ ! -d "${SDK_PATH}" ]; then
    echo "[-] Erreur : SDK iOS introuvable dans ${SDK_PATH}"
    exit 1
fi

if ! command -v clang &>/dev/null; then
    echo "[-] Erreur : 'clang' est introuvable."
    exit 1
fi

if ! command -v ldid &>/dev/null; then
    echo "[-] Erreur : 'ldid' est introuvable (brew install ldid)."
    exit 1
fi

if ! command -v insert_dylib &>/dev/null; then
    echo "[-] Erreur : 'insert_dylib' est introuvable."
    exit 1
fi

# 2. Compilation de InstaController.dylib (ARM64 iOS)
echo "[*] Étape 1 : Compilation de InstaController.dylib pour iOS ARM64..."
clang -dynamiclib -arch arm64 \
    -isysroot "${SDK_PATH}" \
    -miphoneos-version-min=14.0 \
    -O2 -fobjc-arc \
    -framework Foundation -framework CoreFoundation \
    -I"${SCRIPT_DIR}" \
    "${SCRIPT_DIR}/InstaControllerFilter.m" \
    "${SCRIPT_DIR}/Tweak.m" \
    -o "${SCRIPT_DIR}/InstaController.dylib"

ldid -S "${SCRIPT_DIR}/InstaController.dylib"
echo "[+] InstaController.dylib compilé et signé avec succès ($(ls -lh "${SCRIPT_DIR}/InstaController.dylib" | awk '{print $5}'))."

# 3. Exécution des tests unitaires natifs
echo "[*] Étape 2 : Validation des filtres via test_ios_filter..."
if [ -f "${SCRIPT_DIR}/test_ios_filter" ]; then
    "${SCRIPT_DIR}/test_ios_filter"
fi

# 4. Recherche de l'IPA source
TARGET_IPA="$1"
if [ -z "${TARGET_IPA}" ]; then
    if [ -f "${ROOT_DIR}/apk_workspace/instagram_base.ipa" ]; then
        TARGET_IPA="${ROOT_DIR}/apk_workspace/instagram_base.ipa"
    elif [ -f "${SCRIPT_DIR}/instagram_base.ipa" ]; then
        TARGET_IPA="${SCRIPT_DIR}/instagram_base.ipa"
    fi
fi

FINAL_IPA="${SCRIPT_DIR}/InstaController-iOS.ipa"

if [ -n "${TARGET_IPA}" ] && [ -f "${TARGET_IPA}" ]; then
    echo "[*] Étape 3 : Injection dans l'IPA officiel spécifié : ${TARGET_IPA}"
    BUILD_DIR="${SCRIPT_DIR}/build_patch_ipa"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    
    echo "  -> Décompression de l'IPA..."
    unzip -q "${TARGET_IPA}" -d "${BUILD_DIR}"
    
    APP_DIR=$(find "${BUILD_DIR}/Payload" -maxdepth 1 -name "*.app" | head -n 1)
    if [ -z "${APP_DIR}" ]; then
        echo "[-] Erreur : Aucun bundle .app trouvé dans le dossier Payload."
        exit 1
    fi
    
    APP_NAME=$(basename "${APP_DIR}")
    EXE_NAME=$(defaults read "${APP_DIR}/Info.plist" CFBundleExecutable 2>/dev/null || echo "${APP_NAME%.app}")
    EXE_PATH="${APP_DIR}/${EXE_NAME}"
    
    echo "  -> Bundle détecté : ${APP_NAME} (Binaire : ${EXE_NAME})"
    mkdir -p "${APP_DIR}/Frameworks"
    cp "${SCRIPT_DIR}/InstaController.dylib" "${APP_DIR}/Frameworks/InstaController.dylib"
    ldid -S "${APP_DIR}/Frameworks/InstaController.dylib"
    
    echo "  -> Injection LC_LOAD_DYLIB dans le binaire Mach-O principal..."
    insert_dylib --inplace --overwrite "@executable_path/Frameworks/InstaController.dylib" "${EXE_PATH}"
    
    echo "  -> Signature ad-hoc avec ldid..."
    ldid -S "${EXE_PATH}"
    
    FINAL_IPA="${SCRIPT_DIR}/Instagram_patched.ipa"
    echo "  -> Reconditionnement de l'archive IPA : ${FINAL_IPA}..."
    (cd "${BUILD_DIR}" && zip -qr "${FINAL_IPA}" Payload)
    rm -rf "${BUILD_DIR}"
    echo "[+] IPA Instagram patché généré avec succès !"
else
    echo "[*] Étape 3 : Aucun IPA officiel fourni. Génération de l'application hôte InstaController-iOS (WKWebView + Mach-O)..."
    HOST_SRC="${SCRIPT_DIR}/host_app"
    BUILD_DIR="${SCRIPT_DIR}/build_host_ipa"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}/Payload/InstaController.app/Frameworks"
    
    echo "  -> Compilation du binaire d'application Mach-O ARM64..."
    clang -arch arm64 \
        -isysroot "${SDK_PATH}" \
        -miphoneos-version-min=14.0 \
        -O2 -fobjc-arc \
        -framework UIKit -framework WebKit -framework Foundation -framework CoreGraphics \
        "${HOST_SRC}/main.m" \
        -o "${BUILD_DIR}/Payload/InstaController.app/InstaController"
        
    cp "${HOST_SRC}/Info.plist" "${BUILD_DIR}/Payload/InstaController.app/Info.plist"
    cp "${SCRIPT_DIR}/InstaController.dylib" "${BUILD_DIR}/Payload/InstaController.app/Frameworks/InstaController.dylib"
    
    echo "  -> Injection LC_LOAD_DYLIB dans le binaire hôte..."
    insert_dylib --inplace --overwrite "@executable_path/Frameworks/InstaController.dylib" "${BUILD_DIR}/Payload/InstaController.app/InstaController"
    
    echo "  -> Signature des composants avec ldid..."
    ldid -S "${BUILD_DIR}/Payload/InstaController.app/Frameworks/InstaController.dylib"
    ldid -S "${BUILD_DIR}/Payload/InstaController.app/InstaController"
    
    echo "  -> Création de l'archive IPA : ${FINAL_IPA}..."
    (cd "${BUILD_DIR}" && zip -qr "${FINAL_IPA}" Payload)
    rm -rf "${BUILD_DIR}"
    echo "[+] Application hôte InstaController-iOS.ipa générée avec succès ($(ls -lh "${FINAL_IPA}" | awk '{print $5}'))."
fi

# 5. Contrôle d'intégrité REA Area-Watcher
echo "[*] Étape 4 : Analyse d'ancres REA sur l'IPA final..."
python3 "${ROOT_DIR}/area-watcher/anchor_watcher.py" --ipa "${FINAL_IPA}"

# 6. Détection et Déploiement iPhone
echo "=================================================================="
echo " [Détection iPhone & Déploiement]"
echo "=================================================================="

CONNECTED_DEVICE=$(idevice_id -l 2>/dev/null | head -n 1 || true)
if [ -n "${CONNECTED_DEVICE}" ]; then
    echo "[+] iPhone détecté en USB !"
    echo "    UDID : ${CONNECTED_DEVICE}"
    
    # Test d'appairage
    PAIR_STATUS=$(idevicepair pair 2>&1 || true)
    if echo "${PAIR_STATUS}" | grep -q "SUCCESS"; then
        echo "[+] Appairage USB confirmé avec l'iPhone."
        if command -v ideviceinstaller &>/dev/null; then
            echo "[*] Tentative d'installation directe via ideviceinstaller..."
            ideviceinstaller -i "${FINAL_IPA}" || echo "[!] L'installation directe nécessite la signature développeur de votre profil Apple."
        fi
    else
        echo "[!] Note : L'iPhone nécessite la confirmation du dialogue 'Faire confiance à cet ordinateur'."
        echo "    Déverrouillez votre iPhone et appuyez sur 'Faire confiance'."
    fi
else
    echo "[!] Aucun iPhone détecté via libimobiledevice."
fi

# 7. Lancement automatique de Sideloadly si disponible
if [ -d "/Applications/Sideloadly.app" ]; then
    echo "[*] Lancement de Sideloadly avec l'IPA généré..."
    open -a /Applications/Sideloadly.app "${FINAL_IPA}" 2>/dev/null || open /Applications/Sideloadly.app 2>/dev/null || true
    echo "[+] Sideloadly ouvert avec l'IPA : ${FINAL_IPA}"
    echo "    Il vous suffit de cliquer sur 'Start' dans Sideloadly pour installer l'application sur votre iPhone."
else
    echo "[!] Sideloadly n'a pas été trouvé dans /Applications/Sideloadly.app"
fi

echo "=================================================================="
echo "[✓] Phase 5 Terminée avec succès ! IPA prêt : ${FINAL_IPA}"
echo "=================================================================="
