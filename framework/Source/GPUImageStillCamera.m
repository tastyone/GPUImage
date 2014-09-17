// 2448x3264 pixel image = 31,961,088 bytes for uncompressed RGBA

#import "GPUImageStillCamera.h"

void stillImageDataReleaseCallback(void *releaseRefCon, const void *baseAddress)
{
    free((void *)baseAddress);
}

void GPUImageCreateResizedSampleBuffer(CVPixelBufferRef cameraFrame, CGSize finalSize, CMSampleBufferRef *sampleBuffer)
{
    // CVPixelBufferCreateWithPlanarBytes for YUV input
    
    CGSize originalSize = CGSizeMake(CVPixelBufferGetWidth(cameraFrame), CVPixelBufferGetHeight(cameraFrame));

    CVPixelBufferLockBaseAddress(cameraFrame, 0);
    GLubyte *sourceImageBytes =  CVPixelBufferGetBaseAddress(cameraFrame);
    CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, sourceImageBytes, CVPixelBufferGetBytesPerRow(cameraFrame) * originalSize.height, NULL);
    CGColorSpaceRef genericRGBColorspace = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImageFromBytes = CGImageCreate((int)originalSize.width, (int)originalSize.height, 8, 32, CVPixelBufferGetBytesPerRow(cameraFrame), genericRGBColorspace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, dataProvider, NULL, NO, kCGRenderingIntentDefault);
    
    GLubyte *imageData = (GLubyte *) calloc(1, (int)finalSize.width * (int)finalSize.height * 4);
    
    CGContextRef imageContext = CGBitmapContextCreate(imageData, (int)finalSize.width, (int)finalSize.height, 8, (int)finalSize.width * 4, genericRGBColorspace,  kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextDrawImage(imageContext, CGRectMake(0.0, 0.0, finalSize.width, finalSize.height), cgImageFromBytes);
    CGImageRelease(cgImageFromBytes);
    CGContextRelease(imageContext);
    CGColorSpaceRelease(genericRGBColorspace);
    CGDataProviderRelease(dataProvider);
    
    CVPixelBufferRef pixel_buffer = NULL;
    CVPixelBufferCreateWithBytes(kCFAllocatorDefault, finalSize.width, finalSize.height, kCVPixelFormatType_32BGRA, imageData, finalSize.width * 4, stillImageDataReleaseCallback, NULL, NULL, &pixel_buffer);
    CMVideoFormatDescriptionRef videoInfo = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel_buffer, &videoInfo);
    
    CMTime frameTime = CMTimeMake(1, 30);
    CMSampleTimingInfo timing = {frameTime, frameTime, kCMTimeInvalid};
    
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, YES, NULL, NULL, videoInfo, &timing, sampleBuffer);
    CFRelease(videoInfo);
    CVPixelBufferRelease(pixel_buffer);
}

@interface GPUImageStillCamera ()
{
    AVCaptureStillImageOutput *photoOutput;
}

// Methods calling this are responsible for calling dispatch_semaphore_signal(frameRenderingSemaphore) somewhere inside the block
- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withImageOnGPUHandler:(void (^)(NSError *error))block;

@end

@implementation GPUImageStillCamera {
    BOOL requiresFrontCameraTextureCacheCorruptionWorkaround;
}

@synthesize currentCaptureMetadata = _currentCaptureMetadata;
@synthesize jpegCompressionQuality = _jpegCompressionQuality;
@synthesize stillPhotoOutput = photoOutput;
@synthesize _requiresFrontCameraTextureCacheCorruptionWorkaround = requiresFrontCameraTextureCacheCorruptionWorkaround;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithSessionPreset:(NSString *)sessionPreset cameraPosition:(AVCaptureDevicePosition)cameraPosition;
{
    if (!(self = [super initWithSessionPreset:sessionPreset cameraPosition:cameraPosition]))
    {
		return nil;
    }
    
    /* Detect iOS version < 6 which require a texture cache corruption workaround */
    requiresFrontCameraTextureCacheCorruptionWorkaround = [[[UIDevice currentDevice] systemVersion] compare:@"6.0" options:NSNumericSearch] == NSOrderedAscending;
    
    [self.captureSession beginConfiguration];
    
    photoOutput = [[AVCaptureStillImageOutput alloc] init];
   
    // Having a still photo input set to BGRA and video to YUV doesn't work well, so since I don't have YUV resizing for iPhone 4 yet, kick back to BGRA for that device
//    if (captureAsYUV && [GPUImageContext supportsFastTextureUpload])
    if (captureAsYUV && [GPUImageContext deviceSupportsRedTextures])
    {
        BOOL supportsFullYUVRange = NO;
        NSArray *supportedPixelFormats = photoOutput.availableImageDataCVPixelFormatTypes;
        for (NSNumber *currentPixelFormat in supportedPixelFormats)
        {
            if ([currentPixelFormat intValue] == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            {
                supportsFullYUVRange = YES;
            }
        }
        
        if (supportsFullYUVRange)
        {
            [photoOutput setOutputSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
        }
        else
        {
            [photoOutput setOutputSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
        }
    }
    else
    {
        captureAsYUV = NO;
        [photoOutput setOutputSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
        [videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    }
    
//    if (captureAsYUV && [GPUImageContext deviceSupportsRedTextures])
//    {
//        // TODO: Check for full range output and use that if available
//        [photoOutput setOutputSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
//    }
//    else
//    {
//        [photoOutput setOutputSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
//    }

    [self.captureSession addOutput:photoOutput];
    
    [self.captureSession commitConfiguration];
    
    self.jpegCompressionQuality = 0.8;
    
    return self;
}

- (id)init;
{
    if (!(self = [self initWithSessionPreset:AVCaptureSessionPresetPhoto cameraPosition:AVCaptureDevicePositionBack]))
    {
		return nil;
    }
    return self;
}

- (void)removeInputsAndOutputs;
{
    [self.captureSession removeOutput:photoOutput];
    [super removeInputsAndOutputs];
}

#pragma mark -
#pragma mark Photography controls

- (void)capturePhotoAsSampleBufferWithCompletionHandler:(void (^)(CMSampleBufferRef imageSampleBuffer, NSError *error))block
{
    NSLog(@"If you want to use the method capturePhotoAsSampleBufferWithCompletionHandler:, you must comment out the line in GPUImageStillCamera.m in the method initWithSessionPreset:cameraPosition: which sets the CVPixelBufferPixelFormatTypeKey, as well as uncomment the rest of the method capturePhotoAsSampleBufferWithCompletionHandler:. However, if you do this you cannot use any of the photo capture methods to take a photo if you also supply a filter.");
    
    /*dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
    
    [photoOutput captureStillImageAsynchronouslyFromConnection:[[photoOutput connections] objectAtIndex:0] completionHandler:^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        block(imageSampleBuffer, error);
    }];
     
     dispatch_semaphore_signal(frameRenderingSemaphore);

     */
    
    return;
}

- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withImageOrientation:(UIImageOrientation)imageOrientation withCompletionHandler:(void (^)(UIImage *processedImage, NSError *error))block;
{
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        UIImage *filteredPhoto = nil;
        
        if(!error){
            filteredPhoto = [finalFilterInChain imageFromCurrentlyProcessedOutputWithOrientation:imageOrientation];
        }
        dispatch_semaphore_signal(frameRenderingSemaphore);
        
        block(filteredPhoto, error);
    }];
}

- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(UIImage *processedImage, NSError *error))block;
{
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        UIImage *filteredPhoto = nil;

        if(!error){
            filteredPhoto = [finalFilterInChain imageFromCurrentlyProcessedOutput];
        }
        dispatch_semaphore_signal(frameRenderingSemaphore);

        block(filteredPhoto, error);
    }];
}

- (void)capturePhotoAsJPEGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(NSData *processedJPEG, NSError *error))block;
{
//    reportAvailableMemoryForGPUImage(@"Before Capture");

    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForJPEGFile = nil;

        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentlyProcessedOutput];
                dispatch_semaphore_signal(frameRenderingSemaphore);
//                reportAvailableMemoryForGPUImage(@"After UIImage generation");

                dataForJPEGFile = UIImageJPEGRepresentation(filteredPhoto,self.jpegCompressionQuality);
//                reportAvailableMemoryForGPUImage(@"After JPEG generation");
            }

//            reportAvailableMemoryForGPUImage(@"After autorelease pool");
        }else{
            dispatch_semaphore_signal(frameRenderingSemaphore);
        }

        block(dataForJPEGFile, error);
    }];
}

- (void)capturePhotoAsPNGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(NSData *processedPNG, NSError *error))block;
{

    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForPNGFile = nil;

        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentlyProcessedOutput];
                dispatch_semaphore_signal(frameRenderingSemaphore);
                dataForPNGFile = UIImagePNGRepresentation(filteredPhoto);
            }
        }else{
            dispatch_semaphore_signal(frameRenderingSemaphore);
        }
        
        block(dataForPNGFile, error);        
    }];
    
    return;
}

#pragma mark - Private Methods

- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withImageOnGPUHandler:(void (^)(NSError *error))block
{
    dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);

    if(photoOutput.isCapturingStillImage){
        block([NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorMaximumStillImageCaptureRequestsExceeded userInfo:nil]);
        return;
    }

//    [self pauseCameraCapture]; // by tastyone
//    [finalFilterInChain prepareForImageCapture]; // by tastyone
    
#ifdef DEBUG
    NSLog(@"is mainThread: %d", [NSThread isMainThread]);
    reportAvailableMemoryForGPUImage_InMB(@"before captureStillImage");
#endif
    
    [photoOutput captureStillImageAsynchronouslyFromConnection:[[photoOutput connections] objectAtIndex:0] completionHandler:^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        if(imageSampleBuffer == NULL){
            block(error);
            return;
        }
        
#ifdef DEBUG
        reportAvailableMemoryForGPUImage_InMB(@"after captureStillImage");
#endif
        
//        [finalFilterInChain prepareForImageCapture]; // by tastyone
        if ( self.pauseSessionWhenCaptureStillPhoto ) {
            [self pauseCameraCapture]; // by tastyone
        } else {
            [self stopCameraCapture]; // by tastyone
        }

#ifdef DEBUG
        reportAvailableMemoryForGPUImage_InMB(@"after stopCameraSession");
#endif
        
        [self conserveMemoryForNextFrame];

        // For now, resize photos to fix within the max texture size of the GPU
        CVImageBufferRef cameraFrame = CMSampleBufferGetImageBuffer(imageSampleBuffer);
        
        CGSize sizeOfPhoto = CGSizeMake(CVPixelBufferGetWidth(cameraFrame), CVPixelBufferGetHeight(cameraFrame));
        CGSize scaledImageSizeToFitOnGPU = [GPUImageContext sizeThatFitsWithinATextureForSize:sizeOfPhoto];
        if (!CGSizeEqualToSize(sizeOfPhoto, scaledImageSizeToFitOnGPU))
        {
            CMSampleBufferRef sampleBuffer = NULL;
            
            if (CVPixelBufferGetPlaneCount(cameraFrame) > 0)
            {
                NSAssert(NO, @"Error: no downsampling for YUV input in the framework yet");
            }
            else
            {
                GPUImageCreateResizedSampleBuffer(cameraFrame, scaledImageSizeToFitOnGPU, &sampleBuffer);
            }

#ifdef DEBUG
            NSLog(@"Not tested!!!");
            abort();
#endif
#ifdef SHOW_STILL_CAPTURE_DEBUG
            NSLog(@"still process. A 1 - sizeOfPhoto: %@ - %p", NSStringFromCGSize(sizeOfPhoto), imageSampleBuffer);
#endif
            runSynchronouslyOnVideoProcessingQueue(^{
                [self processVideoSampleBufferForcely:imageSampleBuffer];
            });
#ifdef SHOW_STILL_CAPTURE_DEBUG
            NSLog(@"still process. A 2");
#endif
//            dispatch_semaphore_signal(frameRenderingSemaphore);
//            [self captureOutput:photoOutput didOutputSampleBuffer:sampleBuffer fromConnection:[[photoOutput connections] objectAtIndex:0]];
//            dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
            if (sampleBuffer != NULL)
                CFRelease(sampleBuffer);
        }
        else
        {
            // This is a workaround for the corrupt images that are sometimes returned when taking a photo with the front camera and using the iOS 5.0 texture caches
            AVCaptureDevicePosition currentCameraPosition = [[videoInput device] position];
            if ( (currentCameraPosition != AVCaptureDevicePositionFront) || (![GPUImageContext supportsFastTextureUpload]) || !requiresFrontCameraTextureCacheCorruptionWorkaround)
            {
#ifdef SHOW_STILL_CAPTURE_DEBUG
                NSLog(@"still process. 1 - sizeOfPhoto: %@ - %p", NSStringFromCGSize(sizeOfPhoto), imageSampleBuffer);
#endif
                runSynchronouslyOnVideoProcessingQueue(^{
                    [self processVideoSampleBufferForcely:imageSampleBuffer];
                });
#ifdef SHOW_STILL_CAPTURE_DEBUG
                NSLog(@"still process. 2");
#endif
//                dispatch_semaphore_signal(frameRenderingSemaphore);
//                NSLog(@"still process. 1 - sizeOfPhoto: %@ - %p", NSStringFromCGSize(sizeOfPhoto), imageSampleBuffer);
//                [self captureOutput:photoOutput didOutputSampleBuffer:imageSampleBuffer fromConnection:[[photoOutput connections] objectAtIndex:0]];
//                NSLog(@"still process. 2");
////                [self processVideoSampleBuffer:imageSampleBuffer];
//                dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
            }
        }
        
        CFDictionaryRef metadata = CMCopyDictionaryOfAttachments(NULL, imageSampleBuffer, kCMAttachmentMode_ShouldPropagate);
        self.currentCaptureMetadata = (__bridge_transfer NSDictionary *)metadata;

//        [self pauseCameraCapture]; // by tastyone
        block(nil);

//        _currentCaptureMetadata = nil;
    }];
}


//// 이게 레알..
//- (void)capturePhotoStartWithLens:(RELens *)lens
//             withImageOrientation:(UIImageOrientation)imageOrientation
//            withCompletionHandler:(void (^)(UIImage *processedImage, NSDictionary *metadata, NSError *error))block
//{
////    //    [lens setFlipSizeForRatio:YES];
////    [(LSLookupLens*)lens setHighResolutionMode:YES];
////    [lens unloadLens];
////    
////    if ( self.isFrontFacingCamera ) {
////        [lens setInputRotation:kGPUImageRotateRightFlipVertical];
////    } else {
////        [lens setInputRotation:kGPUImageRotateRight];
////    }
//    
//    dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
//    
//    [photoOutput captureStillImageAsynchronouslyFromConnection:[[photoOutput connections] objectAtIndex:0] completionHandler:^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
//        //        dispatch_async([GPUImageOpenGLESContext sharedOpenGLESQueue], ^{
//        [self stopCameraCapture];
//        //        });
//        
//        //#ifdef DEBUG
//        // For now, resize photos to fix within the max texture size of the GPU
//        CVImageBufferRef cameraFrame = CMSampleBufferGetImageBuffer(imageSampleBuffer);
//        //        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(imageSampleBuffer);
//        CVPixelBufferLockBaseAddress(cameraFrame,0);
//        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(cameraFrame);
//        size_t width = CVPixelBufferGetWidth(cameraFrame);
//        size_t height = CVPixelBufferGetHeight(cameraFrame);
//        NSLog(@"    bytesPerRow: %lu, width: %lu, height: %lu", bytesPerRow, width, height);
//        CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
//        //#endif
//        
//        
//        /* Second method */
//        
//        CGImageRef image = NULL;
//        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(imageSampleBuffer);
//        if (imageBuffer && (CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess)) {
//            size_t width = CVPixelBufferGetWidth(imageBuffer);
//            size_t height = CVPixelBufferGetHeight(imageBuffer);
//            void* bytes = CVPixelBufferGetBaseAddress(imageBuffer);
//            size_t length = CVPixelBufferGetDataSize(imageBuffer);
//            size_t rowBytes = CVPixelBufferGetBytesPerRow(imageBuffer);
//            CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bytes, length, NULL);
//            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
//            image = CGImageCreate(width, height, 8, 32, rowBytes, colorSpace,
//                                  kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, //kCGBitmapByteOrder32Host,
//                                  provider, NULL, true, kCGRenderingIntentDefault);
//            CGColorSpaceRelease(colorSpace);
//            CGDataProviderRelease(provider);
//            CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
//#ifdef DEBUG
//            NSLog(@"CGImageCreated size: %zdx%zd", width, height);
//#endif
//        } else {
//#ifdef DEBUG
//            NSLog(@"ERROR!!!!!!");
//            abort();
//#endif
//            
//#ifdef RETRO_VERSION
//            [(LSLookupLens*)lens setHighResolutionMode:NO];
//            [lens unloadLens];
//#endif
//            block(nil, nil, error);
//            return ;
//        }
//        
//#ifdef DEBUG
//        NSLog(@"Before filter processing2 - imageRef created: %@(%zdx%zd), %ld", image, CGImageGetWidth(image), CGImageGetHeight(image), CFGetRetainCount(image));
//        [Common print_free_memory];
//#endif
//        UIImage* filteredPhoto = nil;
//        
//        @autoreleasepool {
//            CGImageRef imageRef = NULL;
//            
//            dispatch_semaphore_signal(frameRenderingSemaphore);
//            dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
//            
//#ifdef DEBUG
//            report_memory_in_mb(@"Before filter-chain processing");
//            [Common print_free_memory];
//#endif
//            
//            //            [lens setInputSize:CGSizeMake(height, width) atIndex:0];
//            [lens setInputSize:CGSizeMake(width, height) atIndex:0];
//            //            [lens setInputSize:CGSizeMake(width, height)];
//            
//            /* duplicate 안하는 방법 */
//            imageRef = [lens newCGImageByFilteringCGImage:image orientation:imageOrientation];
//            
//            /* duplicate 하는 방법 */
//            //#ifdef RETRO_VERSION
//            //            __block LSLookupLens* newLens = nil;
//            //            runSynchronouslyOnVideoProcessingQueue(^{
//            //                newLens = (LSLookupLens*)[lens duplicate];
//            //                [newLens prepareForImageCapture];
//            //                if ( newLens.useBlurFilter ) {
//            //                    [newLens setBlurFilterInputSize:[(LSLookupLens*)lens getBlurFilterInputSize]];
//            //                }
//            //            });
//            //#else
//            //            LSLens* newLens = [lens duplicate];
//            //            [newLens prepareForImageCapture];
//            //#endif
//            //
//            //#ifdef DEBUG
//            //            NSLog(@"   lens duplicated: %@", newLens);
//            //            [Common print_free_memory];
//            //#endif
//            //            imageRef = [newLens newCGImageByFilteringCGImage:image orientation:imageOrientation];
//            //            newLens = nil;
//            
//#ifdef DEBUG
//            report_memory_in_mb(@"After filter processing2");
//            [Common print_free_memory];
//#endif
//            
//            // 여기서 orientation 적용하여, 세우는 일이 일어난다!!!
//            filteredPhoto = [UIImage imageWithCGImage:imageRef scale:1.0 orientation:imageOrientation];
//#ifdef DEBUG
//            NSLog(@"UIImage generated, imageRef will release: %@, %ld, size: %@ (%zdx%zd), ori: %d (%d)", imageRef, CFGetRetainCount(imageRef),
//                  NSStringFromCGSize(filteredPhoto.size),
//                  CGImageGetWidth(imageRef), CGImageGetHeight(imageRef), imageOrientation, filteredPhoto.imageOrientation);
//            [Common print_free_memory];
//#endif
//            CGImageRelease(imageRef); imageRef = NULL;
//            
//            dispatch_semaphore_signal(frameRenderingSemaphore);
//        }
//        
//#ifdef DEBUG
//        NSLog(@"UIImage generated, image will release: %@, %ld", image, CFGetRetainCount(image));
//        [Common print_free_memory];
//#endif
//        CGImageRelease(image); image = NULL;
//        
//#ifdef DEBUG
//        report_memory_in_mb(@"After Autoreleasing");
//        [Common print_free_memory];
//#endif
//        // orientation 문제 해결해볼꽈?
//        if ( imageOrientation == UIImageOrientationRightMirrored || imageOrientation == UIImageOrientationLeftMirrored ) {
//            NSLog(@"Issueing orientation: %d (%d)", imageOrientation, filteredPhoto.imageOrientation);
//            filteredPhoto = [filteredPhoto scaledImageWithWidth:filteredPhoto.size.width andHeight:filteredPhoto.size.height];
//            NSLog(@"fixed orientation: %d", filteredPhoto.imageOrientation);
//        }
//        
//        // init metadata
//        NSMutableDictionary* metadata = [[NSMutableDictionary alloc] initWithImageSampleBuffer:imageSampleBuffer];
//        [metadata setImageOrientarion:UIImageOrientationUp];
//#ifdef DEBUG
//        NSLog(@"generated still metadata: %@", metadata);
//#endif
//        
//#ifdef RETRO_VERSION
//        [(LSLookupLens*)lens setHighResolutionMode:NO];
//#endif
//        // call callback block
//        @autoreleasepool {
//            block(filteredPhoto, metadata, error);
//        }
//        
//        filteredPhoto = nil;
//        
//#ifdef DEBUG
//        report_memory_in_mb(@"After doing block");
//        [Common print_free_memory];
//#endif
//        
//        //        filteredPhoto = nil;
//    }];
//    
//    return;
//}
//


@end
