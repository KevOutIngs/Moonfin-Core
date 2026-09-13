package org.moonfin.nativevideo

/**
 * Decides whether a live channel is showing a picture, from two signals
 * that are each trusted only in the direction they are reliable in.
 *
 * A tuner's failover placeholder is a black video with a sound track: it
 * decodes, renders and runs its clock like any channel, so the player sees
 * nothing wrong. Reading the screen's pixels tells the two apart on some
 * devices only: a decoder that renders through a hardware overlay leaves the
 * readable surface black while the panel shows the channel, and nothing says
 * which case a black read is. A read with something in it, on the other
 * hand, is proof of a picture. So a sample counts here only when it is not
 * black.
 *
 * The negative signal is the stream itself. A black or frozen picture
 * compresses to almost nothing, tens of kilobits a second at 1080p, where a
 * real channel carries megabits; that holds for every codec and container
 * and does not depend on the display path. The encoded size of each video
 * frame is known as it is handed to the decoder, so the bits per pixel per
 * second of media time over a short window say whether there is anything to
 * show.
 *
 * Pure and clock-agnostic: fed frames and samples with their times, asked
 * for a verdict at a time. Safe to feed from the playback thread and read
 * from the main thread.
 */
class PictureEvidence(
    /**
     * Media time a verdict is based on. Short enough to land before the
     * status tracker has counted two seconds of clean clock as a channel
     * that played; a placeholder's lone keyframe in it still reads far
     * under the floor, a real channel's P-frames alone far over it.
     */
    private val windowUs: Long = 1_500_000L,
    /**
     * Below this, the video cannot be carrying a moving picture: 200 kbit/s
     * at 1080p, 90 at 720p, 40 at SD. A black stream runs at about a fifth
     * of it whatever its size; the poorest real broadcast at three times it.
     */
    private val minBitsPerPixelPerSecond: Double = 0.1,
    /** How long one non-black read stands as proof of a picture. */
    private val seenForMs: Long = 10_000L,
) {
    private class Frame(val ptsUs: Long, val bytes: Int)

    private val frames = ArrayDeque<Frame>()

    /** Decode order is not presentation order (B-frames), so the newest PTS is tracked, not the last. */
    private var latestPtsUs = Long.MIN_VALUE
    private var width = 0
    private var height = 0
    private var lastSeenAtMs: Long? = null

    @Synchronized
    fun reset() {
        clearFrames()
        width = 0
        height = 0
        lastSeenAtMs = null
    }

    @Synchronized
    fun onVideoSize(width: Int, height: Int) {
        this.width = width
        this.height = height
    }

    /** An encoded video frame handed to the decoder. */
    @Synchronized
    fun onVideoFrame(bytes: Int, ptsUs: Long) {
        if (bytes <= 0) return
        // A clock that leaps back is a discontinuity (a new segment, a
        // timestamp wrap); the window starts over rather than spanning it.
        if (frames.isNotEmpty() && ptsUs < latestPtsUs - windowUs) clearFrames()
        frames.addLast(Frame(ptsUs, bytes))
        if (ptsUs > latestPtsUs) latestPtsUs = ptsUs
        val floor = latestPtsUs - windowUs
        while (frames.first().ptsUs < floor) frames.removeFirst()
    }

    /** A read of the screen that had something in it. Black reads are not reported. */
    @Synchronized
    fun onPictureSeen(nowMs: Long) {
        lastSeenAtMs = nowMs
    }

    @Synchronized
    fun seenRecently(nowMs: Long): Boolean = lastSeenAtMs?.let { nowMs - it <= seenForMs } ?: false

    /**
     * True when the stream cannot be showing a picture, false when it is or
     * was just seen to, null while there is not enough to say.
     */
    @Synchronized
    fun noPicture(nowMs: Long): Boolean? {
        if (seenRecently(nowMs)) return false
        if (width <= 0 || height <= 0 || spanUs() < windowUs * 3 / 4) return null
        return bitsPerPixelPerSecond() < minBitsPerPixelPerSecond
    }

    /** One line for the log: what the verdict rests on. */
    @Synchronized
    fun describe(nowMs: Long): String {
        val rate = if (spanUs() > 0 && width > 0 && height > 0) {
            "%.4f bits/px/s".format(bitsPerPixelPerSecond())
        } else {
            "no rate"
        }
        val seen = lastSeenAtMs?.let { "${nowMs - it}ms ago" } ?: "never"
        return "${width}x$height, ${frames.size} frames over ${spanUs() / 1000}ms, $rate, picture read $seen"
    }

    private fun clearFrames() {
        frames.clear()
        latestPtsUs = Long.MIN_VALUE
    }

    private fun spanUs(): Long = if (frames.isEmpty()) 0L else latestPtsUs - frames.first().ptsUs

    private fun bitsPerPixelPerSecond(): Double {
        val bits = frames.sumOf { it.bytes.toLong() } * 8.0
        return bits / (spanUs() / 1_000_000.0) / (width.toDouble() * height.toDouble())
    }
}
