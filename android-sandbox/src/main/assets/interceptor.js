// InstaController - In-Flight Network Interceptor for Instagram Web / Mobile
(function() {
    if (window.__INSTACONTROLLER_INJECTED__) {
        return;
    }
    window.__INSTACONTROLLER_INJECTED__ = true;
    console.log("[InstaController] Interceptor initialized");

    // 1. Masquage CSS d'urgence pour tout conteneur résiduel
    function injectEmergencyStyles() {
        if (document.getElementById("instacontroller-styles")) return;
        const style = document.createElement("style");
        style.id = "instacontroller-styles";
        style.textContent = `
            /* Masquage des bannières d'installation de l'application native */
            [data-testid="app-upsell-modal"],
            div[role="dialog"] button:has(svg),
            .app-upsell,
            /* Masquage de secours des éléments avec badge sponsorisé */
            article:has(a[href*="/about/ads"]),
            article:has(span:contains("Sponsored")),
            article:has(span:contains("Sponsorisé")),
            article:has(span:contains("Commandité")) {
                display: none !important;
            }
        `;
        (document.head || document.documentElement).appendChild(style);
    }
    injectEmergencyStyles();
    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", injectEmergencyStyles);
    }

    // 2. Interception de window.fetch
    if (window.fetch) {
        const originalFetch = window.fetch;
        window.fetch = async function(...args) {
            const url = typeof args[0] === "string" ? args[0] : (args[0] && args[0].url ? args[0].url : "");
            const response = await originalFetch.apply(this, args);

            try {
                if (window.InstaBridge && response && response.ok) {
                    if (url.includes("/api/v1/feed/timeline/") || url.includes("/feed/timeline")) {
                        const rawText = await response.text();
                        const cleanedText = window.InstaBridge.processTimelineJson(rawText);
                        return new Response(cleanedText, {
                            status: response.status,
                            statusText: response.statusText,
                            headers: response.headers
                        });
                    } else if (url.includes("/api/v1/feed/reels_tray/") || url.includes("/feed/reels_tray")) {
                        const rawText = await response.text();
                        const sortedText = window.InstaBridge.processStoriesJson(rawText);
                        return new Response(sortedText, {
                            status: response.status,
                            statusText: response.statusText,
                            headers: response.headers
                        });
                    } else if (url.includes("/graphql/query")) {
                        // Instagram Web utilise parfois GraphQL pour le feed
                        const rawText = await response.text();
                        if (rawText.includes("feed_items") || rawText.includes("is_sponsored")) {
                            const cleanedText = window.InstaBridge.processTimelineJson(rawText);
                            return new Response(cleanedText, {
                                status: response.status,
                                statusText: response.statusText,
                                headers: response.headers
                            });
                        }
                        return new Response(rawText, {
                            status: response.status,
                            statusText: response.statusText,
                            headers: response.headers
                        });
                    }
                }
            } catch (err) {
                console.error("[InstaController] Error intercepting fetch response:", err);
            }

            return response;
        };
    }

    // 3. Interception de XMLHttpRequest (XHR)
    const originalXHROpen = XMLHttpRequest.prototype.open;
    const originalXHRSend = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function(method, url) {
        this.__instacontroller_url = url;
        return originalXHROpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function() {
        const xhr = this;
        const url = xhr.__instacontroller_url || "";

        if (url.includes("/api/v1/feed/timeline/") ||
            url.includes("/api/v1/feed/reels_tray/") ||
            url.includes("/graphql/query")) {

            xhr.addEventListener("readystatechange", function() {
                if (xhr.readyState === 4 && xhr.status === 200 && window.InstaBridge) {
                    try {
                        const rawText = xhr.responseText;
                        let processedText = rawText;

                        if (url.includes("timeline")) {
                            processedText = window.InstaBridge.processTimelineJson(rawText);
                        } else if (url.includes("reels_tray")) {
                            processedText = window.InstaBridge.processStoriesJson(rawText);
                        } else if (url.includes("graphql") && (rawText.includes("feed_items") || rawText.includes("is_sponsored"))) {
                            processedText = window.InstaBridge.processTimelineJson(rawText);
                        }

                        // Surcharge des accesseurs de réponse
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
                    } catch (e) {
                        console.error("[InstaController] Error modifying XHR response:", e);
                    }
                }
            }, false);
        }

        return originalXHRSend.apply(this, arguments);
    };

    console.log("[InstaController] Interceptor hooks active on fetch and XHR");
})();
