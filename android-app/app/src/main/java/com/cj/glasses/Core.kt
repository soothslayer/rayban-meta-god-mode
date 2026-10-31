package com.cj.glasses

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.telecom.TelecomManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meta.wearable.dat.core.types.RegistrationState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

data class TimerItem(val label: String, val dueAt: Long)

/**
 * State shared by the app screens and the background service: one speaker, one glasses link, one
 * conversation, and the "ask CJ" pipeline both of them use. Touch it from the main thread.
 */
object Core {
    lateinit var store: Store
        private set
    lateinit var speaker: Speaker
        private set
    lateinit var glasses: Glasses
        private set

    val log = mutableStateListOf<Turn>()
    var details by mutableStateOf("")
    var photo by mutableStateOf<Snapshot?>(null)
    var status by mutableStateOf<String?>(null)
    /** True while the hands-free service is running. */
    var handsFree by mutableStateOf(false)

    /** Running timers ("remind me in 10 minutes…"), shown on the Talk screen. */
    val timers = mutableStateListOf<TimerItem>()

    private lateinit var app: Context
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var cached: Pair<Pairing, BrainClient>? = null
    private var pendingVoice: Pair<String, ByteArray>? = null
    /** Set when the last answer opened a note-taking session ("start taking notes"); the service takes over. */
    var dictation: String? = null

    var lastPlace: Place? = null

    /**
     * Roughly where the phone is, for "how long to the airport". Null without the location permission.
     * Android can hide the location from a background service, so the last one seen (with CJ open) is kept.
     */
    @Suppress("MissingPermission")
    fun place(): Place? {
        val allowed = listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
            .any { app.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        if (!allowed) return null
        val lm = app.getSystemService(LocationManager::class.java) ?: return lastPlace
        val now = runCatching {
            lm.getProviders(true).mapNotNull { lm.getLastKnownLocation(it) }.maxByOrNull { it.time }
        }.getOrNull()?.let { Place(it.latitude, it.longitude, if (it.hasAccuracy()) it.accuracy else null) }
        if (now != null) lastPlace = now
        return lastPlace
    }

    /**
     * Says [text] in CJ's voice: the one the brain sent with the answer, else fetched for it ("Bye!", "Okay, I
     * stopped"), and the phone's own voice only when the brain doesn't answer quickly.
     */
    suspend fun speak(text: String) {
        val voice = pendingVoice?.takeIf { it.first == text }?.second
            ?: withTimeoutOrNull(2_500) { runCatching { brain()?.voiceFor(text) }.getOrNull() }
        pendingVoice = null
        if (voice != null) speaker.play(voice) else speaker.say(text)
        pendingCall?.let { pendingCall = null; call(it) }
    }

    fun init(context: Context) {
        if (::store.isInitialized) return
        app = context.applicationContext
        store = Store(app)
        speaker = Speaker(app)
        glasses = Glasses(app)
    }

    fun brain(): BrainClient? {
        val pairing = store.pairing() ?: return null
        cached?.let { (p, client) -> if (p == pairing) return client }
        return BrainClient(pairing).also { cached = pairing to it }
    }

    /**
     * Runs [block] against the brain. If the saved address stopped answering (the Mac got a new Wi-Fi
     * address), finds the brain on the network, saves the new address and tries once more.
     */
    private suspend fun <T> withBrain(block: suspend (BrainClient) -> T): T {
        val brain = brain() ?: throw BrainException("Pair CJ with your laptop first, in the Setup tab.")
        return try {
            block(brain)
        } catch (e: BrainUnreachable) {
            val pairing = store.pairing() ?: throw e
            val found = Discovery.find(app) ?: throw e
            if (found == pairing.url.trimEnd('/')) throw e
            store.save(pairing.copy(url = found))
            block(brain() ?: throw e)
        }
    }

    /** Counts down on the phone, then says it in CJ's voice (through the glasses) and shows a notification. */
    fun startTimer(timer: Timer) {
        val item = TimerItem(timer.label, System.currentTimeMillis() + timer.seconds * 1000L)
        timers.add(item)
        appScope.launch {
            delay(timer.seconds * 1000L)
            timers.remove(item)
            val text = if (item.label.isBlank()) "Your timer is done." else "Time's up: ${item.label}."
            notifyTimer(text)
            val voice = runCatching { brain()?.voiceFor(text) }.getOrNull()
            if (voice != null) speaker.play(voice) else speaker.say(text)
        }
    }

    private fun notifyTimer(text: String) {
        val nm = app.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("cj-timers", "CJ timers", NotificationManager.IMPORTANCE_HIGH))
        nm.notify((System.currentTimeMillis() % 100_000).toInt() + 100, Notification.Builder(app, "cj-timers")
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("CJ")
            .setContentText(text)
            .setAutoCancel(true)
            .build())
    }

    /**
     * "Call this number": the brain already asked "Call …?" and heard yes. Calls straight away through the phone
     * (works from the background); without the permission it opens the dialler with the number filled in.
     */
    @Suppress("MissingPermission")
    fun call(number: String) {
        val uri = Uri.fromParts("tel", number, null)
        if (app.checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED) {
            runCatching { app.getSystemService(TelecomManager::class.java).placeCall(uri, null) }
                .onSuccess { return }
        }
        runCatching {
            app.startActivity(android.content.Intent(android.content.Intent.ACTION_DIAL, uri)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /** Set when the last answer handed a task to the phone agent ("book me an Uber home"). */
    var phoneTask: PhoneTask? = null

    /** Set when the last answer started the live translator; the service takes over. */
    var translateTo: String? = null

    /** Calls after CJ has finished speaking, so "Calling Priya" isn't cut off by the ringing. */
    var pendingCall: String? = null

    /** One stretch of a note-taking session. */
    suspend fun dictate(session: String, wav: ByteArray): NotesChunk {
        val chunk = withBrain { it.dictate(session, wav) }
        if (chunk.stopped) {
            log.add(Turn("assistant", chunk.spoken))
            pendingVoice = chunk.voice?.let { chunk.spoken to it }
        }
        return chunk
    }

    fun glassesLinked(): Boolean =
        glasses.ready.value && glasses.registration.value == RegistrationState.REGISTERED

    /**
     * Asks CJ, optionally with a photo from the glasses first. Adds both turns to [log] and returns the
     * spoken answer. Throws [BrainException] or [GlassesException].
     */
    suspend fun ask(text: String, look: Boolean): String {
        if (brain() == null) throw BrainException("Pair CJ with your laptop first, in the Setup tab.")
        var shot: Snapshot? = null
        if (look) {
            status = "Looking through your glasses…"
            try {
                shot = glasses.takePhoto()
                photo = shot
            } finally {
                status = null
            }
        }
        val history = log.toList()
        log.add(Turn("user", if (shot != null) "[photo] $text" else text))
        val answer = withBrain { it.ask(text, history, shot?.jpegBase64, place()) }
        log.add(Turn("assistant", answer.spoken))
        details = answer.details
        answer.timer?.let(::startTimer)
        pendingCall = answer.call
        answer.visualMemory?.let { store.visualMemory = it }
        translateTo = answer.translate
        phoneTask = answer.task
        pendingVoice = answer.voice?.let { answer.spoken to it }
        return answer.spoken
    }

    /**
     * A spoken question (WAV) from hands-free mode. The brain transcribes it; if it's a "what is this"
     * question CJ takes a photo with the glasses and asks again with it. Returns what was heard (empty when
     * nothing clear was said) and the answer to speak.
     */
    suspend fun askSpoken(wav: ByteArray): Pair<String, String> {
        status = "Thinking…"
        val history = log.toList()
        val first = withBrain { it.askSpoken(wav, history, place()) }
        dictation = first.dictation
        val heard = first.heard.trim()
        if (heard.isEmpty() || wantsStop(heard)) return heard to ""
        if (!first.needsPhoto) {
            log.add(Turn("user", heard))
            log.add(Turn("assistant", first.spoken))
            details = first.details
            pendingVoice = first.voice?.let { first.spoken to it }
            first.timer?.let(::startTimer)
            pendingCall = first.call
            first.visualMemory?.let { store.visualMemory = it }
            translateTo = first.translate
            phoneTask = first.task
            return heard to first.spoken
        }
        val cantLook = when {
            !glassesLinked() -> "I can't see right now. Link your glasses in CJ's Setup tab first."
            !glasses.hasCameraPermission() -> "To let me see, open CJ once and tap Look to allow the camera."
            else -> null
        }
        if (cantLook != null) {
            log.add(Turn("user", heard))
            log.add(Turn("assistant", cantLook))
            return heard to cantLook
        }
        return try {
            heard to ask(heard, look = true)
        } catch (e: GlassesException) {
            heard to (e.message ?: "I couldn't take a photo.")
        }
    }
}

private val LOOK_PHRASES = Regex(
    """what am i looking at|what('s| is) (this|that|it)|read (this|that|it)|look at|can you see|""" +
        """identify|tell me about this|(add|save|call|join|connect to|note) (this|that)\b|this (wifi|wi-fi|number|card|""" +
        """whiteboard|poster|event)|\bye(h)? kya\b|kya hai (ye|yeh)|\bdekh|\bpadh|is(ka|ki|ko) |iska\b|""" +
        """ये क्या|यह क्या|देख|पढ़|इसका|इसको""",
    RegexOption.IGNORE_CASE,
)

/** Whether a spoken question needs a photo from the glasses ("what am I looking at", "ye kya hai"). */
fun wantsLook(text: String): Boolean = LOOK_PHRASES.containsMatchIn(text)

private val STOP_PHRASES = Regex(
    """\b(stop listening|go to sleep|turn (yourself|cj) off|turn off cj|switch off cj|band karo|so jao|chup ho ja)\b|""" +
        """^(cj,? )?(turn|switch) off$|बंद करो|सो जाओ""",
    RegexOption.IGNORE_CASE,
)

/**
 * "Stop listening", "go to sleep", "turn yourself off": switches hands-free off. Only when that's all that was
 * said, so "turn off the bedroom lights" or "AC band karo" goes to the smart home instead.
 */
fun wantsStop(text: String): Boolean {
    val clean = text.trim().trimEnd('.', '!', '?', '।').trim()
    return STOP_PHRASES.containsMatchIn(clean) && clean.split(Regex("\\s+")).size <= 4 &&
        !Regex("(?i)\\b(ac|light|lights|fan|tv|music|notes|geyser|plug)\\b").containsMatchIn(clean)
}

private val BYE_PHRASES = Regex(
    """\b(bye( bye)?( cj)?|good ?bye|that'?s all|that is all|that'?s it( for now)?|see you|see ya|""" +
        """talk (to you )?later|catch you later|later cj|i('ve| have)? (got|gotta) to go|i (gotta|have to|need to|must) go|""" +
        """gotta go|got to go|i'?m (done|off)|we'?re done|done for (now|today)|nothing else|""" +
        """chalo bye|ok bye|bas itna hi|bas itna|alvida|phir milte|chalta hu+n?|chalti hu+n?|""" +
        """adi[oó]s|hasta luego|au revoir|tsch[uü]ss|ciao|tchau|sayonara|ma'?a ?salama|khuda hafiz|allah hafiz)\b|""" +
        """बाय|अलविदा|फिर मिलते|चलता हूँ|再见|さようなら|до свидания|пока|مع السلامة|খোদা হাফেজ|خدا حافظ""",
    RegexOption.IGNORE_CASE,
)

/**
 * "Bye", "I've got to go", "that's all", "alvida", "adiós": ends the conversation (CJ goes back to waiting for "CJ"). Only when it's
 * the point of what was said: a short phrase, or one ending with it. "How do you say bye in French?" doesn't count.
 */
fun wantsBye(text: String): Boolean {
    val clean = text.trim().trimEnd('.', '!', '?', '।').trim()
    val match = BYE_PHRASES.findAll(clean).lastOrNull() ?: return false
    return clean.split(Regex("\\s+")).size <= 6 || match.range.last >= clean.length - 1
}
