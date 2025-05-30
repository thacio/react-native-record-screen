package com.recordscreen

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.util.SparseIntArray
import android.view.Surface
import androidx.appcompat.app.AppCompatActivity
import com.facebook.react.bridge.*
import com.hbisoft.hbrecorder.HBRecorder
import com.hbisoft.hbrecorder.HBRecorderListener
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import kotlin.math.ceil

class RecordScreenModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext), HBRecorderListener {

  private var hbRecorder: HBRecorder? = null;
  private var screenWidth: Number = 0;
  private var screenHeight: Number = 0;
  private var mic: Boolean = true;
  private var audioOnly: Boolean = false;
  private var currentVersion: String = "";
  private var outputUri: File? = null;
  private var startPromise: Promise? = null;
  private var stopPromise: Promise? = null;

  companion object {
    private val ORIENTATIONS = SparseIntArray();
    const val SCREEN_RECORD_REQUEST_CODE = 1000;

    init {
      ORIENTATIONS.append(Surface.ROTATION_0, 90);
      ORIENTATIONS.append(Surface.ROTATION_90, 0);
      ORIENTATIONS.append(Surface.ROTATION_180, 270);
      ORIENTATIONS.append(Surface.ROTATION_270, 180);
    }
  }

  override fun getName(): String {
    return "RecordScreen"
  }

  private val mActivityEventListener: ActivityEventListener = object : BaseActivityEventListener() {
    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, intent: Intent?) {
      if (requestCode == SCREEN_RECORD_REQUEST_CODE) {
        if (resultCode == AppCompatActivity.RESULT_OK) {
          hbRecorder!!.startScreenRecording(intent, resultCode);
        } else {
          startPromise!!.resolve("permission_error");
        }
      } else {
        startPromise!!.reject("404", "cancel!");
      }
      startPromise!!.resolve("started");
    }
  }

  override fun initialize() {
    super.initialize()
    currentVersion = Build.VERSION.SDK_INT.toString()
    outputUri = reactApplicationContext.getExternalFilesDir("ReactNativeRecordScreen");
  }

  @ReactMethod
  fun setup(readableMap: ReadableMap) {
    Application().onCreate()
    screenWidth = if (readableMap.hasKey("width")) ceil(readableMap.getDouble("width")).toInt() else 0;
    screenHeight = if (readableMap.hasKey("height")) ceil(readableMap.getDouble("height")).toInt() else 0;
    mic =  if (readableMap.hasKey("mic")) readableMap.getBoolean("mic") else true;
    audioOnly = if (readableMap.hasKey("audioOnly")) readableMap.getBoolean("audioOnly") else false;

    hbRecorder = HBRecorder(reactApplicationContext, this);
    hbRecorder!!.setOutputPath(outputUri.toString());

    // For FPS and bitrate we need to enable custom settings
    if (readableMap.hasKey("fps") || readableMap.hasKey("bitrate")) {
      hbRecorder!!.enableCustomSettings();

      if (readableMap.hasKey("fps")) {
        val fps = readableMap.getInt("fps");
        hbRecorder!!.setVideoFrameRate(fps);
      }
      if (readableMap.hasKey("bitrate")) {
        val bitrate = readableMap.getInt("bitrate");
        hbRecorder!!.setVideoBitrate(bitrate);
      }
    }

    if (doesSupportEncoder("h264")) {
      hbRecorder!!.setVideoEncoder("H264");
    } else {
      hbRecorder!!.setVideoEncoder("DEFAULT");
    }
    hbRecorder!!.isAudioEnabled(mic);
    reactApplicationContext.addActivityEventListener(mActivityEventListener);
  }

  private fun startRecordingScreen() {
    val mediaProjectionManager = reactApplicationContext.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager;
    val permissionIntent = mediaProjectionManager.createScreenCaptureIntent();
    currentActivity!!.startActivityForResult(permissionIntent, SCREEN_RECORD_REQUEST_CODE);
  }


  @ReactMethod
  fun startRecording(promise: Promise) {
    startPromise = promise;
    try {
      startRecordingScreen();
      println("startRecording");
    } catch (e: IllegalStateException) {
      promise.reject("404", "error!");
      println(e.toString());
    } catch (e: IOException) {
      println(e);
      e.printStackTrace();
      promise.reject("404", "error!!");
    }
  }

  @ReactMethod
  fun stopRecording(promise: Promise) {
    stopPromise = promise
    hbRecorder!!.stopScreenRecording();
  }

  @ReactMethod
  fun clean(promise: Promise) {
    println("clean!!");
    println(outputUri);
    outputUri!!.delete();
    promise.resolve("cleaned");
  }

  override fun HBRecorderOnStart() {
    println("HBRecorderOnStart")
  }

  override fun HBRecorderOnComplete() {
    println("HBRecorderOnComplete")
    if (stopPromise != null) {
      val videoUri = hbRecorder!!.filePath;
      
      if (audioOnly) {
        // Extract audio from video
        val audioUri = extractAudioFromVideo(videoUri);
        if (audioUri != null) {
          // Delete original video file
          File(videoUri).delete();
          
          val response = WritableNativeMap();
          val result = WritableNativeMap();
          result.putString("outputURL", audioUri);
          response.putString("status", "success");
          response.putMap("result", result);
          stopPromise!!.resolve(response);
        } else {
          stopPromise!!.reject("500", "Failed to extract audio");
        }
      } else {
        // Return video as before
        val response = WritableNativeMap();
        val result = WritableNativeMap();
        result.putString("outputURL", videoUri);
        response.putString("status", "success");
        response.putMap("result", result);
        stopPromise!!.resolve(response);
      }
    }
  }

  private fun extractAudioFromVideo(videoPath: String): String? {
    try {
      // Create output file path for audio
      val audioFileName = videoPath.replace(".mp4", ".m4a");
      
      // Initialize MediaExtractor
      val extractor = MediaExtractor();
      extractor.setDataSource(videoPath);
      
      // Find audio track
      var audioTrackIndex = -1;
      var audioFormat: MediaFormat? = null;
      
      for (i in 0 until extractor.trackCount) {
        val format = extractor.getTrackFormat(i);
        val mime = format.getString(MediaFormat.KEY_MIME);
        if (mime != null && mime.startsWith("audio/")) {
          audioTrackIndex = i;
          audioFormat = format;
          break;
        }
      }
      
      if (audioTrackIndex == -1 || audioFormat == null) {
        println("No audio track found");
        return null;
      }
      
      // Select the audio track
      extractor.selectTrack(audioTrackIndex);
      
      // Create MediaMuxer for output
      val muxer = MediaMuxer(audioFileName, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
      val outputAudioTrack = muxer.addTrack(audioFormat);
      muxer.start();
      
      // Allocate buffer
      // val bufferSize = audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 100 * 1024);
      val bufferSize = if (audioFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 100 * 1024
      val buffer = ByteBuffer.allocate(bufferSize);
      val bufferInfo = MediaCodec.BufferInfo();
      
      // Extract and write audio samples
      while (true) {
        val sampleSize = extractor.readSampleData(buffer, 0);
        if (sampleSize < 0) {
          break;
        }
        
        bufferInfo.offset = 0;
        bufferInfo.size = sampleSize;
        bufferInfo.presentationTimeUs = extractor.sampleTime;
        bufferInfo.flags = extractor.sampleFlags;
        
        muxer.writeSampleData(outputAudioTrack, buffer, bufferInfo);
        extractor.advance();
      }
      
      // Clean up
      muxer.stop();
      muxer.release();
      extractor.release();
      
      return audioFileName;
      
    } catch (e: Exception) {
      println("Error extracting audio: ${e.message}");
      e.printStackTrace();
      return null;
    }
  }

  override fun HBRecorderOnError(errorCode: Int, reason: String?) {
    println("HBRecorderOnError")
    println("errorCode")
    println(errorCode)
    println("reason")
    println(reason)
  }

  override fun HBRecorderOnPause() {
    println("HBRecorderOnPause")
  }

  override fun HBRecorderOnResume() {
    println("HBRecorderOnResume")
  }

  private fun doesSupportEncoder(encoder: String): Boolean {
    val list = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
    val size = list.size
    for (i in 0 until size) {
      val codecInfo = list[i]
      if (codecInfo.isEncoder) {
        if (codecInfo!!.name.contains(encoder)) {
          return true
        }
      }
    }
    return false
  }
}