package com.cj.glasses

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.net.Uri
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * The phone agent's hands: reads what's on screen and taps, types and scrolls, only while CJ runs a task you asked
 * for ("book me an Uber home"). Turned on by you in Settings -> Accessibility -> CJ phone agent. The brain decides
 * each step (brain/app/phone_agent.py), and asks you before anything is paid or booked.
 */
class AgentService : AccessibilityService() {
    private var nodes: Map<Int, AccessibilityNodeInfo> = emptyMap()

    override fun onServiceConnected() {
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** What's on screen, numbered: buttons, text and fields the brain can choose from. */
    fun screen(): JSONArray {
        val out = JSONArray()
        val found = mutableMapOf<Int, AccessibilityNodeInfo>()
        fun walk(node: AccessibilityNodeInfo?, depth: Int) {
            if (node == null || depth > 40 || found.size >= 150) return
            if (node.isVisibleToUser) {
                val text = node.text?.toString().orEmpty()
                val desc = node.contentDescription?.toString().orEmpty()
                if (text.isNotBlank() || desc.isNotBlank() || node.isClickable || node.isEditable || node.isScrollable) {
                    val n = found.size + 1
                    found[n] = node
                    out.put(JSONObject().put("n", n).put("text", text.take(120)).put("desc", desc.take(120))
                        .put("kind", node.className?.toString()?.substringAfterLast('.')?.lowercase() ?: "view")
                        .put("clickable", node.isClickable).put("editable", node.isEditable)
                        .put("scrollable", node.isScrollable).put("checked", node.isChecked).put("password", node.isPassword))
                }
            }
            for (i in 0 until node.childCount) walk(node.getChild(i), depth + 1)
        }
        walk(rootInActiveWindow, 0)
        nodes = found
        return out
    }

    fun tap(n: Int): Boolean {
        var node = nodes[n] ?: return false
        var hops = 0
        while (!node.isClickable && hops++ < 5) node = node.parent ?: break
        if (node.isClickable && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
        val r = Rect().also { nodes[n]!!.getBoundsInScreen(it) }  // not clickable by itself: tap its middle
        val path = Path().apply { moveTo(r.exactCenterX(), r.exactCenterY()) }
        return dispatchGesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, 60)).build(), null, null)
    }

    fun type(n: Int, text: String): Boolean {
        val node = nodes[n] ?: return false
        if (node.isPassword) return false  // never: the brain hands these to the user
        node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,
            Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text) })
    }

    fun scroll(): Boolean =
        nodes.values.firstOrNull { it.isScrollable }?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD) ?: false

    fun back(): Boolean = performGlobalAction(GLOBAL_ACTION_BACK)

    /** Opens the app for the task: its deep link when there is one ("uber://…" straight to the ride), else the app. */
    fun open(packageName: String, link: String): Boolean {
        val intent = when {
            link.isNotBlank() -> Intent(Intent.ACTION_VIEW, Uri.parse(link))
            packageName.isNotBlank() -> packageManager.getLaunchIntentForPackage(packageName)
            else -> null
        } ?: return false
        return runCatching { startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true }.getOrDefault(false)
    }

    companion object {
        @Volatile var instance: AgentService? = null
            private set
    }
}
