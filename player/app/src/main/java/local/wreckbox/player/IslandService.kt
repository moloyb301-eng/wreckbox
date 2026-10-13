package local.wreckbox.player

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import androidx.media3.common.util.UnstableApi

/**
 * Hosts the island's window (Island.kt). An accessibility service only because its overlay windows are the ones that
 * sit above the status bar; it reads no screen content and ignores every event.
 */
@UnstableApi
class IslandService : AccessibilityService() {
    override fun onServiceConnected() {
        Island.landscape.value = resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
        Island.host.value = this
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        Island.landscape.value = newConfig.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}
    override fun onUnbind(intent: android.content.Intent?): Boolean { if (Island.host.value === this) Island.host.value = null; return super.onUnbind(intent) }
    override fun onDestroy() { if (Island.host.value === this) Island.host.value = null; super.onDestroy() }
}
