package com.cj.glasses

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.IBinder
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.selects.select

/**
 * Hands-free CJ. Runs in the background with the screen off:
 * listen for "CJ" -> beep -> record the question -> the brain transcribes it and, for "what is this"
 * questions, CJ takes a photo with the glasses -> answer in the ear -> up to two follow-ups without the wake
 * word -> back to waiting.
 *
 * The glasses stay on their Bluetooth call link for the whole session and one mic stream feeds both the wake
 * word and recording, so nothing switches audio mid-conversation.
 */
class CJService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var mic: GlassesMic
    private lateinit var stream: MicStream
    private lateinit var wake: WakeWord
    private var loop: Job? = null
    private var streamJob: Job? = null
    @Volatile private var conversing = false
    @Volatile private var pausedForMusic = false
    @Volatile private var liveOffUntil = 0L
    private var focus: AudioFocusRequest? = null
    private val talkNow = Channel<Unit>(Channel.CONFLATED)
    private val beep by lazy { ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Core.init(this)
        mic = GlassesMic(this)
        stream = MicStream(mic)
        wake = WakeWord(this)
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "CJ hands-free", NotificationManager.IMPORTANCE_LOW))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = notification("Starting…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Location too when allowed, so nudges ("you're near the supermarket") work with the screen off.
            val located = checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                (if (located) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0))
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (intent?.action == ACTION_TALK) talkNow.trySend(Unit)
        if (loop == null) loop = scope.launch { run() }
        running = true
        Core.handsFree = true
        // Not sticky: Android only lets a service use the mic if it was started while you were using CJ.
        return START_NOT_STICKY
    }

    private suspend fun run() {
        Core.glasses.initialize()
        Core.speaker.setVoiceCall(true)
        if (mic.musicPlaying()) pausedForMusic = true else listenOnGlasses()
        scope.launch { watchAudio() }
        scope.launch { announceFinishedJobs() }
        scope.launch { watchPlace() }
        scope.launch { visualMemory() }
        while (scope.isActive) {
            setStatus(idleStatus())
            stream.drain()
            if (!waitForWakeOrTap()) continue
            converse()
        }
    }

    /**
     * Claude Code jobs run on the Mac for minutes. Every 10 s, ask the brain which ones finished and read each
     * summary into the user's ear (waiting until any conversation is over, pausing music briefly if needed).
     */
    private suspend fun announceFinishedJobs() {
        while (scope.isActive) {
            delay(10_000)
            if (conversing) continue
            val jobs = runCatching { Core.brain()?.finishedJobs() }.getOrNull().orEmpty()
            for (job in jobs) {
                val text = "Claude Code ${if (job.ok) "finished" else "stopped"} in ${job.project}. ${job.summary}"
                Core.log.add(Turn("assistant", text))
                conversing = true
                try {
                    if (pausedForMusic) holdMusic(true)
                    val voice = runCatching { Core.brain()?.voiceFor(text) }.getOrNull()
                    if (voice != null) Core.speaker.play(voice) else Core.speaker.say(text)
                } finally {
                    if (pausedForMusic) holdMusic(false)
                    stream.drain()
                    conversing = false
                }
            }
        }
    }

    /**
     * Location nudges: every minute or so, tell the brain where you are. When it has something useful ("you're near
     * More Supermarket, you noted: buy milk"), say it, pausing music if needed. Some nudges ask a question
     * ("heading out? switch off the lights?"), so CJ then listens like after "CJ".
     */
    @android.annotation.SuppressLint("MissingPermission")
    private suspend fun watchPlace() {
        val lm = getSystemService(android.location.LocationManager::class.java) ?: return
        val located = checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!located) return
        val listener = android.location.LocationListener {
            Core.lastPlace = Place(it.latitude, it.longitude, if (it.hasAccuracy()) it.accuracy else null)
        }
        // Fused (Android 12+): GPS-level accuracy for home and office without keeping GPS on. Network location
        // alone is often 500 m off, which can't tell home from the street.
        val fine = checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        val provider = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && fine &&
                lm.hasProvider(android.location.LocationManager.FUSED_PROVIDER) -> android.location.LocationManager.FUSED_PROVIDER
            fine && lm.isProviderEnabled(android.location.LocationManager.GPS_PROVIDER) &&
                !lm.isProviderEnabled(android.location.LocationManager.NETWORK_PROVIDER) -> android.location.LocationManager.GPS_PROVIDER
            else -> android.location.LocationManager.NETWORK_PROVIDER
        }
        Log.i(TAG, "location from $provider")
        runCatching { lm.requestLocationUpdates(provider, 45_000L, 30f, listener, mainLooper) }
        try {
            var lastSent: Place? = null
            while (scope.isActive) {
                delay(60_000)
                val here = Core.place() ?: continue
                if (conversing || here == lastSent) continue
                lastSent = here
                val brain = Core.brain() ?: continue
                val (text, voice) = runCatching { brain.nudge(here) }.getOrNull() ?: continue
                if (conversing) continue
                conversing = true
                val duringMusic = pausedForMusic
                try {
                    if (duringMusic) holdMusic(true)
                    Core.log.add(Turn("assistant", text))
                    if (voice != null) Core.speaker.play(voice) else Core.speaker.say(text)
                    stream.drain()
                    if (brain.lastNudgeAsks) {
                        if (duringMusic) listenOnGlasses()
                        talk()
                    }
                } finally {
                    if (duringMusic) {
                        if (brain.lastNudgeAsks) { streamJob?.cancel(); mic.release() }
                        holdMusic(false)
                    }
                    conversing = false
                }
            }
        } finally {
            lm.removeUpdates(listener)
        }
    }

    /**
     * Visual memory (opt-in, Setup tab or "start visual memory"): a photo from the glasses every 5 minutes while
     * hands-free runs. The brain keeps a one-line note ("at Blue Tokai café, keys on the table") and drops the photo,
     * so "what was that café I walked past?" has an answer. Skipped during conversations and music.
     */
    private suspend fun visualMemory() {
        while (scope.isActive) {
            delay(GLANCE_EVERY_MS)
            if (!Core.store.visualMemory || conversing || pausedForMusic || !Core.glassesLinked()) continue
            if (!Core.glasses.hasCameraPermission()) continue
            val shot = runCatching { Core.glasses.takePhoto() }.getOrNull() ?: continue
            runCatching { Core.brain()?.glance(shot.jpegBase64) }
            // The camera can drop the call link. Mid-conversation the conversation owns the mic, so leave it alone.
            if (!conversing && !pausedForMusic && !mic.routed()) listenOnGlasses()
        }
    }

    private fun startStream() {
        streamJob?.cancel()
        streamJob = scope.launch {
            try {
                stream.run()
            } catch (e: CancellationException) {
                throw e  // CJ stopped the recorder itself; not a failure
            } catch (e: Exception) {
                Log.w(TAG, "microphone failed", e)
                setStatus("Microphone unavailable: ${e.message}")
            }
        }
    }

    /** Puts the glasses on their call link and (re)starts recording from them. */
    private suspend fun listenOnGlasses() {
        mic.route()
        delay(1_000)  // the Bluetooth call link takes a moment to come up
        startStream()  // a fresh recorder picks the glasses as its input
    }

    /**
     * Checks the audio every 2 s while CJ waits for "CJ":
     * - Music playing: the glasses can't do full-quality music and a call link at once, so CJ gives the link
     *   back to the music and pauses the wake word (tap Talk instead). It listens again when the music stops.
     * - Call link dropped (glasses folded or taken off, the camera session, another app): reconnect.
     *   Without this CJ kept recording from the phone's mic in your pocket and stopped hearing "CJ".
     */
    private suspend fun watchAudio() {
        var failedReconnects = 0
        while (scope.isActive) {
            // Back off after repeated failures: each attempt briefly forces the glasses into call audio, which
            // stutters any music. 62 attempts in 3 minutes did exactly that.
            delay(if (failedReconnects >= 3) 30_000 else 2_000)
            if (conversing) continue
            val music = mic.musicPlaying() && !Core.store.wakeDuringMusic
            when {
                music && !pausedForMusic -> {
                    pausedForMusic = true
                    streamJob?.cancel()
                    mic.release()
                    setStatus(idleStatus())
                }
                !music && pausedForMusic -> {
                    pausedForMusic = false
                    listenOnGlasses()
                    setStatus(idleStatus())
                }
                !pausedForMusic && mic.connected() && !mic.routed() -> {
                    listenOnGlasses()
                    failedReconnects = if (mic.routed()) 0 else failedReconnects + 1
                    Log.i(TAG, "glasses mic link lost; reconnect ${if (failedReconnects == 0) "ok" else "failed x$failedReconnects"}, music=$music")
                    setStatus(idleStatus())
                }
                else -> if (mic.routed() || pausedForMusic) failedReconnects = 0
            }
        }
    }

    private fun idleStatus(): String = when {
        pausedForMusic -> "Music playing: tap Talk to ask CJ"
        mic.routed() -> "Say \"CJ\""
        else -> "Glasses mic not connected: using the phone's mic"
    }

    /** True when "CJ" was heard or Talk was tapped in the notification. */
    private suspend fun waitForWakeOrTap(): Boolean = coroutineScope {
        val heard = async {
            try {
                wake.await(stream.frames)
                true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "wake word failed", e)
                setStatus("Wake word unavailable: ${e.message}")
                delay(5_000)
                false
            }
        }
        val tapped = async { talkNow.receive(); true }
        val result = select { heard.onAwait { it }; tapped.onAwait { it } }
        heard.cancel()
        tapped.cancel()
        result
    }

    /** One conversation. Started during music (via Talk), it pauses the music first and resumes it after. */
    private suspend fun converse() {
        conversing = true
        val duringMusic = pausedForMusic
        try {
            if (duringMusic) {
                holdMusic(true)
                listenOnGlasses()
            }
            talk()
        } finally {
            if (duringMusic) {
                streamJob?.cancel()
                mic.release()
                holdMusic(false)  // Spotify resumes at full quality
            }
            conversing = false
        }
    }

    /** Asks music apps to pause (they resume when CJ lets go). */
    private fun holdMusic(hold: Boolean) {
        val audio = getSystemService(AudioManager::class.java)
        if (hold) {
            focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .build().also { audio.requestAudioFocus(it) }
        } else {
            focus?.let { audio.abandonAudioFocusRequest(it) }
            focus = null
        }
    }

    private suspend fun talk() {
        beep.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
        if (Core.store.liveVoice && Core.store.pairing() != null) liveTalk() else classicTalk()
    }

    /**
     * Real-time conversation. The live session closes after 90 s of quiet and reopens the moment you speak again
     * (with the half second before it, so no words are lost); the conversation itself stays open until "bye".
     */
    private suspend fun liveTalk() {
        if (System.currentTimeMillis() < liveOffUntil) return classicTalk()
        useCallMic(true)
        try {
            liveLoop()
        } finally {
            useCallMic(false)
        }
    }

    /** Restarts the mic in call mode (echo cancelled) for a live conversation, or back to wake-word mode. */
    private fun useCallMic(on: Boolean) {
        if (stream.callMode == on) return
        stream.callMode = on
        if (!pausedForMusic || on) startStream()
    }

    private suspend fun liveLoop() {
        var lead: List<ShortArray>? = null
        while (scope.isActive) {
            val end = LiveSession(this, stream, ::setStatus).run("assistant", lead)
            lead = null
            Core.pendingCall?.let { Core.pendingCall = null; Core.call(it); return }
            when (end) {
                LiveEnd.Bye -> return
                LiveEnd.Stop -> { stopSelf(); return }
                is LiveEnd.Dictation -> takeNotes(end.session)
                is LiveEnd.Translate -> translate(end.language)
                is LiveEnd.Task -> { runTask(end.task); return }
                is LiveEnd.Failed -> {
                    Log.w(TAG, "live voice failed (${end.why}); using classic voice for this conversation")
                    // Out of free Live quota (or Live is down): don't retry on every "CJ" for the next hour.
                    if (Regex("(?i)quota|exhaust|429|resource|limit|unavailable|1011").containsMatchIn(end.why))
                        liveOffUntil = System.currentTimeMillis() + 3_600_000
                    useCallMic(false)
                    classicTalk()
                    return
                }
                LiveEnd.Idle -> {
                    setStatus("Still here: just talk, or say \"bye\"")
                    while (scope.isActive && lead == null) lead = stream.awaitSpeech(maxWaitMs = 600_000)
                }
            }
        }
    }

    /**
     * Phone agent: CJ works through an app for you, one step at a time (the brain picks each step from what's on
     * screen). It asks you out loud before anything that pays, orders or books, and hands you passwords and OTPs.
     */
    private suspend fun runTask(task: PhoneTask) {
        val agent = AgentService.instance
        val brain = Core.brain() ?: return
        if (agent == null) {
            say("To do things in apps, turn on CJ phone agent in your phone's Accessibility settings first.")
            return
        }
        val power = getSystemService(android.os.PowerManager::class.java)
        val lock = getSystemService(android.app.KeyguardManager::class.java)
        if (!power.isInteractive || lock.isKeyguardLocked) {
            say("Unlock your phone and I'll start.")
            if (withTimeoutOrNull(30_000) { while (!power.isInteractive || lock.isKeyguardLocked) delay(500) } == null) return
        }
        if (!agent.open(task.packageName, task.link) && task.packageName.isNotBlank()) {
            say("I couldn't open ${task.app}. Is it installed?")
            return
        }
        val history = mutableListOf<String>()
        var approved = ""
        var before = ""
        var stuck = 0
        repeat(40) {
            setStatus("Working in ${task.app.ifBlank { "your phone" }}… step ${history.size + 1}")
            val screen = settledScreen(agent)
            val now = screen.toString()
            if (history.isNotEmpty() && now == before && !history.last().startsWith("asked") &&
                !history.last().startsWith("the user")) {
                history[history.size - 1] += " (the screen didn't change)"
                if (++stuck >= 3) {
                    say("I'm stuck on this screen, so I stopped. It's on your phone if you want to finish it.")
                    return
                }
            } else {
                stuck = 0
            }
            before = now
            val step = try {
                brain.agentStep(task.goal, screen, history, approved)
            } catch (e: BrainException) {
                say("I lost my brain connection, so I stopped. It's on your screen.")
                return
            }
            approved = ""
            val n = step.optInt("n")
            val words = step.optString("say")
            // Numbers change with every screen, so the history names what was tapped.
            val what = (0 until screen.length()).map { screen.getJSONObject(it) }.firstOrNull { it.optInt("n") == n }
                ?.let { it.optString("text").ifBlank { it.optString("desc") } }.orEmpty().take(60)
            when (step.optString("do")) {
                "tap" -> history += "tapped \"$what\"" + (if (agent.tap(n)) "" else " (didn't work)")
                "type" -> history += "typed \"${step.optString("text")}\" into \"$what\"" + (if (agent.type(n, step.optString("text"))) "" else " (didn't work)")
                "scroll" -> history += "scrolled " + (if (agent.scroll()) "" else "(nothing to scroll)")
                "back" -> { agent.back(); history += "went back" }
                "wait" -> history += "waited"
                "done" -> { speakStep(brain, step, words); return }
                "ask" -> {
                    speakStep(brain, step, words)
                    val answer = listenOnce(brain) ?: run { say("I'll leave it there. It's on your screen."); return }
                    history += "asked \"$words\"; the user said \"$answer\""
                }
                "confirm" -> {
                    speakStep(brain, step, words)
                    val answer = listenOnce(brain).orEmpty()
                    if (!YES.containsMatchIn(answer) || Regex("(?i)\\b(no|nahi|don'?t|stop|wait)\\b").containsMatchIn(answer)) {
                        say("Okay, I didn't. It's on your screen if you want to finish it yourself.")
                        return
                    }
                    approved = step.optString("label")
                    history += "the user said yes to \"$approved\""
                }
            }
        }
        say("That took too long, so I stopped. It's on your screen.")
    }

    /** The screen once it stops changing (a page loading, an animation), at most ~4 s after the last step. */
    private suspend fun settledScreen(agent: AgentService): org.json.JSONArray {
        delay(600)
        var last = agent.screen()
        repeat(9) {
            delay(400)
            val next = agent.screen()
            if (next.toString() == last.toString()) return next
            last = next
        }
        return last
    }

    private suspend fun speakStep(brain: BrainClient, step: org.json.JSONObject, words: String) {
        if (words.isBlank()) return
        setStatus("Speaking…")
        val voice = brain.voiceIn(step)
        if (voice != null) Core.speaker.play(voice) else Core.speaker.say(words)
        stream.drain()
    }

    /** One spoken answer (a choice, or yes / no), transcribed. Null when nothing was said for 20 s. */
    private suspend fun listenOnce(brain: BrainClient): String? {
        beep.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
        setStatus("Listening for your answer…")
        val wav = stream.recordQuestion(waitForSpeechMs = 20_000) ?: return null
        return runCatching { brain.hear(wav) }.getOrNull()?.takeIf { it.isNotBlank() }
    }

    /** Live translator: "CJ, translate for me, she speaks Spanish". Ends with "stop translating". */
    private suspend fun translate(language: String) {
        val end = LiveSession(this, stream, ::setStatus).run("interpreter", null, language)
        if (end is LiveEnd.Failed) say("I couldn't start the translator: ${end.why}")
        else say("Okay, translation off.")
    }

    private suspend fun classicTalk() {
        // The conversation stays open, with the mic listening, until you say goodbye: no time limit.
        while (scope.isActive) {
            setStatus("Listening… say \"bye\" to finish")
            val wav = stream.recordQuestion(waitForSpeechMs = 30_000) ?: continue  // silence: keep waiting
            val (heard, spoken) = try {
                Core.askSpoken(wav)
            } catch (e: BrainException) {
                "?" to (e.message ?: "I couldn't reach my brain on the laptop.")
            }
            if (heard.isEmpty()) continue  // background noise, not speech: stay quiet and keep listening
            if (wantsStop(heard)) {
                say("Okay, CJ is going quiet.")
                stopSelf()
                return
            }
            if (wantsBye(heard)) {
                say(if (heard.any { it in 'ऀ'..'ॿ' } || Regex("(?i)chalo|alvida|bas|phir").containsMatchIn(heard)) "Theek hai, bye!" else "Bye!")
                return
            }
            val calling = Core.pendingCall != null
            say(spoken)
            if (calling) return  // the phone call has the audio now; say "CJ" again afterwards
            Core.dictation?.let { takeNotes(it) }
            Core.translateTo?.let { Core.translateTo = null; translate(it) }
            Core.phoneTask?.let { Core.phoneTask = null; runTask(it); return }
        }
    }

    /**
     * "Start taking notes": CJ quietly writes down everything said (a meeting, a lecture, a thought) until
     * "stop taking notes", then reads back a short summary. Long stretches, and pauses don't end it.
     */
    private suspend fun takeNotes(session: String) = coroutineScope {
        Core.dictation = null
        var chunks = 0
        // Uploads run beside the recorder, one at a time and in order, so no words are lost while one is sent.
        val outbox = Channel<ByteArray>(Channel.UNLIMITED)
        val finished = CompletableDeferred<String>()
        val uploader = launch {
            for (wav in outbox) {
                val chunk = try {
                    Core.dictate(session, wav)
                } catch (e: BrainException) {
                    Log.w(TAG, "dictation chunk lost", e)
                    continue  // keep going: one lost stretch is better than ending the meeting notes
                }
                if (chunk.heard.isNotBlank()) chunks++
                if (chunk.stopped) {
                    finished.complete(chunk.spoken)
                    return@launch
                }
            }
        }
        while (isActive && !finished.isCompleted) {
            setStatus("Taking notes ($chunks)… say \"stop taking notes\"")
            val recording = async { stream.recordQuestion(waitForSpeechMs = 120_000, maxMs = 60_000, endSilenceMs = 4_000) }
            val wav = select<ByteArray?> {
                finished.onAwait { null }
                recording.onAwait { it }
            }
            recording.cancel()  // the summary is ready: stop recording before CJ speaks
            if (wav != null) outbox.send(wav)
        }
        outbox.close()
        say(finished.await())
        uploader.cancel()
        coroutineContext.cancelChildren()
    }

    /** Speaks, then drops whatever the mic picked up of CJ's own voice. */
    private suspend fun say(text: String) {
        setStatus("Speaking…")
        Core.speak(text)
        stream.drain()
    }

    private fun setStatus(text: String) {
        Core.status = text
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(text))
    }

    private fun notification(text: String): Notification {
        fun action(action: String, code: Int) = PendingIntent.getService(this, code,
            Intent(this, CJService::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("CJ is listening")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Talk", action(ACTION_TALK, 1)).build())
            .addAction(Notification.Action.Builder(null, "Stop", action(ACTION_STOP, 2)).build())
            .build()
    }

    override fun onDestroy() {
        scope.cancel()
        Core.speaker.setVoiceCall(false)
        mic.release()
        beep.release()
        running = false
        Core.handsFree = false
        Core.status = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "CJService"
        private const val CHANNEL = "cj-hands-free"
        private const val NOTIFICATION_ID = 1
        private const val GLANCE_EVERY_MS = 5 * 60_000L
        private val YES = Regex("(?i)\\b(yes|yeah|yep|sure|ok(ay)?|go ahead|do it|haan|ha|kar do|confirm|book it|order it|pay)\\b")
        const val ACTION_TALK = "com.cj.glasses.TALK"
        const val ACTION_STOP = "com.cj.glasses.STOP"

        @Volatile var running = false
            private set

        fun start(context: Context, talk: Boolean = false) {
            val intent = Intent(context, CJService::class.java)
            if (talk) intent.action = ACTION_TALK
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, CJService::class.java).setAction(ACTION_STOP))
        }
    }
}
