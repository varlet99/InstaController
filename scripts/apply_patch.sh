#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$(dirname "$DIR")"

export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
export PATH="$JAVA_HOME/bin:$PATH"

echo "=================================================="
echo "  InstaController - Patch & Injection Native      "
echo "=================================================="

# 1. Vérification / Compilation des artefacts
echo "[1/4] Compilation des modules Kotlin..."
cd "$ROOT_DIR"
./gradlew :core-filter:assemble :revanced-extension:assemble

# 2. Exécution du patcher avec injection DEX et signature
echo "[2/4] Patch de l'APK officiel et signature cryptographique..."
python3 "$ROOT_DIR/scripts/patcher.py" \
    --apk "$ROOT_DIR/apk_workspace/instagram_base.apk" \
    --out "$ROOT_DIR/apk_workspace/instagram_patched.apk" \
    "$@"

echo "[3/4] Scan du package patché avec Area-Watcher / REA..."
python3 "$ROOT_DIR/area-watcher/anchor_watcher.py" \
    --apk "$ROOT_DIR/apk_workspace/instagram_patched.apk" \
    --output "$ROOT_DIR/apk_workspace/patched_report.json"

echo "=================================================="
echo "  Patch terminé avec succès !                     "
echo "  Fichier : $ROOT_DIR/apk_workspace/instagram_patched.apk"
echo "=================================================="
