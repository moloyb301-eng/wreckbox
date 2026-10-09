# The page talks to the app through this bridge (WebView JavaScript interface).
-keepclassmembers class local.wreckbox.player.WebEngine$Bridge { @android.webkit.JavascriptInterface <methods>; }
