package com.cj.glasses

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.content.Context
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** How a live session ended, and what CJ should do next. */
sealed class LiveEnd {
    data object Bye : LiveEnd()
    data object Stop : LiveEnd()
    data object Idle : LiveEnd()  // quiet for a while: the session closed, the conversation is still open
    data class Dictation(val session: String) : LiveEnd()
    data class Translate(val language: String) : LiveEnd()
    data class Task(val task: PhoneTask) : LiveEnd()
    data class Failed(val why: String) : LiveEnd()
}

/**
 * One real-time session with the brain (brain/app/live.py): the mic streams up, CJ's voice streams back and
 * stops the moment you talk over it. In interpreter mode, the other person's translation plays out loud from
 * the phone's speaker and yours in the glasses.
 */
class LiveSession(private val context: Context, private val stream: MicStream, private val status: (String) -> Unit) {
    private val events = Channel<JSONObject>(Channel.UNLIMITED)
    private val audio = Channel<ByteArray>(Channel.UNLIMITED)
    private val opened = CompletableDeferred<Boolean>()
    @Volatile private var playingUntil = 0L  // when the audio written so far will have finished playing
    @Volatile private var echo = 0.0  // how loud CJ's own voice comes back into the mic
    @Volatile private var out: AudioTrack? = null  // where CJ's voice plays now (glasses, or the phone's speaker)

    suspend fun run(mode: String, lead: List<ShortArray>?, language: String = ""): LiveEnd = coroutineScope {
        val pairing = Core.store.pairing() ?: return@coroutineScope LiveEnd.Failed("not paired")
        val url = pairing.url.trimEnd('/').replaceFirst("http", "ws") + "/ws/live"
        // The token goes in a header, not the address, so it stays out of the brain's request log.
        val request = Request.Builder().url(url).header("Authorization", "Bearer ${pairing.token}").build()
        val ws = CLIENT.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { opened.complete(true) }
            override fun onMessage(webSocket: WebSocket, text: String) { events.trySend(JSONObject(text)) }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { audio.trySend(bytes.toByteArray()) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                opened.complete(false)
                events.trySend(JSONObject().put("type", "error").put("text", t.message ?: "connection lost"))
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                events.trySend(JSONObject().put("type", "closed"))
            }
        })
        if (!opened.await()) return@coroutineScope LiveEnd.Failed("couldn't reach the brain")
        val history = JSONArray().apply { Core.log.takeLast(8).forEach { put(JSONObject().put("role", it.role).put("text", it.text)) } }
        ws.send(JSONObject().put("type", "start").put("mode", mode).put("history", history).put("language", language)
            .put("user_language", "English").apply {
                Core.place()?.let { put("location", JSONObject().put("lat", it.lat).put("lon", it.lon)) }
            }.toString())

        val glasses = track(Core.speaker.attributes, speaker = false)
        var loud = if (mode == "interpreter") track(PARTNER, speaker = true) else null
        var loudChecked = false
        out = glasses
        var result: LiveEnd? = null
        var lastActivity = System.currentTimeMillis()
        val heard = StringBuilder()
        var nextStep: LiveEnd? = null

        val uplink = launch(Dispatchers.Default) {
            lead?.forEach { ws.send(MicStream.toBytes(it).toByteString()) }
            while (isActive) {
                val frame = stream.frames.receive()
                val level = MicStream.rms(frame)
                val speaking = System.currentTimeMillis() < playingUntil
                // While CJ talks, only clearly louder speech goes up (you interrupting), not CJ's own voice.
                val send = !speaking || level > maxOf(echo * 2.5, stream.noiseFloor * 5, 600.0)
                // Learn the echo only from what was held back: learning from your interruption would raise the bar
                // the longer you talk over CJ.
                if (speaking && !send) echo = 0.9 * echo + 0.1 * level
                ws.send(MicStream.toBytes(if (send) frame else ShortArray(frame.size)).toByteString())
            }
        }
        val player = launch(Dispatchers.IO) {
            for (pcm in audio) {
                val now = System.currentTimeMillis()
                playingUntil = maxOf(playingUntil, now) + pcm.size / 2 * 1000L / OUT_RATE
                out?.write(pcm, 0, pcm.size)
            }
        }
        status(if (mode == "interpreter") "Translating… say \"stop translating\"" else "Listening… just talk, say \"bye\" to finish")
        try {
            while (result == null) {
                val e = withTimeoutOrNull(1_000) { events.receive() }
                val now = System.currentTimeMillis()
                if (e == null) {
                    if (mode == "assistant" && now - lastActivity > IDLE_MS && now > playingUntil) result = LiveEnd.Idle
                    continue
                }
                when (e.optString("type")) {
                    "heard" -> { heard.append(e.optString("text")); lastActivity = now }
                    "said" -> lastActivity = now
                    "interrupted" -> {
                        out?.run { pause(); flush(); play() }
                        while (audio.tryReceive().isSuccess) Unit
                        playingUntil = 0
                    }
                    "route" -> {
                        out = if (e.optString("to") == "partner" && loud != null) loud else glasses
                        if (out === loud && !loudChecked) launch {
                            // While the glasses hold the call audio, some phones still send media to them. Check
                            // where the other person's translation really plays; if not the loudspeaker, use the
                            // alarm route, which Android always plays out loud.
                            delay(400)
                            loudChecked = true
                            val routed = loud?.routedDevice?.type
                            if (routed != null && routed != AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
                                Log.i(TAG, "translation went to device type $routed, switching to the alarm route")
                                val old = loud
                                loud = track(OUT_LOUD, speaker = true)
                                if (out === old) out = loud
                                old?.release()
                            }
                        }
                    }
                    "need_photo" -> launch { ws.send(JSONObject().put("type", "photo").put("image_b64", photo()).toString()) }
                    "phone" -> when (e.optString("action")) {
                        "call_number" -> Core.pendingCall = e.optString("number").takeIf { it.isNotBlank() }
                        "timer" -> Core.startTimer(Timer(e.optInt("seconds"), e.optString("label")))
                        "visual_memory" -> Core.store.visualMemory = e.optBoolean("on")
                        "dictation" -> nextStep = LiveEnd.Dictation(e.optString("session"))
                        "translate" -> nextStep = LiveEnd.Translate(e.optString("language"))
                        "phone_task" -> nextStep = LiveEnd.Task(PhoneTask(e.optString("goal"), e.optString("package"),
                            e.optString("link"), e.optString("app")))
                    }
                    "turn_done" -> {
                        lastActivity = now
                        val said = e.optString("heard").ifBlank { heard.toString() }.trim()
                        heard.clear()
                        if (mode == "assistant") {
                            if (said.isNotBlank()) Core.log.add(Turn("user", said))
                            e.optString("said").takeIf { it.isNotBlank() }?.let { Core.log.add(Turn("assistant", it)) }
                            when {
                                wantsStop(said) -> result = LiveEnd.Stop
                                wantsBye(said) -> result = LiveEnd.Bye
                                Core.pendingCall != null -> result = LiveEnd.Bye  // the call takes the audio
                            }
                        } else if (Regex("(?i)stop translat").containsMatchIn(said)) {
                            result = LiveEnd.Bye
                        }
                    }
                    "end" -> result = nextStep ?: LiveEnd.Bye
                    "error" -> result = LiveEnd.Failed(e.optString("text"))
                    "closed" -> result = nextStep ?: LiveEnd.Failed("the brain closed the session")
                }
            }
            // Let the last words finish before closing (a goodbye, "I'm taking notes").
            val left = playingUntil - System.currentTimeMillis()
            if (left > 0 && result !is LiveEnd.Failed) delay(minOf(left + 200, 8_000))
        } finally {
            uplink.cancel()
            player.cancel()
            runCatching { ws.send(JSONObject().put("type", "end").toString()) }
            ws.close(1000, null)
            glasses.release()
            loud?.release()
            stream.drain()
        }
        result!!
    }

    /** A photo for "what is this" / "add this to my calendar", or "" when the glasses can't take one. */
    private suspend fun photo(): String = runCatching {
        if (!Core.glassesLinked() || !Core.glasses.hasCameraPermission()) return ""
        status("Looking through your glasses…")
        Core.glasses.takePhoto().also { Core.photo = it }.jpegBase64
    }.getOrDefault("")

    private fun track(attributes: AudioAttributes, speaker: Boolean): AudioTrack {
        val format = AudioFormat.Builder().setSampleRate(OUT_RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
        val size = AudioTrack.getMinBufferSize(OUT_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT) * 4
        return AudioTrack.Builder().setAudioAttributes(attributes).setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(size).build().apply {
                if (speaker) {
                    context.getSystemService(AudioManager::class.java).getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                        .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }?.let { preferredDevice = it }
                }
                play()
            }
    }

    companion object {
        private const val OUT_RATE = 24000
        private const val IDLE_MS = 90_000L  // quiet this long: close the session until you speak again
        private val CLIENT = OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).pingInterval(20, TimeUnit.SECONDS).build()
        private const val TAG = "LiveSession"
        /** Fallback for phones that send media to the glasses during a call: alarms always play out loud. */
        private val OUT_LOUD = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        /** The other person hears your translation out loud from the phone. */
        private val PARTNER = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    }
}
