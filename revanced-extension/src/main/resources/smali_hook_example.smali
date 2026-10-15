# Exemple d'injection Smali générée par InstaControllerPatch
# Cible : Méthode de désérialisation HTTP d'Instagram (ex: parseFromJson(Ljava/lang/String;)Lcom/instagram/feed/model/Feed;)
# Registre d'entrée : p0 (this), p1 (rawJson String)

.method public static parseTimelineResponse(Ljava/lang/String;)Ljava/lang/String;
    .registers 2
    .param p0, "rawJson"    # Ljava/lang/String;

    .prologue
    # ==============================================================
    # DEBUT INJECTION INSTACONTROLLER HOOK
    # ==============================================================
    invoke-static {p0}, Lcom/instacontroller/extension/InstaControllerHook;->filterTimeline(Ljava/lang/String;)Ljava/lang/String;
    move-result-object p0
    # ==============================================================
    # FIN INJECTION INSTACONTROLLER HOOK (p0 est maintenant purgé)
    # ==============================================================

    # Suite normale de l'exécution d'Instagram
    return-object p0
.end method
