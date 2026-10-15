package com.instacontroller.extension

import com.instacontroller.core.InstagramFilter
import com.instacontroller.core.PriorityStoryScorer
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicInteger

/**
 * Pont statique ReVanced pour Instagram.
 *
 * Cette classe est la cible directe des hooks Smali injectés par le patch ReVanced.
 * Toutes les méthodes sont statiques (@JvmStatic), synchrones et strictement protégées
 * contre tout crash (fail-safe) pour garantir que l'application Instagram ne plante jamais.
 */
object InstaControllerHook {

    private const val TAG = "InstaControllerHook"

    private val favoriteUsernames = CopyOnWriteArraySet<String>()
    private val totalTimelineAdsRemoved = AtomicInteger(0)
    private val totalStoriesProcessed = AtomicInteger(0)

    @Volatile
    private var filter = createFilterInstance()

    private fun createFilterInstance(): InstagramFilter {
        val scorer = PriorityStoryScorer(
            favoriteUsernames = favoriteUsernames
        )
        return InstagramFilter(defaultStoryScorer = scorer)
    }

    /**
     * Point d'injection Smali au retour de LX/03af;->unsafeParseFromJson (classes.dex) :
     * Nettoie l'objet complet de réponse de Timeline (LX/00WK;) en purgeant les listes de posts
     * (A0U et A0W) et en désactivant les unités de suggestions (A09), sondages (A08) et paquets de pub.
     */
    @JvmStatic
    fun cleanTimelineResponse(response: Any?): Any? {
        if (response == null) return response
        return try {
            val clazz = response.javaClass
            for (field in clazz.fields) {
                val fName = field.name
                // 1. Désactivation des suggestions d'utilisateurs et composants publicitaires / sondages
                if (fName == "A09" || fName == "A08" || fName == "A05" || fName == "A0D" || fName == "A0E" || fName == "A0K") {
                    try {
                        val prevVal = field.get(response)
                        if (prevVal != null) {
                            field.set(response, null)
                            println("[$TAG] cleanTimelineResponse: Neutralisé champ racine $fName (${prevVal.javaClass.simpleName})")
                        }
                    } catch (_: Throwable) {}
                }

                // 2. Filtrage des listes de posts et de cartes feed_items (A0U = feed_items, A0W = items)
                if (fName == "A0U" || fName == "A0W") {
                    try {
                        val list = field.get(response) as? List<*>
                        if (!list.isNullOrEmpty()) {
                            val filtered = filterFeedItems(list)
                            field.set(response, filtered)
                        }
                    } catch (_: Throwable) {}
                }
            }
            println("[$TAG] cleanTimelineResponse: Réponse de Timeline nettoyée avec succès")
            response
        } catch (t: Throwable) {
            logError("cleanTimelineResponse failed", t)
            response
        }
    }

    /**
     * Point d'injection Smali au retour de LX/01Od;->unsafeParseFromJson (classes3.dex) :
     * Nettoie la réponse des endpoints /feed/reels_media/ et /feed/injected_reels_media/
     * en purgeant tous les reels publicitaires injectés pendant la lecture des stories.
     */
    @JvmStatic
    fun cleanReelsMediaResponse(response: Any?): Any? {
        if (response == null) return response
        return try {
            val clazz = response.javaClass
            for (field in clazz.fields) {
                val fName = field.name
                // 1. Désactivation des métadonnées de publicité dans la réponse de reels_media
                if (fName == "A03" || fName == "A0C" || fName == "A0A" || fName == "A08") {
                    try {
                        field.set(response, null)
                        println("[$TAG] cleanReelsMediaResponse: Neutralisé métadonnée $fName")
                    } catch (_: Throwable) {}
                }

                // 2. Filtrage de la Map de reels (A0G: Map<String, ReelResponseItem>)
                if (fName == "A0G") {
                    try {
                        val map = field.get(response) as? MutableMap<*, *>
                        if (map != null && map.isNotEmpty()) {
                            val it = map.entries.iterator()
                            var removed = 0
                            while (it.hasNext()) {
                                val entry = it.next()
                                val reel = entry.value
                                if (reel != null && isStoryAd(reel)) {
                                    it.remove()
                                    removed++
                                }
                            }
                            if (removed > 0) {
                                println("[$TAG] cleanReelsMediaResponse: Éliminé $removed stories publicitaires de la map (Restants: ${map.size})")
                            }
                        }
                    } catch (_: Throwable) {}
                }
            }
            println("[$TAG] cleanReelsMediaResponse: Réponse de ReelsMedia traitée avec succès")
            response
        } catch (t: Throwable) {
            logError("cleanReelsMediaResponse failed", t)
            response
        }
    }

    /**
     * Point d'injection Smali dans LX/03af; et LX/01ZN; (List<08nf> ou List<Media>) :
     * Filtre la liste des feed_items pour éradiquer les publicités et suggestions.
     */
    @JvmStatic
    fun filterFeedItems(items: List<Any?>?): List<Any?>? {
        if (items.isNullOrEmpty()) return items
        return try {
            val result = ArrayList<Any?>()
            var adsCount = 0
            for (item in items) {
                if (item == null) continue
                if (isAdOrAlgorithmicItem(item)) {
                    adsCount++
                } else {
                    result.add(item)
                }
            }
            if (adsCount > 0) {
                totalTimelineAdsRemoved.addAndGet(adsCount)
                println("[$TAG] filterFeedItems: Éliminé $adsCount pubs/suggestions (Restants: ${result.size})")
            }
            result
        } catch (t: Throwable) {
            logError("filterFeedItems failed", t)
            items
        }
    }

    private fun isAdOrAlgorithmicItem(item: Any): Boolean {
        try {
            val clazz = item.javaClass

            // 0. Si l'item est lui-même un Media sponsorisé direct
            if (isMediaSponsored(item)) {
                println("[$TAG] Détecté media sponsorisé direct")
                return true
            }

            // 1. Vérification des méthodes A0J() et A0K() de 08nf :
            // A0J() vérifie IAASingleAdFormatInfo != null (Ad unique)
            // A0K() vérifie MultiAdPivot != null (Multi Ad)
            for (method in clazz.methods) {
                if (method.parameterCount == 0) {
                    try {
                        if (method.name == "A0J" || method.name == "A0K") {
                            val res = method.invoke(item)
                            if (res is Boolean && res) {
                                println("[$TAG] Détecté flag publicitaire via méthode ${method.name}()")
                                return true
                            }
                        }
                        // Détection du bloc suggested_users via A0B()
                        if (method.name == "A0B") {
                            val res = method.invoke(item)
                            if (res != null) {
                                println("[$TAG] Détecté bloc suggested_users via A0B()")
                                return true
                            }
                        }
                    } catch (_: Throwable) {}
                }
            }

            // 2. Vérification du type d'item via l'enum 04yb (dans 08nf : public 04yb A0s ou A08())
            for (field in clazz.fields) {
                try {
                    val fVal = field.get(item) ?: continue
                    if (fVal is Enum<*>) {
                        val enumName = fVal.name
                        if (enumName != "MEDIA") {
                            println("[$TAG] Détecté item non-organique (field ${field.name}): $enumName")
                            return true
                        }
                    }
                } catch (_: Throwable) {}
            }

            for (method in clazz.methods) {
                if (method.parameterCount == 0 && Enum::class.java.isAssignableFrom(method.returnType)) {
                    try {
                        val enumVal = method.invoke(item) as? Enum<*>
                        if (enumVal != null && enumVal.name != "MEDIA") {
                            println("[$TAG] Détecté item non-organique (method ${method.name}): ${enumVal.name}")
                            return true
                        }
                    } catch (_: Throwable) {}
                }
            }

            // 3. Vérification des composants de Netego / Ad / Threads connus sur 08nf :
            for (field in clazz.fields) {
                try {
                    val fVal = field.get(item) ?: continue
                    val typeName = fVal.javaClass.name.lowercase()
                    if (typeName.contains("netego") || typeName.contains("ad4ad") || typeName.contains("simpleaction") ||
                        typeName.contains("suggested") || typeName.contains("threads") || typeName.contains("immersive")) {
                        println("[$TAG] Détecté composant publicitaire/netego (${field.name}): $typeName")
                        return true
                    }
                } catch (_: Throwable) {}
            }

            // 4. Extraction et vérification exhaustive de tous les objets Media associés à l'item
            val mediaCandidates = ArrayList<Any>()
            for (field in clazz.fields) {
                try {
                    val fVal = field.get(item) ?: continue
                    val fClass = fVal.javaClass.name
                    if (fClass.contains("Media")) {
                        mediaCandidates.add(fVal)
                    } else {
                        // Support des wrappers comme LX/05D6 -> CfJ() : Media
                        try {
                            val cfj = fVal.javaClass.getMethod("CfJ")
                            val m = cfj.invoke(fVal)
                            if (m != null) mediaCandidates.add(m)
                        } catch (_: Throwable) {}
                    }
                } catch (_: Throwable) {}
            }
            for (method in clazz.methods) {
                if (method.parameterCount == 0 && (method.name.startsWith("A0") || method.name == "CfJ")) {
                    try {
                        val res = method.invoke(item) ?: continue
                        if (res.javaClass.name.contains("Media")) {
                            mediaCandidates.add(res)
                        }
                    } catch (_: Throwable) {}
                }
            }

            for (media in mediaCandidates) {
                if (isMediaSponsored(media)) {
                    println("[$TAG] Détecté media sponsorisé dans l'item (${media.javaClass.simpleName})")
                    return true
                }
            }
        } catch (t: Throwable) {
            logError("isAdOrAlgorithmicItem check error", t)
        }
        return false
    }

    private fun isMediaSponsored(media: Any): Boolean {
        try {
            val clazz = media.javaClass

            // Vérification exhaustive des méthodes de Media dans Instagram
            for (method in clazz.methods) {
                if (method.parameterCount == 0) {
                    val mname = method.name
                    try {
                        // 1. Tag publicitaire 'injected' (A3C() -> LX/0A08)
                        if (mname == "A3C") {
                            val res = method.invoke(media)
                            if (res != null) {
                                println("[$TAG] isMediaSponsored: Détecté tag 'injected' via A3C()")
                                return true
                            }
                        }

                        // 2. Bouton d'action publicitaire (A72() -> 'ad_action' : "Shop Now", "Install", etc.)
                        if (mname == "A72") {
                            val res = method.invoke(media)
                            if (res is String && res.isNotEmpty()) {
                                println("[$TAG] isMediaSponsored: Détecté 'ad_action' via A72(): $res")
                                return true
                            }
                        }

                        // 3. Carte de génération de leads / sponsor (A1l() -> lead_gen_card_info, A1t() -> offsite_lead_ads_info)
                        if (mname == "A1l" || mname == "A1t") {
                            val res = method.invoke(media)
                            if (res != null) {
                                println("[$TAG] isMediaSponsored: Détecté lead-gen via $mname()")
                                return true
                            }
                        }

                        // 4. Statut sponsorisé / promu / partenariat rémunéré
                        // A4p() -> is_currently_promoting_by_sponsor
                        // A5S() -> is_promoted
                        // A5M() -> is_paid_partnership
                        if (mname == "A4p" || mname == "A5S" || mname == "A5M") {
                            val res = method.invoke(media)
                            if (res is Boolean && res) {
                                println("[$TAG] isMediaSponsored: Détecté promu/sponsorisé via $mname()")
                                return true
                            }
                        }

                        // 5. Post sponsorisé / boosté
                        // A7B -> boosted_by_sponsor, A7C -> boosted_post_id, A7D -> boosted_status, A7O -> commercial_title
                        if (mname == "A7B" || mname == "A7C" || mname == "A7D" || mname == "A7O") {
                            val res = method.invoke(media)
                            if (res is String && res.isNotEmpty()) {
                                println("[$TAG] isMediaSponsored: Détecté post boosté/commercial via $mname(): $res")
                                return true
                            }
                        }

                        // 6. Liste des tags sponsorisés (A9d -> sponsor_tags, A8g -> ad_metadata)
                        if (mname == "A9d" || mname == "A8g") {
                            val tags = method.invoke(media) as? List<*>
                            if (!tags.isNullOrEmpty()) {
                                println("[$TAG] isMediaSponsored: Détecté liste sponsor/ad non-vide via $mname() (${tags.size} items)")
                                return true
                            }
                        }

                        // 7. Formats publicitaires IAA / Multi-Ad / CTM / Ad Tag / Stickers / Headlines
                        // A1U = IAASingleAdFormatInfo, A2G = MultiAdPivot
                        // A15 = ctm_ads_info, A1I = ad_tag, A0V = ad_disclaimer_info, A0W = ad_preview_config
                        // A1a = reels_ad_cta_sticker, A1b = story_ad_cta_sticker, A3H = story_ad_headline
                        // A6n = ad_created_time, A5v = ad_product_destination
                        if (mname == "A1U" || mname == "A2G" || mname == "A15" || mname == "A1I" ||
                            mname == "A0V" || mname == "A0W" || mname == "A1a" || mname == "A1b" ||
                            mname == "A3H" || mname == "A6n" || mname == "A5v") {
                            val adInfo = method.invoke(media)
                            if (adInfo != null) {
                                println("[$TAG] isMediaSponsored: Détecté format publicitaire via $mname()")
                                return true
                            }
                        }

                        // 8. Méthodes explicites isSponsored / isAd
                        if (mname.equals("isSponsored", ignoreCase = true) || mname.equals("isAd", ignoreCase = true)) {
                            val res = method.invoke(media)
                            if (res is Boolean && res) {
                                println("[$TAG] isMediaSponsored: Détecté via $mname() == true")
                                return true
                            }
                        }

                        // 9. Détection par type de retour explicite
                        val retName = method.returnType.name.lowercase()
                        if (retName.contains("iaasinglead") || retName.contains("adpreview") ||
                            retName.contains("ctm_ads") || retName.contains("igads") ||
                            retName.contains("multiad")) {
                            val res = method.invoke(media)
                            if (res != null) {
                                println("[$TAG] isMediaSponsored: Détecté via type de retour $retName (${method.name})")
                                return true
                            }
                        }
                    } catch (_: Throwable) {}
                }
            }

            // 10. Vérification des champs internes de type publicitaire
            for (field in clazz.fields) {
                try {
                    val fVal = field.get(media) ?: continue
                    if (fVal is Boolean || fVal is Number || fVal is String || fVal is Set<*>) continue
                    val typeName = fVal.javaClass.name.lowercase()
                    if (typeName.contains("iaasinglead") || typeName.contains("ad4ad") || typeName.contains("multiadpivot") || typeName.contains("igads")) {
                        println("[$TAG] isMediaSponsored: Détecté champ publicitaire $typeName")
                        return true
                    }
                } catch (_: Throwable) {}
            }
        } catch (_: Throwable) {}
        return false
    }

    /**
     * Détecte si un ReelResponseItem (Story) est une publicité ou une insertion algorithmique.
     */
    private fun isStoryAd(item: Any): Boolean {
        try {
            val clazz = item.javaClass

            // 1. Vérification des champs de ReelResponseItem par type d'objet (ou valeur mockée)
            for (field in clazz.fields) {
                val fVal = field.get(item) ?: continue
                if (fVal is Boolean || fVal is Number) continue

                val typeName = fVal.javaClass.name.lowercase()
                val strVal = (fVal as? String)?.lowercase() ?: ""
                if (typeName.contains("adpod") || typeName.contains("netego") ||
                    typeName.contains("survey") || typeName.contains("ad4ad") ||
                    typeName.contains("suggested") || typeName.contains("metaai") ||
                    typeName.contains("threadsinstories") || typeName.contains("intentawareads") ||
                    typeName.contains("igads") ||
                    strVal.contains("intent_ad") || strVal.contains("ad4ad")) {
                    println("[$TAG] isStoryAd: Détecté composant publicitaire/netego ($typeName / $strVal)")
                    return true
                }
            }

            // 2. Vérification si les items de la story sont des médias sponsorisés
            for (method in clazz.methods) {
                if (method.parameterCount == 0 && (method.name == "getItems" || method.name.equals("items", ignoreCase = true))) {
                    val mediaList = method.invoke(item) as? List<*>
                    if (!mediaList.isNullOrEmpty()) {
                        for (media in mediaList) {
                            if (media != null && isMediaSponsored(media)) {
                                println("[$TAG] isStoryAd: Contient un media sponsorisé")
                                return true
                            }
                        }
                    }
                }
            }
        } catch (t: Throwable) {
            logError("isStoryAd check failed", t)
        }
        return false
    }

    /**
     * Point d'injection Smali dans LX/04ln;->unsafeParseFromJson (classes.dex) :
     * Réordonne le tray des Stories selon PriorityStoryScorer (Favoris > Non vues > Vues)
     * et élimine les stories publicitaires / suggestions.
     */
    @JvmStatic
    fun filterStoriesTray(items: List<Any?>?): List<Any?>? {
        if (items.isNullOrEmpty()) return items
        return try {
            val result = ArrayList<Any?>()
            val favorites = ArrayList<Any?>()
            val others = ArrayList<Any?>()
            var adsCount = 0

            for (item in items) {
                if (item == null) continue
                // Élimination des suggestions et des publicités dans le tray des stories
                if (isSuggestedStory(item) || isStoryAd(item)) {
                    adsCount++
                    continue
                }

                val username = extractUsernameFromStory(item)
                if (username != null && favoriteUsernames.contains(username.lowercase())) {
                    favorites.add(item)
                } else {
                    others.add(item)
                }
            }

            result.addAll(favorites)
            result.addAll(others)

            totalStoriesProcessed.addAndGet(items.size)
            if (adsCount > 0) {
                println("[$TAG] filterStoriesTray: Éliminé $adsCount stories publicitaires/suggestions")
            }
            println("[$TAG] filterStoriesTray: Trié ${result.size} stories (Favoris: ${favorites.size})")
            result
        } catch (t: Throwable) {
            logError("filterStoriesTray failed", t)
            items
        }
    }

    private fun isSuggestedStory(item: Any): Boolean {
        try {
            for (method in item.javaClass.methods) {
                if (method.parameterCount == 0) {
                    val mName = method.name.lowercase()
                    val retName = method.returnType.name.lowercase()
                    if (retName.contains("suggested") || mName.contains("suggested")) {
                        val res = method.invoke(item)
                        if (res != null) return true
                    }
                }
            }
        } catch (_: Throwable) {}
        return false
    }

    private fun extractUsernameFromStory(item: Any): String? {
        try {
            // Dans ReelResponseItem : Dqt() returns User
            for (method in item.javaClass.methods) {
                if (method.parameterCount == 0 && method.name == "Dqt") {
                    val user = method.invoke(item)
                    if (user != null) {
                        for (uMethod in user.javaClass.methods) {
                            if (uMethod.parameterCount == 0 && uMethod.name.equals("getUsername", ignoreCase = true)) {
                                return uMethod.invoke(user) as? String
                            }
                        }
                    }
                }
            }
        } catch (_: Throwable) {}
        return null
    }

    /**
     * Point d'injection Smali pour la Timeline (JSON brut)
     */
    @JvmStatic
    fun filterTimeline(rawJson: String?): String? {
        if (rawJson.isNullOrBlank()) return rawJson

        return try {
            val result = filter.filterTimeline(rawJson)
            totalTimelineAdsRemoved.incrementAndGet()
            result
        } catch (t: Throwable) {
            logError("filterTimeline failed, returning untouched raw payload", t)
            rawJson
        }
    }

    @JvmStatic
    fun filterTimeline(rawBytes: ByteArray?): ByteArray? {
        if (rawBytes == null || rawBytes.isEmpty()) return rawBytes

        return try {
            val rawString = String(rawBytes, StandardCharsets.UTF_8)
            val filteredString = filterTimeline(rawString) ?: return rawBytes
            filteredString.toByteArray(StandardCharsets.UTF_8)
        } catch (t: Throwable) {
            logError("filterTimeline(bytes) failed", t)
            rawBytes
        }
    }

    @JvmStatic
    fun filterTimelineStream(inputStream: InputStream?): InputStream? {
        if (inputStream == null) return null

        return try {
            val bytes = inputStream.readBytes()
            val filteredBytes = filterTimeline(bytes) ?: bytes
            ByteArrayInputStream(filteredBytes)
        } catch (t: Throwable) {
            logError("filterTimelineStream failed", t)
            inputStream
        }
    }

    /**
     * Point d'injection Smali pour les Stories (JSON brut)
     */
    @JvmStatic
    fun filterStories(rawJson: String?): String? {
        if (rawJson.isNullOrBlank()) return rawJson

        return try {
            val result = filter.filterStories(rawJson)
            totalStoriesProcessed.incrementAndGet()
            result
        } catch (t: Throwable) {
            logError("filterStories failed, returning untouched raw payload", t)
            rawJson
        }
    }

    @JvmStatic
    fun filterStories(rawBytes: ByteArray?): ByteArray? {
        if (rawBytes == null || rawBytes.isEmpty()) return rawBytes

        return try {
            val rawString = String(rawBytes, StandardCharsets.UTF_8)
            val filteredString = filterStories(rawString) ?: return rawBytes
            filteredString.toByteArray(StandardCharsets.UTF_8)
        } catch (t: Throwable) {
            logError("filterStories(bytes) failed", t)
            rawBytes
        }
    }

    @JvmStatic
    fun filterStoriesStream(inputStream: InputStream?): InputStream? {
        if (inputStream == null) return null

        return try {
            val bytes = inputStream.readBytes()
            val filteredBytes = filterStories(bytes) ?: bytes
            ByteArrayInputStream(filteredBytes)
        } catch (t: Throwable) {
            logError("filterStoriesStream failed", t)
            inputStream
        }
    }

    // Gestion des Favoris
    @JvmStatic
    fun addFavorite(username: String) {
        val clean = username.trim().removePrefix("@").lowercase()
        if (clean.isNotBlank()) {
            favoriteUsernames.add(clean)
            filter = createFilterInstance()
        }
    }

    @JvmStatic
    fun removeFavorite(username: String) {
        val clean = username.trim().removePrefix("@").lowercase()
        if (clean.isNotBlank()) {
            favoriteUsernames.remove(clean)
            filter = createFilterInstance()
        }
    }

    @JvmStatic
    fun getFavorites(): Set<String> = favoriteUsernames.toSet()

    @JvmStatic
    fun getStats(): String {
        return "Timeline calls filtered: ${totalTimelineAdsRemoved.get()}, Stories processed: ${totalStoriesProcessed.get()}"
    }

    private fun logError(message: String, t: Throwable) {
        System.err.println("[$TAG] $message: ${t.javaClass.simpleName} - ${t.message}")
    }
}
