package com.example.homework_companion

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Invisible activity that appears in the Android share sheet as "Save to TubeBox".
 * It saves the shared YouTube link straight into the currently selected list file
 * (path written by the Flutter app into files/share_config.txt) and closes at once,
 * so the user never leaves the YouTube app.
 */
class ShareReceiverActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent?.getStringExtra(Intent.EXTRA_TEXT) ?: ""
        val subject = intent?.getStringExtra(Intent.EXTRA_SUBJECT) ?: ""
        val appContext = applicationContext
        val dir = filesDir

        Thread {
            val message = try {
                saveShared(dir, text, subject)
            } catch (e: Exception) {
                "Could not save: ${e.message}"
            }
            runOnUiThread {
                Toast.makeText(appContext, message, Toast.LENGTH_LONG).show()
                finish()
                overridePendingTransition(0, 0)
            }
        }.start()
    }

    private fun saveShared(filesDir: File, text: String, subject: String): String {
        val url = Regex("https?://\\S+").find(text)?.value
            ?: return "No YouTube link found in what was shared"

        val videoId = Regex("(?:[?&]v=|youtu\\.be/|/shorts/|/embed/|/live/)([A-Za-z0-9_-]{11})")
            .find(url)?.groupValues?.get(1)
        val playlistId = if (videoId == null) {
            Regex("[?&]list=([A-Za-z0-9_-]{10,})").find(url)?.groupValues?.get(1)
        } else null

        val kind: String
        val id: String
        if (videoId != null) {
            kind = "video"; id = videoId
        } else if (playlistId != null) {
            kind = "playlist"; id = playlistId
        } else {
            return "That is not a YouTube video or playlist link"
        }

        val webUrl = if (kind == "video") "https://www.youtube.com/watch?v=$id"
        else "https://www.youtube.com/playlist?list=$id"

        val fetched = fetchTitle(webUrl)
        val fromText = text.replace(url, "").trim()
        val rawTitle = when {
            !fetched.isNullOrBlank() -> fetched
            fromText.isNotEmpty() -> fromText
            subject.isNotBlank() -> subject
            kind == "video" -> "YouTube video"
            else -> "YouTube playlist"
        }
        val title = rawTitle.replace(Regex("[\\r\\n\\t]+"), " ").trim()

        return synchronized(LOCK) { appendEntry(filesDir, kind, id, title) }
    }

    private fun appendEntry(filesDir: File, kind: String, id: String, title: String): String {
        val config = File(filesDir, "share_config.txt")
        if (!config.exists()) {
            // The app has never been opened / no file chosen yet: park it.
            File(filesDir, "pending_shares.txt").appendText("$kind\t$id\t$title\n")
            return "Saved. Open TubeBox once to finish setup."
        }
        val lines = config.readLines()
        val listFile = File(lines[0])
        val listName = lines.getOrElse(1) { "YouTube List" }.replace("\"", "")

        listFile.parentFile?.mkdirs()
        if (!listFile.exists()) listFile.writeText("#EXTM3U\n")

        val key = if (kind == "video") "video_id=$id" else "playlist_id=$id"
        if (listFile.readText().contains(key)) {
            return "Already in \"$listName\""
        }

        val logo = if (kind == "video") "https://img.youtube.com/vi/$id/hqdefault.jpg" else ""
        val kodiUrl = if (kind == "video") "plugin://plugin.video.youtube/play/?video_id=$id"
        else "plugin://plugin.video.youtube/play/?playlist_id=$id&order=default&play=1"

        listFile.appendText("\n#EXTINF:-1 group-title=\"$listName\" play-status=\"working\" tvg-logo=\"$logo\", $title\n$kodiUrl\n")
        return "Saved to \"$listName\""
    }

    private fun fetchTitle(webUrl: String): String? {
        return try {
            val api = "https://www.youtube.com/oembed?format=json&url=" + URLEncoder.encode(webUrl, "UTF-8")
            val conn = URL(api).openConnection() as HttpURLConnection
            conn.connectTimeout = 3000
            conn.readTimeout = 3000
            if (conn.responseCode != 200) return null
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            JSONObject(body).optString("title").takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        private val LOCK = Any()
    }
}
