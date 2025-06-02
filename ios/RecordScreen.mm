// ios/RecordScreen.mm

#import "RecordScreen.h"
#import <React/RCTConvert.h>

@implementation RecordScreen

UIBackgroundTaskIdentifier _backgroundRenderingID;

- (NSDictionary *)errorResponse:(NSDictionary *)result;
{
    NSDictionary *json = [NSDictionary dictionaryWithObjectsAndKeys:
        @"error", @"status",
        result, @"result",nil];
    return json;

}

- (NSDictionary *) successResponse:(NSDictionary *)result;
{
    NSDictionary *json = [NSDictionary dictionaryWithObjectsAndKeys:
        @"success", @"status",
        result, @"result",nil];
    return json;

}

- (void) muteAudioInBuffer:(CMSampleBufferRef)sampleBuffer
{

    CMItemCount numSamples = CMSampleBufferGetNumSamples(sampleBuffer);
    NSUInteger channelIndex = 0;

    CMBlockBufferRef audioBlockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t audioBlockBufferOffset = (channelIndex * numSamples * sizeof(SInt16));
    size_t lengthAtOffset = 0;
    size_t totalLength = 0;
    SInt16 *samples = NULL;
    CMBlockBufferGetDataPointer(audioBlockBuffer, audioBlockBufferOffset, &lengthAtOffset, &totalLength, (char **)(&samples));

    for (NSInteger i=0; i<numSamples; i++) {
        samples[i] = (SInt16)0;
    }
}

// For H264, unless the value is a multiple of 2 or 4, a green border will appear, so a function to adjust it
- (int) adjustMultipleOf2:(int)value;
{
    if (value % 2 == 1) {
        return value + 1;
    }
    return value;
}


RCT_EXPORT_MODULE()

RCT_EXPORT_METHOD(setup: (NSDictionary *)config)
{
    self.screenWidth = [RCTConvert int: config[@"width"]];
    self.screenHeight = [RCTConvert int: config[@"height"]];
    self.enableMic = [RCTConvert BOOL: config[@"mic"]];
    self.bitrate = [RCTConvert int: config[@"bitrate"]];
    self.fps = [RCTConvert int: config[@"fps"]];
    self.audioOnly = config[@"audioOnly"] ? [RCTConvert BOOL: config[@"audioOnly"]] : NO;
    self.useBroadcast = config[@"broadcast"] ? [RCTConvert BOOL: config[@"broadcast"]] : NO;
}

RCT_EXPORT_METHOD(startBroadcastRecording: (RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 12.0, *)) {
            // Get the root view controller
            UIViewController *rootViewController = nil;
            UIWindow *window = [UIApplication sharedApplication].keyWindow;
            
            // Try to find the topmost view controller
            if (window) {
                rootViewController = window.rootViewController;
                while (rootViewController.presentedViewController) {
                    rootViewController = rootViewController.presentedViewController;
                }
            }
            
            if (!rootViewController) {
                // Fallback: try to get any available window
                for (UIWindow *w in [UIApplication sharedApplication].windows) {
                    if (w.rootViewController) {
                        rootViewController = w.rootViewController;
                        break;
                    }
                }
            }
            
            if (!rootViewController) {
                reject(@"no_root_view", @"Could not find root view controller", nil);
                return;
            }
            
            // Create the broadcast picker
            self.broadcastPicker = [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
            
            // Set preferred extension to nil to use system's Photos recorder
            self.broadcastPicker.preferredExtension = nil;
            self.broadcastPicker.showsMicrophoneButton = self.enableMic;
            
            // Add it to the view hierarchy (invisible)
            self.broadcastPicker.alpha = 0.01;
            [rootViewController.view addSubview:self.broadcastPicker];
            
            // Programmatically trigger the picker
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BOOL buttonFound = NO;
                for (UIView *subview in self.broadcastPicker.subviews) {
                    if ([subview isKindOfClass:[UIButton class]]) {
                        UIButton *button = (UIButton *)subview;
                        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
                        buttonFound = YES;
                        break;
                    }
                }
                
                if (!buttonFound) {
                    [self.broadcastPicker removeFromSuperview];
                    self.broadcastPicker = nil;
                    reject(@"button_not_found", @"Could not find broadcast button", nil);
                    return;
                }
                
                // Clean up the picker after a delay
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self.broadcastPicker removeFromSuperview];
                    self.broadcastPicker = nil;
                });
                
                resolve(@{
                    @"status": @"broadcast_picker_shown",
                    @"message": @"System broadcast picker presented. User must tap 'Start Recording' and stop from Control Center."
                });
            });
        } else {
            reject(@"not_available", @"System broadcast recording requires iOS 12.0 or later", nil);
        }
    });
}

RCT_EXPORT_METHOD(isBroadcasting:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{
    // Note: There's no direct API to check if system broadcast is active
    // This is a limitation of the broadcast approach
    resolve(@{@"broadcasting": @NO, @"message": @"Cannot determine broadcast status. Check for red status bar indicator."});
}

RCT_REMAP_METHOD(startRecording, resolve:(RCTPromiseResolveBlock)resolve rejecte:(RCTPromiseRejectBlock)reject)
{
    // If broadcast mode is enabled, use the broadcast picker instead
    if (self.useBroadcast) {
        [self startBroadcastRecording:resolve reject:reject];
        return;
    }
    
    // Otherwise, continue with the existing in-app recording code
    UIApplication *app = [UIApplication sharedApplication];
    _backgroundRenderingID = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:_backgroundRenderingID];
        _backgroundRenderingID = UIBackgroundTaskInvalid;
    }];

    self.screenRecorder = [RPScreenRecorder sharedRecorder];
    if (self.screenRecorder.isRecording) {
        return;
    }

    self.encounteredFirstBuffer = NO;

    NSArray *pathDocuments = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *outputURL = pathDocuments[0];

    NSString *fileExtension = self.audioOnly ? @"m4a" : @"mp4";
    NSString *outputPath = [[outputURL stringByAppendingPathComponent:[NSString stringWithFormat:@"%u", arc4random() % 1000]] stringByAppendingPathExtension:fileExtension];

    NSError *error;
    AVFileType fileType = self.audioOnly ? AVFileTypeAppleM4A : AVFileTypeMPEG4;
    self.writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:outputPath] fileType:fileType error:&error];
    if (!self.writer) {
        NSLog(@"writer: %@", error);
        abort();
    }

    AudioChannelLayout acl = { 0 };
    acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    self.audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:@{ AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(44100),  AVChannelLayoutKey: [NSData dataWithBytes: &acl length: sizeof( acl ) ], AVEncoderBitRateKey: @(64000)}];
    self.audioInput.expectsMediaDataInRealTime = YES;
    self.micInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:@{ AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(44100),  AVChannelLayoutKey: [NSData dataWithBytes: &acl length: sizeof( acl ) ], AVEncoderBitRateKey: @(64000)}];
    self.micInput.expectsMediaDataInRealTime   = YES;

    self.audioInput.preferredVolume = 1.0;
    self.micInput.preferredVolume = 0.0;

    [self.writer addInput:self.audioInput];
    if (self.enableMic) {
        [self.writer addInput:self.micInput];
    }

    // Only add video input if not audio-only mode
    if (!self.audioOnly) {
        NSDictionary *compressionProperties = @{AVVideoProfileLevelKey         : AVVideoProfileLevelH264HighAutoLevel,
                                                AVVideoH264EntropyModeKey      : AVVideoH264EntropyModeCABAC,
                                                AVVideoAverageBitRateKey       : @(self.bitrate),
                                                AVVideoMaxKeyFrameIntervalKey  : @(self.fps),
                                                AVVideoAllowFrameReorderingKey : @NO};

        NSLog(@"width: %d", [self adjustMultipleOf2:self.screenWidth]);
        NSLog(@"height: %d", [self adjustMultipleOf2:self.screenHeight]);
        if (@available(iOS 11.0, *)) {
            NSDictionary *videoSettings = @{AVVideoCompressionPropertiesKey : compressionProperties,
                                            AVVideoCodecKey                 : AVVideoCodecTypeH264,
                                            AVVideoWidthKey                 : @([self adjustMultipleOf2:self.screenWidth]),
                                            AVVideoHeightKey                : @([self adjustMultipleOf2:self.screenHeight])};

            self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
            [self.writer addInput:self.videoInput];
            [self.videoInput setMediaTimeScale:60];
            [self.videoInput setExpectsMediaDataInRealTime:YES];
        }
    }

    [self.writer setMovieTimeScale:60];

    if (self.screenRecorder.microphoneEnabled != self.enableMic) {
        self.screenRecorder.microphoneEnabled = self.enableMic;
    }

    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        if (granted) {
            if (@available(iOS 11.0, *)) {
                [self.screenRecorder startCaptureWithHandler:^(CMSampleBufferRef sampleBuffer, RPSampleBufferType bufferType, NSError* error) {
                    // Failure to do so will result in a memory error when accessing the sampleBuffer in the main thread.
                    CFRetain(sampleBuffer);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (CMSampleBufferDataIsReady(sampleBuffer)) {
                            // For audio-only mode, start on first audio buffer
                            BOOL shouldStartWriting = NO;
                            if (self.audioOnly) {
                                shouldStartWriting = self.writer.status == AVAssetWriterStatusUnknown && !self.encounteredFirstBuffer &&
                                                   (bufferType == RPSampleBufferTypeAudioApp || bufferType == RPSampleBufferTypeAudioMic);
                            } else {
                                shouldStartWriting = self.writer.status == AVAssetWriterStatusUnknown && !self.encounteredFirstBuffer &&
                                                   bufferType == RPSampleBufferTypeVideo;
                            }

                            if (shouldStartWriting) {
                                self.encounteredFirstBuffer = YES;
                                NSLog(@"First buffer %@", self.audioOnly ? @"audio" : @"video");
                                [self.writer startWriting];
                                [self.writer startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
                            } else if (self.writer.status == AVAssetWriterStatusFailed) {

                            }

                            if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground) {
                                CMSampleBufferRef copiedBuffer;
                                CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &copiedBuffer);
                                switch (bufferType) {
                                    case RPSampleBufferTypeVideo:
                                        if (!self.audioOnly) {
                                            self.afterAppBackgroundVideoSampleBuffer = copiedBuffer;
                                        }
                                        break;
                                    case RPSampleBufferTypeAudioApp:
                                        self.afterAppBackgroundAudioSampleBuffer = copiedBuffer;
                                        break;
                                    case RPSampleBufferTypeAudioMic:
                                        self.afterAppBackgroundMicSampleBuffer = copiedBuffer;
                                        break;
                                    default:
                                        break;
                                }
                            } else if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) {
                                if (!self.audioOnly && bufferType == RPSampleBufferTypeVideo && self.afterAppBackgroundVideoSampleBuffer != nil && self.afterAppBackgroundAudioSampleBuffer != nil && self.afterAppBackgroundMicSampleBuffer != nil) {
                                    CMTime timeWhenAppBackground = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), CMSampleBufferGetPresentationTimeStamp(self.afterAppBackgroundVideoSampleBuffer));
                                    // Calc loop count for appendSampleBuffer.
                                    long bufferCount = floor(CMTimeGetSeconds(timeWhenAppBackground) * (1 / CMTimeGetSeconds(CMSampleBufferGetDuration(self.afterAppBackgroundAudioSampleBuffer))));

                                    // Make mute audio.
                                    [self muteAudioInBuffer:self.afterAppBackgroundAudioSampleBuffer];
                                    [self muteAudioInBuffer:self.afterAppBackgroundMicSampleBuffer];

                                    for (int i = 0; i < bufferCount; i ++) {
                                        if (self.audioInput.isReadyForMoreMediaData) {
                                            [self.audioInput appendSampleBuffer:self.afterAppBackgroundAudioSampleBuffer];
                                        }
                                    }
                                    for (int i = 0; i < bufferCount; i ++) {
                                        if (self.enableMic && self.micInput.isReadyForMoreMediaData) {
                                            [self.micInput appendSampleBuffer:self.afterAppBackgroundMicSampleBuffer];
                                        }
                                    }

                                    // Clean
                                    CFRelease(self.afterAppBackgroundAudioSampleBuffer);
                                    CFRelease(self.afterAppBackgroundMicSampleBuffer);
                                    CFRelease(self.afterAppBackgroundVideoSampleBuffer);
                                    self.afterAppBackgroundAudioSampleBuffer = nil;
                                    self.afterAppBackgroundMicSampleBuffer = nil;
                                    self.afterAppBackgroundVideoSampleBuffer = nil;
                                }
                            }

                            if (self.writer.status == AVAssetWriterStatusWriting) {
                                switch (bufferType) {
                                    case RPSampleBufferTypeVideo:
                                        if (!self.audioOnly && self.videoInput.isReadyForMoreMediaData) {
                                            [self.videoInput appendSampleBuffer:sampleBuffer];
                                        }
                                        break;
                                    case RPSampleBufferTypeAudioApp:
                                        if (self.audioInput.isReadyForMoreMediaData) {
                                            [self.audioInput appendSampleBuffer:sampleBuffer];
                                        }
                                        break;
                                    case RPSampleBufferTypeAudioMic:
                                        if (self.enableMic && self.micInput.isReadyForMoreMediaData) {
                                            [self.micInput appendSampleBuffer:sampleBuffer];
                                        }
                                        break;
                                    default:
                                        break;
                                }
                            }
                        }

                        CFRelease(sampleBuffer);
                    });
                } completionHandler:^(NSError* error) {
                    NSLog(@"startCapture: %@", error);
                    if (error) {
                        resolve(@"permission_error");
                    } else {
                        resolve(@"started");
                    }
                }];
            } else {
                // Fallback on earlier versions
            }
        } else {
            NSError* err = nil;
            reject(0, @"Permission denied", err);
        }
    }];
}

RCT_REMAP_METHOD(stopRecording, resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
    [[UIApplication sharedApplication] endBackgroundTask:_backgroundRenderingID];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 11.0, *)) {
            [[RPScreenRecorder sharedRecorder] stopCaptureWithHandler:^(NSError * _Nullable error) {
                if (!error) {
                    [self.audioInput markAsFinished];
                    if (self.enableMic) {
                        [self.micInput markAsFinished];
                    }
                    if (!self.audioOnly) {
                        [self.videoInput markAsFinished];
                    }
                    [self.writer finishWritingWithCompletionHandler:^{

                        NSDictionary *result = [NSDictionary dictionaryWithObject:self.writer.outputURL.absoluteString forKey:@"outputURL"];
                        resolve([self successResponse:result]);

                        NSLog(@"finishWritingWithCompletionHandler: Recording stopped successfully. Cleaning up... %@", result);
                        self.audioInput = nil;
                        self.micInput = nil;
                        self.videoInput = nil;
                        self.writer = nil;
                        self.screenRecorder = nil;
                    }];
                }
            }];
        } else {
            // Fallback on earlier versions
        }
    });
}

RCT_REMAP_METHOD(clean,
                 cleanResolve:(RCTPromiseResolveBlock)resolve
                 cleanRejecte:(RCTPromiseRejectBlock)reject)
{

    NSArray *pathDocuments = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *path = pathDocuments[0];
    NSLog(@"startCapture: %@", path);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    resolve(@"cleaned");
}

// Don't compile this code when we build for the old architecture.
#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeRecordScreenSpecJSI>(params);
}
#endif

@end
