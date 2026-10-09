package local.wreckbox.player

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout

/** The only time a service's web page is on screen: signing in. Cookies are app-wide, so the hidden pages are signed in too. */
class LoginActivity : Activity() {
    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val service = Service.valueOf(intent.getStringExtra("service") ?: "YOUTUBE")
        val web = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            // Google refuses sign-in when a WebView claims to be desktop Chrome: sign in with the WebView's own
            // (mobile) identity. Spotify gets the desktop one, as its player does.
            if (service == Service.SPOTIFY) settings.userAgentString = WebEngine.userAgent()
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            webViewClient = object : WebViewClient() {
                // Signed in: done — close before the service's own player page loads here.
                override fun onPageFinished(view: WebView, url: String) {
                    if (signedIn(service)) {
                        CookieManager.getInstance().flush()
                        setResult(RESULT_OK)
                        finish()
                    }
                }
            }
            loadUrl(service.login)
        }
        val done = Button(this).apply {
            text = "Done"
            setOnClickListener {
                CookieManager.getInstance().flush()
                setResult(RESULT_OK)
                finish()
            }
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            addView(done)
            addView(web, LinearLayout.LayoutParams(-1, 0, 1f))
        })
    }

    companion object {
        /**
         * Signs out of one service: expires its cookies (Android has no "delete this site's cookies"), on every domain
         * its sign-in uses, then reloads nothing — the hidden page picks the change up on its next song.
         */
        fun signOut(s: Service) {
            val cm = CookieManager.getInstance()
            val sites = when (s) {
                Service.YOUTUBE -> listOf("youtube.com", "music.youtube.com", "www.youtube.com", "google.com", "accounts.google.com", "www.google.com")
                Service.SPOTIFY -> listOf("spotify.com", "open.spotify.com", "accounts.spotify.com", "www.spotify.com")
            }
            for (site in sites) {
                val url = "https://$site"
                val names = cm.getCookie(url)?.split(";")?.map { it.substringBefore('=').trim() }?.filter { it.isNotEmpty() } ?: continue
                for (n in names) {
                    val secure = "; Secure"
                    cm.setCookie(url, "$n=; Max-Age=0; Path=/$secure")
                    if (!n.startsWith("__Host-")) {
                        cm.setCookie(url, "$n=; Max-Age=0; Path=/; Domain=$site$secure")
                        cm.setCookie(url, "$n=; Max-Age=0; Path=/; Domain=.${site.split('.').takeLast(2).joinToString(".")}$secure")
                    }
                }
            }
            cm.flush()
        }

        /** Signed in = the service's session cookie is there. */
        fun signedIn(s: Service): Boolean {
            val c = CookieManager.getInstance().getCookie(s.origin) ?: return false
            return when (s) {
                Service.YOUTUBE -> c.contains("SAPISID=") || c.contains("__Secure-3PAPISID=")
                Service.SPOTIFY -> c.contains("sp_dc=")
            }
        }
    }
}
