package org.moonfin.nativevideo

import android.media.MediaCodec
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter

/**
 * Reports the encoded size and timestamp of every video frame handed to a
 * decoder, by wrapping the adapter the video renderer talks to its codec
 * through. Audio codecs pass through untouched. Codec configuration buffers
 * and the end-of-stream marker are not frames and are not reported.
 *
 * The callback runs on the playback thread.
 */
@UnstableApi
class VideoFrameMeter(
    private val inner: MediaCodecAdapter.Factory,
    private val onVideoFrame: (bytes: Int, presentationTimeUs: Long) -> Unit,
) : MediaCodecAdapter.Factory {
    override fun createAdapter(configuration: MediaCodecAdapter.Configuration): MediaCodecAdapter {
        val adapter = inner.createAdapter(configuration)
        if (!MimeTypes.isVideo(configuration.format.sampleMimeType)) return adapter
        return Metered(adapter, onVideoFrame)
    }

    private class Metered(
        private val adapter: MediaCodecAdapter,
        private val onVideoFrame: (Int, Long) -> Unit,
    ) : MediaCodecAdapter by adapter {
        override fun queueInputBuffer(
            index: Int,
            offset: Int,
            size: Int,
            presentationTimeUs: Long,
            flags: Int,
        ) {
            if (flags and (MediaCodec.BUFFER_FLAG_CODEC_CONFIG or MediaCodec.BUFFER_FLAG_END_OF_STREAM) == 0) {
                onVideoFrame(size, presentationTimeUs)
            }
            adapter.queueInputBuffer(index, offset, size, presentationTimeUs, flags)
        }
    }
}
