package com.cj.glasses

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.Permission
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/** What the UI needs from the activity: glasses setup and the hands-free switch. */
interface GlassesControls {
    /** Opens the Meta AI app so the user can link CJ to their glasses. */
    fun register()
    fun unregister()
    /** Opens the Meta AI app on the screen that updates the glasses-side app CJ talks to. */
    fun updateGlassesApp()
    /** Asks for glasses camera access through the Meta AI app. True when granted. */
    suspend fun requestCamera(): Boolean
    /** Starts or stops hands-free "CJ" (asks for the microphone first). */
    fun setHandsFree(on: Boolean)
}

class MainActivity : ComponentActivity(), GlassesControls {
    private var micResult: ((Boolean) -> Unit)? = null
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        micResult?.invoke(granted)
        micResult = null
    }
    private val startupPermissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result[Manifest.permission.BLUETOOTH_CONNECT] != false) Core.glasses.initialize()
    }
    private var cameraResult: CancellableContinuation<Boolean>? = null
    private val glassesCameraPermission = registerForActivityResult(Wearables.RequestPermissionContract()) { result ->
        cameraResult?.resume(result.getOrDefault(PermissionStatus.Denied) == PermissionStatus.Granted)
        cameraResult = null
    }
    private lateinit var listener: Listener

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Core.init(this)
        listener = Listener(this)
        askStartupPermissions()
        setContent { CJTheme { CJApp(Core.store, Core.speaker, listener, Core.glasses, this, ::withMic) } }
    }

    override fun onResume() {
        super.onResume()
        Core.place()  // remember where you are while CJ is open; the background service may not be told
    }

    /** Bluetooth for the glasses SDK (Android 12+), notifications for hands-free (Android 13+), and location for travel times. */
    private fun askStartupPermissions() {
        val wanted = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(Manifest.permission.BLUETOOTH_CONNECT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
            add(Manifest.permission.ACCESS_FINE_LOCATION)  // for "how long to reach…"
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            add(Manifest.permission.CALL_PHONE)  // "call this number", after you say yes
        }.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (wanted.isEmpty()) Core.glasses.initialize() else startupPermissions.launch(wanted.toTypedArray())
    }

    override fun register() = Wearables.startRegistration(this)

    override fun unregister() {
        Core.glasses.disconnect()
        Wearables.startUnregistration(this)
    }

    override fun updateGlassesApp() {
        Wearables.openDATGlassesAppUpdate(this).onFailure { _, _ -> Wearables.openFirmwareUpdate(this) }
    }

    override suspend fun requestCamera(): Boolean = suspendCancellableCoroutine { continuation ->
        cameraResult = continuation
        continuation.invokeOnCancellation { cameraResult = null }
        glassesCameraPermission.launch(Permission.CAMERA)
    }

    override fun setHandsFree(on: Boolean) {
        if (!on) return CJService.stop(this)
        withMic { granted -> if (granted) CJService.start(this) }
    }

    /** Runs [onResult] with true once the microphone permission is granted, asking first if needed. */
    private fun withMic(onResult: (Boolean) -> Unit) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            onResult(true)
        } else {
            micResult = onResult
            micPermission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    override fun onDestroy() {
        listener.stop()
        // The speaker and glasses link stay alive in Core while hands-free CJ runs in the background.
        if (!Core.handsFree) Core.glasses.disconnect()
        super.onDestroy()
    }
}
