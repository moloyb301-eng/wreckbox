package local.wreckbox.player

import android.content.Context

/** Loose word matching: typos, Hindi in either script, the usual spelling variants of romanised Indian names. */
object Fuzzy {
    /** Damerau–Levenshtein distance, giving up (returning limit + 1) once it's over [limit]. */
    fun distance(a: String, b: String, limit: Int = 3): Int {
        if (a == b) return 0
        if (kotlin.math.abs(a.length - b.length) > limit) return limit + 1
        val n = a.length
        val m = b.length
        var prev2 = IntArray(m + 1)
        var prev = IntArray(m + 1) { it }
        var cur = IntArray(m + 1)
        for (i in 1..n) {
            cur[0] = i
            var best = cur[0]
            for (j in 1..m) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                var v = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) v = minOf(v, prev2[j - 2] + 1)
                cur[j] = v
                if (v < best) best = v
            }
            if (best > limit) return limit + 1
            val t = prev2; prev2 = prev; prev = cur; cur = t
        }
        return prev[m]
    }

    /** One spelling for the ways a name gets romanised: "Arijeet"/"Arijit", "Pyaar"/"Pyar", "Khwaab"/"Kwab", "Shubh"/"Subh". */
    private val phonetics = java.util.concurrent.ConcurrentHashMap<String, String>()

    /** (Remembered: the same words are compared over and over — every song's title against every typed word.) */
    fun phonetic(w: String): String {
        phonetics[w]?.let { return it }
        if (phonetics.size > 50_000) phonetics.clear()
        return computePhonetic(w).also { phonetics[w] = it }
    }

    private val replacements = listOf("ee" to "i", "oo" to "u", "aa" to "a", "ii" to "i", "uu" to "u", "ph" to "f", "kh" to "k", "gh" to "g", "th" to "t",
        "dh" to "d", "bh" to "b", "jh" to "j", "ch" to "c", "sh" to "s", "w" to "v", "z" to "j", "q" to "k", "ck" to "k", "y" to "i")
    private val doubles = Regex("(.)\\1+")

    private fun computePhonetic(w: String): String {
        var s = devanagari(w)
        for ((a, b) in replacements) s = s.replace(a, b)
        s = s.replace(doubles, "$1")
        if (s.length > 3 && s.endsWith("h")) s = s.dropLast(1)
        if (s.length > 3 && s.endsWith("a")) s = s.dropLast(1)
        return s
    }

    private val consonants = mapOf(
        'क' to "k", 'ख' to "kh", 'ग' to "g", 'घ' to "gh", 'ङ' to "n", 'च' to "ch", 'छ' to "chh", 'ज' to "j", 'झ' to "jh", 'ञ' to "n",
        'ट' to "t", 'ठ' to "th", 'ड' to "d", 'ढ' to "dh", 'ण' to "n", 'त' to "t", 'थ' to "th", 'द' to "d", 'ध' to "dh", 'न' to "n",
        'प' to "p", 'फ' to "ph", 'ब' to "b", 'भ' to "bh", 'म' to "m", 'य' to "y", 'र' to "r", 'ल' to "l", 'व' to "v", 'श' to "sh",
        'ष' to "sh", 'स' to "s", 'ह' to "h",
    )
    private val vowels = mapOf('अ' to "a", 'आ' to "aa", 'इ' to "i", 'ई' to "ee", 'उ' to "u", 'ऊ' to "oo", 'ऋ' to "ri", 'ए' to "e", 'ऐ' to "ai", 'ओ' to "o", 'औ' to "au")
    private val signs = mapOf('ा' to "aa", 'ि' to "i", 'ी' to "ee", 'ु' to "u", 'ू' to "oo", 'ृ' to "ri", 'े' to "e", 'ै' to "ai", 'ो' to "o", 'ौ' to "au")

    /** Hindi (Devanagari) → Latin letters, roughly as people type it: "अरिजीत सिंह" → "arijit sinh". */
    fun devanagari(s: String): String {
        if (s.none { it in 'ऀ'..'ॿ' }) return s
        val out = StringBuilder()
        var i = 0
        // NFD splits the nukta letters (क़ = क + ़), which then read as their base letter.
        val chars = java.text.Normalizer.normalize(s, java.text.Normalizer.Form.NFD)
        while (i < chars.length) {
            val ch = chars[i]
            if (ch in consonants && chars.getOrNull(i + 1) == '\u093C') i++ // nukta: read as the base letter
            val next = chars.getOrNull(i + 1)
            when {
                ch in consonants -> {
                    out.append(consonants[ch])
                    when {
                        next == '्' -> i++ // no vowel
                        next != null && next in signs -> { out.append(signs[next]); i++ }
                        // The silent final "a" (schwa) of a word isn't typed: "सिंह" is "singh", not "singha".
                        next == null || next == ' ' || next == 'ं' && (chars.getOrNull(i + 2) == null || chars.getOrNull(i + 2) == ' ') -> {}
                        else -> out.append('a')
                    }
                }
                ch in vowels -> out.append(vowels[ch])
                ch in signs -> out.append(signs[ch])
                ch == 'ं' || ch == 'ँ' -> out.append('n')
                ch == 'ः' -> out.append('h')
                ch == '़' || ch == '्' -> {}
                else -> out.append(ch)
            }
            i++
        }
        return out.toString()
    }

    /**
     * How well one typed word matches a word of a title/artist: 1 exact, 0.9 the start of it (while typing), 0.85
     * same spelling-variant, 0.7 within a typo or two, else 0.
     */
    fun word(q: String, w: String, last: Boolean): Double {
        if (q == w) return 1.0
        if (last && q.length >= 2 && w.startsWith(q)) return 0.9
        if (q.length >= 3 && phonetic(q) == phonetic(w)) return 0.85
        if (q.length >= 4) {
            val limit = if (q.length >= 8) 2 else 1
            if (distance(q, w, limit) <= limit) return 0.7
            if (last && w.length > q.length && distance(q, w.take(q.length), 1) <= 1) return 0.6
        }
        return 0.0
    }
}

/**
 * The on-phone search index: everything you own or have touched — phone files, likes, playlists, recently played and
 * your listening history — searched instantly and offline, with typo and spelling tolerance. Rebuilt when any of those
 * change.
 */
object SearchIndex {
    private class Entry(val track: Track, val title: List<String>, val artist: List<String>, val album: List<String>, val mine: Double)

    private var entries: List<Entry> = emptyList()
    private var signature = ""

    private fun words(s: String?) = Search.norm(Fuzzy.devanagari(s ?: "")).split(' ').filter { it.isNotEmpty() }

    @Synchronized
    private fun ensure(c: Context) {
        val lib = Library.get(c).data.value
        val hist = History.get(c).data.value
        val local = runCatching { Local.cached(c) }.getOrDefault(emptyList())
        val sig = "${local.size}|${lib.likes.size}|${lib.playlists.sumOf { it.tracks.size }}|${lib.recent.firstOrNull()?.key}|${hist.songs.size}"
        if (sig == signature) return
        val liked = lib.likes.map { it.key }.toSet()
        val all = LinkedHashMap<String, Track>()
        // Phone files first: when a song is known twice, the copy kept is the one on the phone.
        (local + lib.likes + lib.playlists.flatMap { it.tracks } + lib.recent + hist.songs.values.map { it.track }).forEach { t ->
            val n = Radio.name(t)
            if (n !in all) all[n] = t
        }
        entries = all.values.map { t ->
            val st = hist.songs[Radio.name(t)]
            val mine = (if (t.key in liked) 1.0 else 0.0) + (if (t.source == Source.LOCAL) 0.4 else 0.0) + (st?.score?.coerceIn(-1.0, 4.0) ?: 0.0) * 0.25
            Entry(t, words(t.title), words(t.artist), words(t.album), mine)
        }
        signature = sig
    }

    /** Your songs matching [q], best first: every typed word must match (one may miss when you typed 3+). */
    fun search(c: Context, q: String, max: Int = 40): List<Track> {
        ensure(c)
        val qw = words(q)
        if (qw.isEmpty()) return emptyList()
        return entries.mapNotNull { e ->
            var total = 0.0
            var missed = 0
            var artistHit = false
            qw.forEachIndexed { i, w ->
                val last = i == qw.lastIndex
                val t = e.title.maxOfOrNull { Fuzzy.word(w, it, last) } ?: 0.0
                val a = e.artist.maxOfOrNull { Fuzzy.word(w, it, last) } ?: 0.0
                val al = (e.album.maxOfOrNull { Fuzzy.word(w, it, last) } ?: 0.0) * 0.8
                val best = maxOf(t, a, al)
                if (a >= 0.85 && a >= t) artistHit = true
                if (best == 0.0) missed++ else total += best
            }
            if (missed > (if (qw.size >= 3) 1 else 0)) return@mapNotNull null
            val s = total / qw.size + (if (artistHit) 0.15 else 0.0) + e.mine * 0.2 - (e.title.size - qw.size).coerceAtLeast(0) * 0.02
            e.track to s
        }.sortedByDescending { it.second }.take(max).map { it.first }
    }
}
