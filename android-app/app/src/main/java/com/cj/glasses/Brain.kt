package com.cj.glasses

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

data class Pairing(val url: String, val token: String)
data class Turn(val role: String, val text: String)
data class Timer(val seconds: Int, val label: String)
data class FinishedJob(val project: String, val ok: Boolean, val summary: String)
data class Answer(val spoken: String, val details: String, val language: String, val voice: ByteArray? = null,
                  val timer: Timer? = null, val call: String? = null, val visualMemory: Boolean? = null,
                  val translate: String? = null, val task: PhoneTask? = null)
data class SpokenAnswer(val heard: String, val needsPhoto: Boolean, val spoken: String, val details: String,
                        val voice: ByteArray? = null, val timer: Timer? = null, val dictation: String? = null,
                        val call: String? = null, val visualMemory: Boolean? = null, val translate: String? = null,
                        val task: PhoneTask? = null)
data class Place(val lat: Double, val lon: Double, val accuracy: Float? = null)
data class PhoneTask(val goal: String, val packageName: String, val link: String, val app: String)
/** One chunk of "start taking notes": what was heard, and once you say "stop taking notes", the summary. */
data class NotesChunk(val heard: String, val stopped: Boolean, val spoken: String, val voice: ByteArray? = null)

open class BrainException(message: String) : Exception(message)

/** The brain didn't answer at all (wrong address, Mac asleep, other Wi-Fi), as opposed to answering with an error. */
class BrainUnreachable(message: String) : BrainException(message)

/** Talks to the CJ brain server on the laptop. Every call sends the pairing token. */
class BrainClient(private val pairing: Pairing) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(40, TimeUnit.SECONDS)
        .build()
    private val jsonType = "application/json; charset=utf-8".toMediaType()

    private suspend fun call(method: String, path: String, body: JSONObject? = null): JSONObject =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(pairing.url.trimEnd('/') + path)
                .header("Authorization", "Bearer ${pairing.token}")
                .method(method, body?.toString()?.toRequestBody(jsonType))
                .build()
            try {
                http.newCall(request).execute().use { response ->
                    val text = response.body?.string().orEmpty()
                    when {
                        response.code == 401 -> throw BrainException("The brain rejected the pairing token. Pair again in Devices.")
                        !response.isSuccessful -> throw BrainException("Brain error ${response.code}: ${text.take(160)}")
                        else -> JSONObject(text)
                    }
                }
            } catch (e: IOException) {
                throw BrainUnreachable("Can't reach the brain at ${pairing.url}. Is it running, and are you on the same Wi-Fi?")
            }
        }

    suspend fun health(): Map<String, Boolean> {
        val providers = call("GET", "/health").getJSONObject("providers")
        return providers.keys().asSequence().associateWith { providers.getBoolean(it) }
    }

    private fun JSONObject.at(place: Place?): JSONObject =
        if (place == null) this else put("location", place.json())

    private fun Place.json(): JSONObject = JSONObject().put("lat", lat).put("lon", lon).apply { accuracy?.let { put("acc", it.toDouble()) } }

    suspend fun ask(text: String, history: List<Turn>, imageJpegBase64: String? = null, place: Place? = null): Answer {
        val past = JSONArray().apply {
            history.takeLast(8).forEach { put(JSONObject().put("role", it.role).put("text", it.text)) }
        }
        val body = JSONObject().put("text", text).put("history", past).put("voice", true)
        if (imageJpegBase64 != null) body.put("image_b64", imageJpegBase64).put("mime", "image/jpeg")
        val r = call("POST", "/api/ask", body.at(place))
        return Answer(r.getString("spoken"), r.optString("details"), r.optString("language", "en"), voiceOf(r), timerOf(r),
            callOf(r), visualMemoryOf(r), translateOf(r), phoneTaskOf(r))
    }

    /** A spoken question as a WAV clip; the brain transcribes it and says whether it must look first. */
    suspend fun askSpoken(wav: ByteArray, history: List<Turn>, place: Place? = null): SpokenAnswer {
        val past = JSONArray().apply {
            history.takeLast(8).forEach { put(JSONObject().put("role", it.role).put("text", it.text)) }
        }
        val r = call("POST", "/api/ask", JSONObject()
            .put("audio_b64", Base64.encodeToString(wav, Base64.NO_WRAP)).put("audio_mime", "audio/wav")
            .put("history", past).put("voice", true).at(place))
        return SpokenAnswer(r.optString("heard"), r.optBoolean("needs_photo"), r.optString("spoken"), r.optString("details"),
            voiceOf(r), timerOf(r), r.optString("dictation").takeIf { it.isNotEmpty() && it != "null" }, callOf(r), visualMemoryOf(r), translateOf(r), phoneTaskOf(r))
    }

    /** Sends one stretch of dictation to the note-taking session the brain opened. */
    suspend fun dictate(session: String, wav: ByteArray): NotesChunk {
        val r = call("POST", "/api/notes/dictate", JSONObject().put("session", session)
            .put("audio_b64", Base64.encodeToString(wav, Base64.NO_WRAP)).put("audio_mime", "audio/wav"))
        return NotesChunk(r.optString("heard"), r.optBoolean("stopped"), r.optString("spoken"), voiceOf(r))
    }

    /** The answer spoken by CJ's Azure voice, when the brain sent one. */
    private fun voiceOf(r: JSONObject): ByteArray? =
        r.optString("voice_b64").takeIf { it.isNotEmpty() }?.let { Base64.decode(it, Base64.DEFAULT) }

    private fun timerOf(r: JSONObject): Timer? =
        r.optJSONObject("timer")?.let { t -> Timer(t.optInt("seconds"), t.optString("label")).takeIf { it.seconds > 0 } }

    /** Where the phone is now; the brain answers with something to say when the place makes it useful. */
    suspend fun nudge(place: Place): Pair<String, ByteArray?>? {
        val r = call("POST", "/api/nudge", JSONObject().put("location", place.json()))
        val say = r.optString("say")
        lastNudgeAsks = r.optBoolean("converse")
        return if (say.isBlank()) null else say to voiceOf(r)
    }

    /** Whether a nudge wants an answer ("Heading out? Want me to switch off the lights?"). */
    var lastNudgeAsks = false

    /** Visual memory: one automatic photo. True when the brain kept a note of it. */
    suspend fun glance(jpegBase64: String): Boolean =
        call("POST", "/api/glance", JSONObject().put("image_b64", jpegBase64).put("mime", "image/jpeg")).optBoolean("kept")

    /** "Translate for me, she speaks Spanish": the language, when the brain started the translator. */
    private fun translateOf(r: JSONObject): String? = r.optJSONObject("phone")
        ?.takeIf { it.optString("action") == "translate" }?.optString("language")

    /** "Start / pause visual memory" said to CJ: the switch lives on the phone. */
    fun visualMemoryOf(r: JSONObject): Boolean? = r.optJSONObject("phone")
        ?.takeIf { it.optString("action") == "visual_memory" }?.optBoolean("on")

    /** Phone agent: the next step for [goal] given the screen. */
    suspend fun agentStep(goal: String, screen: JSONArray, history: List<String>, approved: String): JSONObject =
        call("POST", "/api/agent/step", JSONObject().put("goal", goal).put("screen", screen)
            .put("history", JSONArray(history.takeLast(40))).put("approved", approved))

    /** What was said in a clip, nothing more (answers to the phone agent's questions). */
    suspend fun hear(wav: ByteArray): String = call("POST", "/api/hear", JSONObject()
        .put("audio_b64", Base64.encodeToString(wav, Base64.NO_WRAP)).put("audio_mime", "audio/wav")).optString("heard")

    fun voiceIn(r: JSONObject): ByteArray? = voiceOf(r)

    /** "Book me an Uber home": the task, when the brain handed one to the phone. */
    fun phoneTaskOf(r: JSONObject): PhoneTask? = r.optJSONObject("phone")
        ?.takeIf { it.optString("action") == "phone_task" }
        ?.let { PhoneTask(it.optString("goal"), it.optString("package"), it.optString("link"), it.optString("app")) }

    /** A number to call, sent once the user said yes to "Call …?". */
    private fun callOf(r: JSONObject): String? = r.optJSONObject("phone")
        ?.takeIf { it.optString("action") == "call_number" }?.optString("number")?.takeIf { it.isNotBlank() }

    /** Claude Code jobs that finished on the Mac since the last check (each is returned once). */
    suspend fun finishedJobs(): List<FinishedJob> {
        val jobs = call("GET", "/api/jobs/done").optJSONArray("jobs") ?: return emptyList()
        return (0 until jobs.length()).map { i ->
            val j = jobs.getJSONObject(i)
            FinishedJob(j.optString("project"), j.optString("state") == "done", j.optString("summary"))
        }
    }

    /** CJ's voice for something the phone says by itself (a timer going off). Null when Azure isn't set up. */
    suspend fun voiceFor(text: String): ByteArray? = voiceOf(call("POST", "/api/speak", JSONObject().put("text", text)))

}
