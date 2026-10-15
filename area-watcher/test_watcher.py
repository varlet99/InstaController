import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anchor_watcher import AnchorWatcher

class TestAnchorWatcher(unittest.TestCase):

    def setUp(self):
        self.watcher = AnchorWatcher()
        self.repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    def test_rea_mcp_health(self):
        """Vérifie que le serveur MCP REA répond positivement au doctor check."""
        status = self.watcher.verify_rea_mcp_environment()
        self.assertTrue(status.get("available"), "Le MCP REA doit être disponible via npx")
        self.assertGreaterEqual(status.get("tools_count", 0), 200, "Le MCP REA doit fournir > 200 outils")

    def test_scan_source_directory_anchors(self):
        """Vérifie que les points d'ancrage essentiels sont trouvés dans le projet."""
        result = self.watcher.scan_source_directory(self.repo_root)
        self.assertIn("anchors_found", result)
        found = result["anchors_found"]

        # Les ancres clés doivent être trouvées
        self.assertIn("reels_tray", found)
        self.assertIn("is_sponsored", found)
        self.assertIn("ranked_position", found)
        self.assertIn("feed_items", found)
        self.assertIn("netego_type", found)

        self.assertGreaterEqual(result["integrity_score"], 80.0)

    def test_scan_apk_if_available(self):
        """Vérifie le scan DEX d'un APK si présent."""
        apk_path = os.path.join(self.repo_root, "android-sandbox/build/outputs/apk/debug/android-sandbox-debug.apk")
        if os.path.exists(apk_path):
            result = self.watcher.scan_apk_dex_strings(apk_path)
            self.assertIn("dex_files_scanned", result)
            self.assertGreater(len(result["dex_files_scanned"]), 0)
            self.assertIn("reels_tray", result["anchors_found"])

if __name__ == "__main__":
    unittest.main()
