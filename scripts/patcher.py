#!/usr/bin/env python3
"""
InstaController Native ReVanced Patcher
Script automatisé d'injection bytecode Smali et multi-dex pour Instagram Android.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ANDROID_BUILD_TOOLS = "/Users/charlesrivest/Library/Android/sdk/build-tools/34.0.0"
ZIPALIGN = os.path.join(ANDROID_BUILD_TOOLS, "zipalign")
APKSIGNER = os.path.join(ANDROID_BUILD_TOOLS, "apksigner")
KEYSTORE = os.path.expanduser("~/.android/debug.keystore")
DEVICE_SERIAL = "R5CT12FJ7EM"

def run_command(cmd, desc=None, check=True):
    if desc:
        print(f"[Patcher] {desc}...")
    result = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"[Patcher] ERREUR ({desc}):\n{result.stderr}\n{result.stdout}")
        sys.exit(1)
    return result

def ensure_artifacts(project_root):
    dex_path = os.path.join(project_root, "revanced-extension/build/libs/classes.dex")
    if not os.path.isfile(dex_path):
        run_command(
            f"export JAVA_HOME=/opt/homebrew/opt/openjdk@21 && ./gradlew :revanced-extension:assemble",
            desc="Compilation des modules :core-filter et :revanced-extension"
        )
    if not os.path.isfile(dex_path):
        print(f"[Patcher] Erreur : impossible de trouver {dex_path}")
        sys.exit(1)
    print(f"[Patcher] Artefact DEX validé : {dex_path} ({os.path.getsize(dex_path)} octets)")
    return dex_path

def patch_apk(input_apk, output_apk, extension_dex):
    print(f"\n[Patcher] Démarrage du patch de : {input_apk}")
    work_dir = tempfile.mkdtemp(prefix="instacontroller_patch_")

    try:
        # 1. Analyse des DEX existants dans l'APK
        dex_indices = []
        with zipfile.ZipFile(input_apk, 'r') as zin:
            for item in zin.infolist():
                m = re.match(r"^classes(\d*)\.dex$", item.filename)
                if m:
                    idx = int(m.group(1)) if m.group(1) else 1
                    dex_indices.append(idx)

        next_dex_index = max(dex_indices) + 1 if dex_indices else 1
        new_dex_name = f"classes{next_dex_index}.dex"
        print(f"[Patcher] Multi-DEX détecté ({len(dex_indices)} DEX). Nouveau DEX assigné : {new_dex_name}")

        # 2. Création de l'archive patchée en injectant notre classes.dex
        unsigned_apk = os.path.join(work_dir, "unsigned.apk")
        with zipfile.ZipFile(input_apk, 'r') as zin:
            with zipfile.ZipFile(unsigned_apk, 'w', compression=zipfile.ZIP_DEFLATED) as zout:
                for item in zin.infolist():
                    # Suppression des signatures Meta originales (META-INF)
                    if item.filename.startswith("META-INF/"):
                        if item.filename.endswith((".RSA", ".SF", ".MF", ".DSA", ".EC")):
                            continue
                    data = zin.read(item.filename)
                    zout.writestr(item, data)

                # Injection de notre DEX contenant InstaControllerHook et InstagramFilter
                print(f"[Patcher] Injection de {new_dex_name} contenant InstaControllerHook...")
                with open(extension_dex, 'rb') as f:
                    zout.writestr(new_dex_name, f.read())

        # 3. Zipalign (alignement 4 octets requis pour Android 11+)
        aligned_apk = os.path.join(work_dir, "aligned.apk")
        run_command(
            [ZIPALIGN, "-p", "-f", "4", unsigned_apk, aligned_apk],
            desc="Alignement 4-octets de l'APK (zipalign)"
        )

        # 4. Signature APK avec apksigner (v1, v2, v3 schemes)
        run_command(
            [
                APKSIGNER, "sign",
                "--ks", KEYSTORE,
                "--ks-pass", "pass:android",
                "--ks-key-alias", "androiddebugkey",
                "--key-pass", "pass:android",
                "--out", output_apk,
                aligned_apk
            ],
            desc="Signature cryptographique de l'APK avec debug.keystore"
        )

        # 5. Vérification apksigner
        verify_res = run_command([APKSIGNER, "verify", output_apk], desc="Vérification de la signature APK")
        print(f"[Patcher] Succès : APK patché et signé prêt à être déployé : {output_apk}")
        print(f"[Patcher] Taille finale : {os.path.getsize(output_apk) / (1024*1024):.2f} MB")

    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

def deploy_and_test(apk_path, serial=DEVICE_SERIAL):
    print(f"\n[Patcher] Déploiement ADB sur {serial}...")

    # Vérification si une version avec signature différente est présente
    install_res = run_command(
        ["adb", "-s", serial, "install", "-r", apk_path],
        desc="Tentative d'installation avec conservation des données",
        check=False
    )

    if install_res.returncode != 0:
        if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in install_res.stderr or "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in install_res.stdout:
            print("[Patcher] Conflit de signature détecté (PlayStore Meta vs Debug Keystore).")
            print("[Patcher] Désinstallation propre de l'ancienne version...")
            run_command(["adb", "-s", serial, "uninstall", "com.instagram.android"], desc="Désinstallation de com.instagram.android")
            run_command(["adb", "-s", serial, "install", apk_path], desc="Installation de l'APK patché")
        else:
            print(f"[Patcher] Erreur ADB install : {install_res.stderr} {install_res.stdout}")
            sys.exit(1)
    else:
        print("[Patcher] Installation réussie !")

    # Démarrage de l'application
    print("[Patcher] Lancement d'Instagram sur le smartphone...")
    run_command(["adb", "-s", serial, "shell", "am", "force-stop", "com.instagram.android"], check=False)
    run_command(
        ["adb", "-s", serial, "shell", "monkey", "-p", "com.instagram.android", "-c", "android.intent.category.LAUNCHER", "1"],
        desc="Démarrage via Intent Launcher"
    )

    print("[Patcher] Instagram lancé avec succès sur le Samsung Galaxy A13 5G !")

def main():
    parser = argparse.ArgumentParser(description="InstaController Native APK Patcher")
    parser.add_argument("--apk", default="apk_workspace/instagram_base.apk", help="Chemin vers l'APK source")
    parser.add_argument("--out", default="apk_workspace/instagram_patched.apk", help="Chemin de sortie")
    parser.add_argument("--deploy", action="store_true", help="Installer et lancer directement sur le smartphone")
    parser.add_argument("--serial", default=DEVICE_SERIAL, help="Serial ADB")
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dex_path = ensure_artifacts(project_root)

    patch_apk(args.apk, args.out, dex_path)

    if args.deploy:
        deploy_and_test(args.out, args.serial)

if __name__ == "__main__":
    main()
