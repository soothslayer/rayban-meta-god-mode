package com.cj.glasses

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioTrack
import java.nio.ByteBuffer
import java.nio.ByteOrder
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume

/** Speaks CJ's replies. Devanagari text uses a Hindi voice, everything else an Indian English voice. */
class Speaker(context: Context) {
    @Volatile private var ready = false
    private val tts: TextToSpeech = TextToSpeech(context) { status -> ready = status == TextToSpeech.SUCCESS }
    private val finished = ConcurrentHashMap<String, () -> Unit>()

    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) { finished.remove(utteranceId)?.invoke() }
            override fun onStop(utteranceId: String?, interrupted: Boolean) { finished.remove(utteranceId)?.invoke() }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) { finished.remove(utteranceId)?.invoke() }
        })
    }

    /**
     * Hands-free keeps the glasses on their call link the whole time, so replies must play as call audio
     * too; switching to music audio mid-conversation makes the glasses drop and rebuild the connection.
     */
    fun setVoiceCall(on: Boolean) {
        voiceCall = on
        attributes = AudioAttributes.Builder()
            .setUsage(if (on) AudioAttributes.USAGE_VOICE_COMMUNICATION else AudioAttributes.USAGE_ASSISTANT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        tts.setAudioAttributes(attributes)
    }

    var attributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANT).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        private set
    var voiceCall = false
        private set

    /** Plays a WAV (CJ's Azure voice from the brain) and returns when it has finished. */
    suspend fun play(wav: ByteArray) {
        val buf = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        if (wav.size < 44) return
        val rate = buf.getInt(24)
        var at = 12
        while (at + 8 <= wav.size && String(wav, at, 4) != "data") at += 8 + buf.getInt(at + 4)
        if (at + 8 > wav.size) return
        val pcm = wav.copyOfRange(at + 8, minOf(wav.size, at + 8 + buf.getInt(at + 4)))
        val track = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(pcm.size)
            .build()
        try {
            track.write(pcm, 0, pcm.size)
            track.play()
            delay(pcm.size / 2 * 1000L / rate + 150)
        } finally {
            track.stop()
            track.release()
        }
    }

    fun speak(text: String, id: String = "cj-reply") {
        if (!ready || text.isBlank()) return
        val hindi = text.any { it in 'ऀ'..'ॿ' }
        tts.language = if (hindi) Locale("hi", "IN") else Locale("en", "IN")
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
    }

    /** Speaks and returns once the sentence has finished playing. */
    suspend fun say(text: String) {
        if (text.isBlank()) return
        withTimeoutOrNull(3_000) { while (!ready) delay(100) } ?: return  // TTS engine still starting
        val id = UUID.randomUUID().toString()
        suspendCancellableCoroutine { cont ->
            finished[id] = { if (cont.isActive) cont.resume(Unit) }
            cont.invokeOnCancellation { finished.remove(id); tts.stop() }
            speak(text, id)
        }
    }

    fun stop() {
        tts.stop()
    }

    fun shutdown() {
        tts.shutdown()
    }
}

/**
 * The glasses' microphone is a Bluetooth headset mic (SCO). While CJ listens it becomes the phone's
 * communication device; afterwards the route is released so replies play through the glasses as media.
 */
class GlassesMic(context: Context) {
    private val audio = context.getSystemService(AudioManager::class.java)

    private fun headset(): AudioDeviceInfo? =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) null
        else audio.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }

    fun connected(): Boolean = headset() != null

    /** Another app (Spotify, YouTube…) is playing music or video right now. */
    fun musicPlaying(): Boolean = audio.isMusicActive

    /** True while the phone's call audio actually goes to the glasses. Android can drop this on its own. */
    fun routed(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            audio.communicationDevice?.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO

    /** The glasses as a recording input, for AudioRecord.setPreferredDevice. */
    fun inputDevice(): AudioDeviceInfo? =
        audio.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }

    /** Returns true when listening now goes through the glasses. */
    fun route(): Boolean {
        val device = headset() ?: return false
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        return audio.setCommunicationDevice(device)
    }

    fun release() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audio.clearCommunicationDevice()
        audio.mode = AudioManager.MODE_NORMAL
    }
}

/** Speech input: the glasses' mic when they're connected over Bluetooth, otherwise the phone's. */
class Listener(val context: Context) {
    private var recognizer: SpeechRecognizer? = null
    private val mic = GlassesMic(context)

    fun usingGlasses(): Boolean = mic.connected()

    fun start(onText: (String) -> Unit, fail: (String) -> Unit) {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            fail("Speech recognition isn't available on this phone.")
            return
        }
        stop()
        mic.route()
        val r = SpeechRecognizer.createSpeechRecognizer(context)
        recognizer = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                mic.release()
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                if (text.isNullOrBlank()) fail("I didn't catch that.") else onText(text)
            }

            override fun onError(error: Int) {
                mic.release()
                fail(when (error) {
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "I didn't hear anything."
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is off for CJ."
                    SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech recognition needs internet."
                    else -> "Speech recognition failed (code $error)."
                })
            }

            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            // English first: with Hindi first, English speech came back written in Devanagari.
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-IN")
            putStringArrayListExtra("android.speech.extra.ADDITIONAL_LANGUAGES", arrayListOf("hi-IN"))
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        })
    }

    /** One question: the recognised text, or null if nothing was said. Call on the main thread. */
    suspend fun listenOnce(): String? = suspendCancellableCoroutine { cont ->
        start({ if (cont.isActive) cont.resume(it) }, { if (cont.isActive) cont.resume(null) })
        cont.invokeOnCancellation { mainHandler.post { stop() } }
    }

    fun stop() {
        recognizer?.destroy()
        recognizer = null
        mic.release()
    }

    private val mainHandler = Handler(Looper.getMainLooper())
}
