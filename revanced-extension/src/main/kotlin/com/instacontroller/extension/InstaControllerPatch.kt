package com.instacontroller.extension

/**
 * Définition du patch ReVanced pour Instagram (InstaController).
 *
 * Ce patch est structuré selon l'architecture du ReVanced Patcher. Il localise dynamiquement
 * les points d'ancrage réseau identifiés par Area-Watcher et injecte les appels statiques vers
 * [InstaControllerHook].
 */
object InstaControllerPatch {

    const val PATCH_NAME = "InstaController Ad & Stories Filter"
    const val PATCH_DESCRIPTION = "Purge les publications sponsorisées, les suggestions de comptes " +
            "et réorganise le plateau de stories par priorités."
    const val COMPATIBLE_PACKAGE = "com.instagram.android"

    // String Anchors identifiées par le module REA (anchor_report.json)
    val TIMELINE_ANCHORS = listOf("feed_items", "is_sponsored", "netego_type", "suggested_users")
    val STORIES_ANCHORS = listOf("reels_tray", "ranked_position")

    /**
     * Représente la signature de détection (Fingerprint) pour la méthode de parsing Timeline.
     */
    data class PatchFingerprint(
        val name: String,
        val targetStrings: List<String>,
        val hookMethodSignature: String,
        val hookClassDescriptor: String = "Lcom/instacontroller/extension/InstaControllerHook;"
    )

    val TIMELINE_FINGERPRINT = PatchFingerprint(
        name = "TimelineResponseParser",
        targetStrings = TIMELINE_ANCHORS,
        hookMethodSignature = "filterTimeline(Ljava/lang/String;)Ljava/lang/String;"
    )

    val STORIES_FINGERPRINT = PatchFingerprint(
        name = "ReelsTrayResponseParser",
        targetStrings = STORIES_ANCHORS,
        hookMethodSignature = "filterStories(Ljava/lang/String;)Ljava/lang/String;"
    )

    /**
     * Génère le snippet Smali exact requis pour intercepter une variable registre Smali (ex: p1 ou v0).
     *
     * @param register Le registre contenant la String JSON brute (ex: "v0" ou "p1").
     * @param hookMethod La méthode statique cible dans InstaControllerHook.
     */
    fun generateSmaliHook(register: String, hookMethod: String): String {
        return """
            # [InstaController] Injection du filtre natif
            invoke-static {$register}, Lcom/instacontroller/extension/InstaControllerHook;->$hookMethod
            move-result-object $register
        """.trimIndent()
    }
}
