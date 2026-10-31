package com.cj.glasses

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The phrases that end a conversation or switch CJ off must not catch everyday requests. */
class PhrasesTest {
    @Test fun goodbyesEndTheConversation() {
        listOf("Bye", "bye CJ", "I've got to go", "I have to go now, gotta go", "talk to you later", "that's all for now",
            "ok, I'm done", "chalo bye", "alvida", "adiós", "ciao", "khuda hafiz", "再见", "Thanks, see you").forEach {
            assertTrue(it, wantsBye(it))
        }
    }

    @Test fun questionsAboutGoodbyeDoNot() {
        listOf("how do you say bye in French and Spanish and German please", "what's the weather",
            "good night", "I'm leaving").forEach { assertFalse(it, wantsBye(it)) }
    }

    @Test fun stopSwitchesCjOff() {
        listOf("stop listening", "CJ go to sleep", "turn off", "turn yourself off", "so jao").forEach {
            assertTrue(it, wantsStop(it))
        }
    }

    @Test fun smartHomeIsNotStop() {
        listOf("turn off the bedroom lights", "AC band karo", "turn off the TV", "switch off the fan",
            "TV band karo", "turn off the music").forEach { assertFalse(it, wantsStop(it)) }
    }

    @Test fun lookAndDoTakesAPhoto() {
        listOf("add this to my calendar", "save this contact", "call this number", "connect to this wifi",
            "turn this whiteboard into notes", "what is this").forEach { assertTrue(it, wantsLook(it)) }
        assertFalse(wantsLook("call mom"))
    }
}
