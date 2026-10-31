package com.cj.glasses

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.meta.wearable.dat.core.types.RegistrationState
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val Night = darkColorScheme(
    primary = Color(0xFF8B7CFF), onPrimary = Color(0xFF0B0B14),
    primaryContainer = Color(0xFF2B2462), onPrimaryContainer = Color(0xFFE6E1FF),
    secondary = Color(0xFF2DD4BF), onSecondary = Color(0xFF04201C),
    background = Color(0xFF0A0B10), onBackground = Color(0xFFE8E9F1),
    surface = Color(0xFF0A0B10), onSurface = Color(0xFFE8E9F1),
    surfaceVariant = Color(0xFF171A24), onSurfaceVariant = Color(0xFFA7ABBD),
    surfaceContainer = Color(0xFF12141C), outline = Color(0xFF2A2E3D), error = Color(0xFFFF6B81),
)

@Composable
fun CJTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Night, content = content)
}

/** Things to try, shown before the first question. Tapping one asks it. */
private val EXAMPLES = listOf(
    "What's the weather in Mumbai today?" to false,
    "Good morning" to false,
    "Remember I parked at B2, pillar 14" to false,
    "Open Spotify on my Mac" to false,
    "Kal Delhi mein mausam kaisa rahega?" to false,
    "What am I looking at?" to true,
)

@Composable
fun CJApp(store: Store, speaker: Speaker, listener: Listener, glasses: Glasses, controls: GlassesControls,
          withMic: ((Boolean) -> Unit) -> Unit) {
    var pairing by remember { mutableStateOf(store.pairing()) }
    val brain = remember(pairing) { pairing?.let { BrainClient(it) } }
    var tab by remember { mutableIntStateOf(if (pairing == null) 1 else 0) }

    Scaffold(containerColor = MaterialTheme.colorScheme.background, bottomBar = {
        NavigationBar(containerColor = MaterialTheme.colorScheme.surfaceContainer) {
            NavigationBarItem(selected = tab == 0, onClick = { tab = 0 },
                icon = { Icon(Icons.Filled.Home, contentDescription = null) }, label = { Text("CJ") })
            NavigationBarItem(selected = tab == 1, onClick = { tab = 1 },
                icon = { Icon(Icons.Filled.Settings, contentDescription = null) }, label = { Text("Setup") })
        }
    }) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            if (tab == 0) TalkScreen(brain, speaker, listener, glasses, controls, withMic)
            else SetupScreen(store, pairing, brain, glasses, controls) { pairing = it; tab = 0 }
        }
    }
}

@Composable
private fun NeedPairing() {
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text("CJ", fontSize = 56.sp, fontWeight = FontWeight.Black, color = MaterialTheme.colorScheme.primary)
        Text("Connect CJ to its brain on your laptop first: open Setup and scan the QR code printed by run.sh.",
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 12.dp))
    }
}

@Composable
private fun Bubble(text: String, mine: Boolean) {
    val colors = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        Column(
            Modifier.fillMaxWidth(0.84f).clip(RoundedCornerShape(20.dp, 20.dp, if (mine) 6.dp else 20.dp, if (mine) 20.dp else 6.dp))
                .background(if (mine) colors.primaryContainer else colors.surfaceVariant)
                .padding(horizontal = 14.dp, vertical = 10.dp)
        ) {
            if (!mine) Text("CJ", style = MaterialTheme.typography.labelSmall, color = colors.secondary, fontWeight = FontWeight.Bold)
            Text(text, color = if (mine) colors.onPrimaryContainer else colors.onSurface)
        }
    }
}

@Composable
private fun StatusDot(on: Boolean) {
    Box(Modifier.size(8.dp).clip(CircleShape).background(if (on) MaterialTheme.colorScheme.secondary else MaterialTheme.colorScheme.outline))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TalkScreen(brain: BrainClient?, speaker: Speaker, listener: Listener, glasses: Glasses, controls: GlassesControls,
               withMic: ((Boolean) -> Unit) -> Unit) {
    if (brain == null) return NeedPairing()
    val scope = rememberCoroutineScope()
    val colors = MaterialTheme.colorScheme
    var input by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    /** Typed, tapped or spoken question; [look] adds a photo from the glasses first. Shares the log with hands-free CJ. */
    fun ask(text: String, look: Boolean = false) {
        if (text.isBlank() || busy) return
        busy = true
        error = null
        input = ""
        scope.launch {
            try {
                if (look && !glasses.hasCameraPermission() && !controls.requestCamera()) {
                    error = "CJ needs camera access in the Meta AI app to see through your glasses."
                    return@launch
                }
                Core.speak(Core.ask(text, look))
            } catch (e: GlassesException) {
                error = e.message
            } catch (e: BrainException) {
                error = e.message
            } finally {
                busy = false
            }
        }
    }

    val listState = rememberLazyListState()
    // Keep the newest message in view, including turns added by hands-free CJ in the background.
    LaunchedEffect(Core.log.size, Core.details) {
        if (Core.log.isNotEmpty()) listState.animateScrollToItem(listState.layoutInfo.totalItemsCount.coerceAtLeast(1) - 1)
    }
    // An old error shouldn't linger once CJ has moved on to a new question.
    LaunchedEffect(Core.log.size) { if (!busy) error = null }

    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        // Header: name, live status, hands-free switch.
        Row(Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("CJ", fontSize = 34.sp, fontWeight = FontWeight.Black, color = colors.primary)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    StatusDot(Core.handsFree)
                    Spacer(Modifier.width(6.dp))
                    Text(Core.status ?: if (Core.handsFree) "Listening for \"CJ\"" else "Hands-free is off",
                        style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Switch(checked = Core.handsFree, onCheckedChange = controls::setHandsFree)
                Text("Hands-free", style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
            }
        }
        Core.timers.forEach { t ->
            val at = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(t.dueAt))
            Text("⏱  $at${if (t.label.isNotBlank()) " · ${t.label}" else ""}", style = MaterialTheme.typography.bodySmall,
                color = colors.secondary, modifier = Modifier.padding(bottom = 4.dp))
        }

        LazyColumn(Modifier.weight(1f), state = listState, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (Core.log.isEmpty()) {
                item {
                    Card(colors = CardDefaults.cardColors(containerColor = colors.surfaceVariant), modifier = Modifier.padding(top = 8.dp)) {
                        Column(Modifier.padding(16.dp)) {
                            Text("Say \"CJ\", then ask anything.", fontWeight = FontWeight.SemiBold)
                            Text("English, Hindi or Hinglish. CJ sees through your glasses, controls your Mac and remembers things for you.",
                                style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant,
                                modifier = Modifier.padding(top = 4.dp, bottom = 8.dp))
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                EXAMPLES.forEach { (text, look) ->
                                    SuggestionChip(onClick = { ask(text, look) }, label = { Text(text) })
                                }
                            }
                        }
                    }
                }
            }
            Core.photo?.let { shot ->
                item {
                    Image(shot.bitmap.asImageBitmap(), contentDescription = "Last photo from the glasses",
                        modifier = Modifier.fillMaxWidth().height(190.dp).clip(RoundedCornerShape(20.dp)),
                        contentScale = ContentScale.Crop)
                }
            }
            items(Core.log) { Bubble(it.text, it.role == "user") }
            if (Core.details.isNotBlank()) item {
                Text(Core.details, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant,
                    modifier = Modifier.padding(start = 6.dp, end = 24.dp))
            }
            item { Spacer(Modifier.height(4.dp)) }
        }
        error?.let { Text(it, color = colors.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(vertical = 4.dp)) }

        // Input: type, talk, or look.
        Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            OutlinedTextField(input, { input = it }, Modifier.weight(1f), shape = RoundedCornerShape(24.dp), singleLine = true,
                placeholder = { Text("Ask CJ…") },
                trailingIcon = {
                    IconButton(onClick = { ask(input) }, enabled = !busy && input.isNotBlank()) {
                        Icon(Icons.Filled.Send, contentDescription = "Send", tint = colors.primary)
                    }
                })
            FilledTonalButton(onClick = { ask(input.ifBlank { "What am I looking at?" }, look = true) }, enabled = !busy) { Text("Look") }
            Button(onClick = {
                // While hands-free runs it owns the mic, so the button just starts a question there.
                if (Core.handsFree) CJService.start(listener.context, talk = true)
                else withMic { granted ->
                    if (granted) listener.start({ ask(it, look = wantsLook(it)) }) { error = it }
                    else error = "Microphone permission is off for CJ."
                }
            }, enabled = !busy) { Text("Talk") }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant), shape = RoundedCornerShape(20.dp)) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            content()
        }
    }
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun GlassesSection(glasses: Glasses, controls: GlassesControls) {
    val ready by glasses.ready.collectAsState()
    if (!ready) {
        Hint("Allow Bluetooth for CJ (Android asks when the app opens) to use your glasses.")
        return
    }
    val registration by glasses.registration.collectAsState()
    val devices by glasses.devices.collectAsState()
    val linked = registration == RegistrationState.REGISTERED
    Row(verticalAlignment = Alignment.CenterVertically) {
        StatusDot(linked && devices.isNotEmpty())
        Spacer(Modifier.width(8.dp))
        Text(when (registration) {
            RegistrationState.REGISTERED -> if (devices.isEmpty()) "Linked. Turn on and unfold your glasses."
                                            else "Linked to your glasses"
            RegistrationState.REGISTERING -> "Finish linking in the Meta AI app…"
            RegistrationState.UNREGISTERING -> "Unlinking…"
            RegistrationState.AVAILABLE -> "Not linked yet"
            else -> "Meta AI app not ready"
        })
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (linked) {
            OutlinedButton(onClick = controls::updateGlassesApp) { Text("Update glasses app") }
            TextButton(onClick = controls::unregister) { Text("Unlink") }
        } else {
            Button(onClick = controls::register, enabled = registration == RegistrationState.AVAILABLE) { Text("Link glasses") }
        }
    }
    if (!linked) Hint("First turn on Developer Mode in the Meta AI app: Settings → App info → tap the version number 5 times.")
}

@Composable
fun SetupScreen(store: Store, pairing: Pairing?, brain: BrainClient?, glasses: Glasses, controls: GlassesControls,
                onPaired: (Pairing) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var url by remember { mutableStateOf(pairing?.url ?: "http://") }
    var token by remember { mutableStateOf(pairing?.token ?: "") }
    var message by remember { mutableStateOf<String?>(null) }
    var manual by remember { mutableStateOf(false) }
    var duringMusic by remember { mutableStateOf(store.wakeDuringMusic) }
    var visualMemory by remember { mutableStateOf(store.visualMemory) }
    var liveVoice by remember { mutableStateOf(store.liveVoice) }

    fun scan() {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(context, options).startScan()
            .addOnSuccessListener { code ->
                try {
                    val j = JSONObject(code.rawValue.orEmpty())
                    val p = Pairing(j.getString("url"), j.getString("token"))
                    store.save(p)
                    url = p.url
                    token = p.token
                    onPaired(p)
                } catch (e: Exception) {
                    message = "That QR code isn't from the CJ brain."
                }
            }
            .addOnFailureListener { message = "Couldn't scan: ${it.message}" }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Setup", fontSize = 28.sp, fontWeight = FontWeight.Black)

        Section("Brain") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(pairing != null)
                Spacer(Modifier.width(8.dp))
                Text(if (pairing != null) "Paired with your laptop" else "Not paired")
            }
            Hint("Run brain/run.sh on your laptop and scan the QR code it prints. Same Wi-Fi for both; CJ finds the laptop again by itself if its address changes.")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = ::scan) { Text("Scan QR code") }
                OutlinedButton(enabled = brain != null, onClick = {
                    scope.launch {
                        message = try {
                            val on = brain!!.health().filter { it.key != "mock" }
                            "Connected · " + on.entries.joinToString(" · ") { "${it.key} ${if (it.value) "✓" else "no key"}" }
                        } catch (e: BrainException) {
                            e.message
                        }
                    }
                }) { Text("Test") }
            }
            message?.let { Hint(it) }
            TextButton(onClick = { manual = !manual }) { Text(if (manual) "Hide manual pairing" else "Pair manually") }
            if (manual) {
                OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), label = { Text("Address") }, singleLine = true)
                OutlinedTextField(token, { token = it }, Modifier.fillMaxWidth(), label = { Text("Pairing token") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation())
                Button(enabled = url.length > 7 && token.isNotBlank(), onClick = {
                    val p = Pairing(url, token)
                    store.save(p)
                    onPaired(p)
                }) { Text("Save") }
            }
        }

        Section("Ray-Ban Meta glasses") { GlassesSection(glasses, controls) }

        Section("Hands-free") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Listen for \"CJ\" during music")
                    Hint(if (duringMusic) "On: music plays at phone-call quality while CJ listens."
                         else "Off: music stays full quality; tap Talk in the notification to ask CJ.")
                }
                Switch(checked = duringMusic, onCheckedChange = { duringMusic = it; store.wakeDuringMusic = it })
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Real-time voice")
                    Hint(if (liveVoice) "On: answers start in under a second and you can talk over CJ. Uses Gemini's own voice."
                         else "Off: CJ records each question, then answers in the Azure voice (Olivia).")
                }
                Switch(checked = liveVoice, onCheckedChange = { liveVoice = it; store.liveVoice = it })
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Visual memory")
                    Hint(if (visualMemory) "On: a photo every 5 minutes; only a short note is kept on your laptop, never the photo."
                         else "Off. When on, ask \"what was that café I walked past?\" Say \"pause visual memory\" any time.")
                }
                Switch(checked = visualMemory, onCheckedChange = { visualMemory = it; store.visualMemory = it })
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Phone agent")
                    Hint(if (AgentService.instance != null) "On: \"book me an Uber home\", \"order my usual chai on Swiggy\". CJ asks before anything is paid."
                         else "Off. Lets CJ use apps for you. Turn on \"CJ phone agent\" in Accessibility settings.")
                }
                TextButton(onClick = {
                    context.startActivity(android.content.Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS))
                }) { Text("Settings") }
            }
            Hint("Say \"bye\" to end a conversation, \"stop listening\" to turn hands-free off. There's also a CJ tile in Quick Settings.")
        }

        Hint("CJ · open source · not affiliated with Meta or Ray-Ban")
    }
}
