package com.cj.glasses

import android.content.Context

/** Remembers which brain this phone is paired with. App-private storage; Android Keystore encryption comes later. */
class Store(context: Context) {
    private val prefs = context.getSharedPreferences("cj", Context.MODE_PRIVATE)

    fun pairing(): Pairing? {
        val url = prefs.getString("url", null) ?: return null
        val token = prefs.getString("token", null) ?: return null
        return Pairing(url, token)
    }

    fun save(p: Pairing) {
        prefs.edit().putString("url", p.url.trim()).putString("token", p.token.trim()).apply()
    }

    /** Keep listening for "CJ" while music plays, at the cost of call-quality music. Off by default. */
    var wakeDuringMusic: Boolean
        get() = prefs.getBoolean("wake_during_music", false)
        set(value) = prefs.edit().putBoolean("wake_during_music", value).apply()

    /** Visual memory: the glasses take a photo every few minutes and the brain keeps a short note. Off by default. */
    var visualMemory: Boolean
        get() = prefs.getBoolean("visual_memory", false)
        set(value) = prefs.edit().putBoolean("visual_memory", value).apply()

    /** Real-time voice (Gemini Live): answers start in under a second and you can interrupt. On by default. */
    var liveVoice: Boolean
        get() = prefs.getBoolean("live_voice", true)
        set(value) = prefs.edit().putBoolean("live_voice", value).apply()

    fun clear() {
        prefs.edit().clear().apply()
    }
}
