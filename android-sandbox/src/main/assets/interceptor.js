// InstaController - Advanced In-Flight Network Interceptor for Instagram Web & Mobile
(function() {
    if (window.__INSTACONTROLLER_INJECTED__) {
        return;
    }
    window.__INSTACONTROLLER_INJECTED__ = true;
    console.log("[InstaController] Advanced Network Interceptor active");

    // 1. Masquage CSS d'urgence pour tout conteneur résiduel et bannières native app
    function injectEmergencyStyles() {
        if (document.getElementById("instacontroller-styles")) return;
        const style = document.createElement("style");
        style.id = "instacontroller-styles";
        style.textContent = `
            /* Bannières et incitations à l'application native */
            [data-testid="app-upsell-modal"],
            .app-upsell,
            a[href^="intent:"],
            a[href^="instagram:"],
            a[href^="market:"],
            div[role="dialog"]:has(button:has(svg)),
            
            /* Masquage de secours des éléments avec badge sponsorisé */
            article:has(a[href*="/about/ads"]),
            article:has(span:contains("Sponsored")),
            article:has(span:contains("Sponsorisé")),
            article:has(span:contains("Commandité")),
            div:has(> a[href*="/about/ads"]) {
                display: none !important;
            }
        `;
        (document.head || document.documentElement).appendChild(style);
    }
    injectEmergencyStyles();
    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", injectEmergencyStyles);
    }

    // 2. Blocage des navigations directes vers les schémas d'application native
    document.addEventListener("click", function(e) {
        const anchor = e.target.closest ? e.target.closest("a") : null;
        if (anchor && anchor.href) {
            const href = anchor.href.toLowerCase();
            if (href.startsWith("intent:") || href.startsWith("instagram:") || href.startsWith("market:")) {
                console.log("[InstaController] Blocked click navigation to scheme:", anchor.href);
                e.preventDefault();
                e.stopPropagation();
            }
        }
    }, true);

    // Fonction d'analyse et de nettoyage de charge utile
    function processPayloadIfApplicable(url, rawText) {
        if (!window.InstaBridge || !rawText || typeof rawText !== "string") {
            return rawText;
        }

        const isStoriesEndpoint = url.includes("reels_tray") || url.includes("stories") ||
            (rawText.includes('"tray":') && !rawText.includes('"feed_items":'));

        const isTimelineOrAds = url.includes("timeline") || url.includes("feed") ||
            rawText.includes('"feed_items"') || rawText.includes('"is_sponsored"') ||
            rawText.includes('"suggested_users"') || rawText.includes('"netego_type"');

        if (isStoriesEndpoint) {
            try {
                return window.InstaBridge.processStoriesJson(rawText);
            } catch (err) {
                console.error("[InstaController] Error in processStoriesJson:", err);
                return rawText;
            }
        } else if (isTimelineOrAds) {
            try {
                return window.InstaBridge.processTimelineJson(rawText);
            } catch (err) {
                console.error("[InstaController] Error in processTimelineJson:", err);
                return rawText;
            }
        }

        return rawText;
    }

    // 3. Interception robuste de window.fetch
    if (window.fetch) {
        const originalFetch = window.fetch;
        window.fetch = async function(...args) {
            const requestInfo = args[0];
            const url = typeof requestInfo === "string" ? requestInfo : (requestInfo && requestInfo.url ? requestInfo.url : "");

            const response = await originalFetch.apply(this, args);

            // Filtrage uniquement si réponse HTTP valide
            if (response && response.ok) {
                try {
                    const clonedResponse = response.clone();
                    const rawText = await clonedResponse.text();

                    // Vérification si le contenu contient des structures Instagram cibles
                    if (rawText.length > 5 && (
                        url.includes("timeline") ||
                        url.includes("reels_tray") ||
                        url.includes("graphql") ||
                        url.includes("feed") ||
                        rawText.includes('"feed_items"') ||
                        rawText.includes('"is_sponsored"') ||
                        rawText.includes('"tray"')
                    )) {
                        const cleanedText = processPayloadIfApplicable(url, rawText);

                        // Si le payload a été modifié, on forge une nouvelle Response enrichie
                        if (cleanedText !== rawText) {
                            const newHeaders = new Headers(response.headers);
                            newHeaders.delete("content-length"); // Évite les incohérences de taille

                            const modifiedResponse = new Response(cleanedText, {
                                status: response.status,
                                statusText: response.statusText,
                                headers: newHeaders
                            });

                            // Surcharge de sécurité pour text() et json()
                            modifiedResponse.json = async () => JSON.parse(cleanedText);
                            modifiedResponse.text = async () => cleanedText;

                            return modifiedResponse;
                        }
                    }
                } catch (err) {
                    console.error("[InstaController] Error in fetch response handler:", err);
                }
            }

            return response;
        };
    }

    // 4. Interception robuste de XMLHttpRequest (XHR)
    const originalXHROpen = XMLHttpRequest.prototype.open;
    const originalXHRSend = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function(method, url) {
        this.__instacontroller_url = typeof url === "string" ? url : (url ? url.toString() : "");
        return originalXHROpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function() {
        const xhr = this;
        const url = xhr.__instacontroller_url || "";

        xhr.addEventListener("readystatechange", function() {
            if (xhr.readyState === 4 && xhr.status === 200 && window.InstaBridge) {
                try {
                    const rawText = xhr.responseText;
                    if (rawText && rawText.length > 5) {
                        const processedText = processPayloadIfApplicable(url, rawText);

                        if (processedText !== rawText) {
                            Object.defineProperty(xhr, "responseText", {
                                get: function() { return processedText; },
                                configurable: true
                            });

                            Object.defineProperty(xhr, "response", {
                                get: function() {
                                    if (xhr.responseType === "" || xhr.responseType === "text") {
                                        return processedText;
                                    }
                                    if (xhr.responseType === "json") {
                                        try { return JSON.parse(processedText); } catch(e) { return processedText; }
                                    }
                                    return processedText;
                                },
                                configurable: true
                            });
                        }
                    }
                } catch (e) {
                    console.error("[InstaController] Error modifying XHR response:", e);
                }
            }
        }, false);

        return originalXHRSend.apply(this, arguments);
    };

    console.log("[InstaController] Interceptor hooks active on all traffic");
})();
