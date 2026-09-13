package org.moonfin.nativevideo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PictureEvidenceTest {

    private val width = 1920
    private val height = 1080

    private fun evidence(): PictureEvidence = PictureEvidence().also { it.onVideoSize(width, height) }

    /** Feeds [seconds] of 25 fps video whose frames average [bytesPerFrame]. */
    private fun feed(e: PictureEvidence, seconds: Int, bytesPerFrame: Int, fromUs: Long = 0L) {
        for (i in 0 until seconds * 25) {
            e.onVideoFrame(bytesPerFrame, fromUs + i * 40_000L)
        }
    }

    @Test
    fun `nothing to say before the window fills`() {
        val e = evidence()
        feed(e, seconds = 1, bytesPerFrame = 100)
        assertNull(e.noPicture(nowMs = 1_000))
    }

    @Test
    fun `nothing to say without a frame size`() {
        val e = PictureEvidence()
        feed(e, seconds = 6, bytesPerFrame = 100)
        assertNull(e.noPicture(nowMs = 6_000))
    }

    @Test
    fun `a black placeholder carries too few bits to be a picture`() {
        // x264 on black: a few kilobytes per keyframe, a hundred bytes between.
        val e = evidence()
        feed(e, seconds = 6, bytesPerFrame = 180)
        assertEquals(true, e.noPicture(nowMs = 6_000))
    }

    @Test
    fun `a real channel carries a picture`() {
        // 2 Mbit/s at 25 fps.
        val e = evidence()
        feed(e, seconds = 6, bytesPerFrame = 10_000)
        assertEquals(false, e.noPicture(nowMs = 6_000))
    }

    @Test
    fun `a poor sd channel still carries a picture`() {
        // 400 kbit/s at 720x576: far above the threshold for its size.
        val e = PictureEvidence().also { it.onVideoSize(720, 576) }
        feed(e, seconds = 6, bytesPerFrame = 2_000)
        assertEquals(false, e.noPicture(nowMs = 6_000))
    }

    @Test
    fun `a black sd placeholder is still caught`() {
        val e = PictureEvidence().also { it.onVideoSize(720, 576) }
        feed(e, seconds = 6, bytesPerFrame = 60)
        assertEquals(true, e.noPicture(nowMs = 6_000))
    }

    @Test
    fun `a picture read on screen overrides the rate while it is fresh`() {
        val e = evidence()
        feed(e, seconds = 6, bytesPerFrame = 180)
        e.onPictureSeen(nowMs = 6_000)
        assertEquals(false, e.noPicture(nowMs = 6_000))
        assertEquals(false, e.noPicture(nowMs = 15_000))
        assertEquals(true, e.noPicture(nowMs = 17_000))
    }

    @Test
    fun `the verdict follows the stream when it collapses mid-play`() {
        val e = evidence()
        feed(e, seconds = 6, bytesPerFrame = 10_000)
        assertEquals(false, e.noPicture(nowMs = 6_000))
        feed(e, seconds = 6, bytesPerFrame = 180, fromUs = 6_000_000L)
        assertEquals(true, e.noPicture(nowMs = 12_000))
    }

    @Test
    fun `a clock that leaps back starts the window over`() {
        val e = evidence()
        feed(e, seconds = 6, bytesPerFrame = 10_000, fromUs = 100_000_000L)
        feed(e, seconds = 1, bytesPerFrame = 180, fromUs = 0L)
        assertNull(e.noPicture(nowMs = 7_000))
    }

    @Test
    fun `reset forgets the frames the size and the read`() {
        val e = evidence()
        feed(e, seconds = 6, bytesPerFrame = 10_000)
        e.onPictureSeen(nowMs = 6_000)
        e.reset()
        assertNull(e.noPicture(nowMs = 6_000))
    }
}
