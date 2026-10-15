#!/usr/bin/env python3
"""
Area-Watcher: Automated String Anchors & Bytecode Scanner for Instagram Updates
Propulsé par REA (Reverse Engineer Anything) et JADX pour la détection proactive
de ruptures d'obfuscation et de changements d'API Meta / Instagram.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Dict, List, Any, Set

DEFAULT_ANCHORS = [
    "reels_tray",
    "is_sponsored",
    "ranked_position",
    "netego_type",
    "feed_items",
    "media_or_ad",
    "suggested_users",
    "xdt_api__v1__feed__timeline__connection",
    "xdt_api__v1__feed__reels_tray"
]

class AnchorWatcher:
    def __init__(self, anchors: List[str] = None):
        self.anchors = anchors or DEFAULT_ANCHORS

    def extract_strings_from_dex(self, dex_bytes: bytes) -> Set[str]:
        """Extrait efficacement les chaînes UTF-8 ASCII depuis le bytecode DEX brut."""
        # Regex pour les chaînes littérales Dalvik Dex
        pattern = re.compile(b'[\x20-\x7E]{4,}')
        matches = pattern.findall(dex_bytes)
        return {m.decode('ascii', errors='ignore') for m in matches}

    def scan_apk_dex_strings(self, apk_path: str) -> Dict[str, Any]:
        """Scanne tous les fichiers classes.dex d'un APK pour détecter les ancres."""
        if not os.path.isfile(apk_path):
            raise FileNotFoundError(f"APK introuvable : {apk_path}")

        results: Dict[str, Any] = {
            "apk_path": apk_path,
            "apk_size_bytes": os.path.getsize(apk_path),
            "dex_files_scanned": [],
            "anchors_found": {},
            "anchors_missing": [],
            "integrity_score": 0.0
        }

        all_strings: Dict[str, List[str]] = {anchor: [] for anchor in self.anchors}

        with zipfile.ZipFile(apk_path, 'r') as zf:
            dex_names = [n for n in zf.namelist() if n.startswith("classes") and n.endswith(".dex")]
            results["dex_files_scanned"] = dex_names

            for dex_name in dex_names:
                dex_data = zf.read(dex_name)
                found_in_dex = self.extract_strings_from_dex(dex_data)

                for anchor in self.anchors:
                    if anchor in found_in_dex:
                        all_strings[anchor].append(dex_name)

        found_count = 0
        for anchor, dex_list in all_strings.items():
            if dex_list:
                found_count += 1
                results["anchors_found"][anchor] = {
                    "occurrences_in_dex": len(dex_list),
                    "dex_files": dex_list
                }
            else:
                results["anchors_missing"].append(anchor)

        results["integrity_score"] = round((found_count / len(self.anchors)) * 100.0, 2)
        return results

    def scan_source_directory(self, src_dir: str) -> Dict[str, Any]:
        """Scanne une arborescence de fichiers sources (Kotlin, Java, JS, JSON)."""
        results: Dict[str, Any] = {
            "source_dir": src_dir,
            "anchors_found": {},
            "anchors_missing": [],
            "integrity_score": 0.0
        }

        found_map: Dict[str, List[str]] = {a: [] for a in self.anchors}

        for root, _, files in os.walk(src_dir):
            for file in files:
                if file.endswith(('.kt', '.java', '.js', '.json', '.smali')):
                    full_path = os.path.join(root, file)
                    try:
                        with open(full_path, 'r', encoding='utf-8', errors='ignore') as f:
                            content = f.read()
                            for anchor in self.anchors:
                                if anchor in content:
                                    rel_path = os.path.relpath(full_path, src_dir)
                                    found_map[anchor].append(rel_path)
                    except Exception:
                        continue

        found_count = 0
        for anchor, file_list in found_map.items():
            if file_list:
                found_count += 1
                results["anchors_found"][anchor] = {
                    "files": file_list,
                    "count": len(file_list)
                }
            else:
                results["anchors_missing"].append(anchor)

        results["integrity_score"] = round((found_count / len(self.anchors)) * 100.0, 2)
        return results

    def verify_rea_mcp_environment(self) -> Dict[str, Any]:
        """Vérifie la disponibilité et la santé du serveur MCP REA."""
        rea_status = {"available": False, "version": None, "tools_count": 0}
        try:
            output = subprocess.check_output(
                ["npx", "-y", "rea-agents", "mcp", "doctor"],
                stderr=subprocess.STDOUT,
                text=True,
                timeout=15
            )
            if "healthy: true" in output:
                rea_status["available"] = True
                rea_status["healthy"] = True
                # Parse version if present
                v_match = re.search(r"version:\s*([\d\.]+)", output)
                if v_match:
                    rea_status["version"] = v_match.group(1)
                t_match = re.search(r"expected:\s*(\d+)", output)
                if t_match:
                    rea_status["tools_count"] = int(t_match.group(1))
        except Exception as e:
            rea_status["error"] = str(e)

        return rea_status

def main():
    parser = argparse.ArgumentParser(description="InstaController Area-Watcher (REA String Anchor Scanner)")
    parser.add_argument("--apk", help="Chemin vers l'APK à analyser")
    parser.add_argument("--dir", help="Dossier source à analyser")
    parser.add_argument("--check-rea", action="store_true", help="Vérifie le serveur MCP de REA")
    parser.add_argument("--output", help="Chemin du rapport JSON de sortie")
    args = parser.parse_args()

    watcher = AnchorWatcher()
    report: Dict[str, Any] = {}

    if args.check_rea:
        print("[Area-Watcher] Vérification du statut REA MCP...")
        report["rea_status"] = watcher.verify_rea_mcp_environment()
        print(f"  -> REA MCP disponible : {report['rea_status'].get('available')} (Outils: {report['rea_status'].get('tools_count')})")

    if args.apk:
        print(f"[Area-Watcher] Scan bytecode de l'APK : {args.apk}")
        report["apk_analysis"] = watcher.scan_apk_dex_strings(args.apk)
        found = len(report["apk_analysis"]["anchors_found"])
        total = len(watcher.anchors)
        print(f"  -> {found}/{total} ancres détectées ({report['apk_analysis']['integrity_score']}%)")

    if args.dir:
        print(f"[Area-Watcher] Scan du répertoire source : {args.dir}")
        report["dir_analysis"] = watcher.scan_source_directory(args.dir)
        found = len(report["dir_analysis"]["anchors_found"])
        total = len(watcher.anchors)
        print(f"  -> {found}/{total} ancres détectées ({report['dir_analysis']['integrity_score']}%)")

    if not args.apk and not args.dir and not args.check_rea:
        # Scan par défaut du projet
        default_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        print(f"[Area-Watcher] Exécution par défaut sur le projet : {default_dir}")
        report["rea_status"] = watcher.verify_rea_mcp_environment()
        report["project_scan"] = watcher.scan_source_directory(default_dir)

    output_path = args.output or os.path.join(os.path.dirname(os.path.abspath(__file__)), "anchor_report.json")
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(f"[Area-Watcher] Rapport sauvegardé dans : {output_path}")

if __name__ == "__main__":
    main()
