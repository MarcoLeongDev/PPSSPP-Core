/*
 Copyright (c) 2013, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "PPSSPPGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenGL/gl.h>

#include "gfx/OpenEmuGLContext.h"

#include "base/NativeApp.h"
#include "base/timeutil.h"

#include "Core/Core.h"
#include "Core/Config.h"
#include "Core/CoreParameter.h"
#include "Core/CoreTiming.h"
#include "Core/HLE/sceCtrl.h"
#include "Core/Host.h"
#include "Core/SaveState.h"
#include "Core/System.h"

#include "Common/GraphicsContext.h"
#include "Common/LogManager.h"

#include "thin3d/thin3d_create.h"
#include "thin3d/GLRenderManager.h"
#include "thin3d/DataFormatGL.h"

#define AUDIO_FREQ          44100
#define AUDIO_CHANNELS      2
#define AUDIO_SAMPLESIZE    sizeof(int16_t)



namespace SaveState {
    struct SaveStart {
        void DoState(PointerWrap &p);
    };
} // namespace SaveState

namespace OpenEmuCoreThread {
    enum class EmuThreadState {
        DISABLED,
        START_REQUESTED,
        RUNNING,
        PAUSE_REQUESTED,
        PAUSED,
        QUIT_REQUESTED,
        STOPPED,
    };
} //namespace OpenEmuThreadCore

void NativeSetThreadState(OpenEmuCoreThread::EmuThreadState threadState);

@interface PPSSPPGameCore () <OEPSPSystemResponderClient, OEAudioBuffer>
{
    CoreParameter _coreParam;
    bool _isInitialized;
    bool _shouldReset;

   OpenEmuGLContext *OEgraphicsContext;
}
@end

PPSSPPGameCore *_current = 0;

@implementation PPSSPPGameCore


- (instancetype)init
{
    (self = [super init]);
    
    _current = self;
    
    return self;
}
# pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    NSString *resourcePath = [[[self owner] bundle] resourcePath];
    NSString *supportDirectoryPath = [self supportDirectoryPath];

    // Copy over font files if needed
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *fontSourceDirectory = [resourcePath stringByAppendingString:@"/flash0/font/"];
    NSString *fontDestinationDirectory = [supportDirectoryPath stringByAppendingString:@"/font/"];
    NSArray *fontFiles = [fileManager contentsOfDirectoryAtPath:fontSourceDirectory error:nil];
    for(NSString *font in fontFiles)
    {
        NSString *fontSource = [fontSourceDirectory stringByAppendingString:font];
        NSString *fontDestination = [fontDestinationDirectory stringByAppendingString:font];

        [fileManager copyItemAtPath:fontSource toPath:fontDestination error:nil];
    }

    LogManager::Init();

    g_Config.Load("");

    NSString *directoryString      = [supportDirectoryPath stringByAppendingString:@"/"];
    g_Config.currentDirectory      = directoryString.fileSystemRepresentation;
    g_Config.externalDirectory     = directoryString.fileSystemRepresentation;
    g_Config.memStickDirectory     = directoryString.fileSystemRepresentation;
    g_Config.flash0Directory       = directoryString.fileSystemRepresentation;
    g_Config.internalDataDirectory = directoryString.fileSystemRepresentation;
    g_Config.iGPUBackend           = (int)GPUBackend::OPENGL;
    
    _coreParam.cpuCore      = CPUCore::JIT;
    _coreParam.gpuCore      = GPUCORE_GLES;
    _coreParam.enableSound  = true;
    _coreParam.fileToStart  = path.fileSystemRepresentation;
    _coreParam.mountIso     = "";
    _coreParam.startPaused  = false;
    _coreParam.printfEmuLog = false;
    _coreParam.headLess     = false;

    _coreParam.renderWidth  = 480;
    _coreParam.renderHeight = 272;
    _coreParam.pixelWidth   = 480;
    _coreParam.pixelHeight  = 272;

    coreState = CORE_POWERUP;
    
    return true;
}

- (void)stopEmulation
{
    PSP_Shutdown();

    NativeShutdownGraphics();
    NativeShutdown();

    [super stopEmulation];
}

- (void)resetEmulation
{
    _shouldReset = YES;
}

- (void)executeFrame
{
    if(!_isInitialized)
    {
        // This is where PPSSPP will look for ppge_atlas.zim
        NSString *resourcePath = [[[[self owner] bundle] resourcePath] stringByAppendingString:@"/"];
        
        OEgraphicsContext = OpenEmuGLContext::CreateGraphicsContext();
        
        NativeInit(0, nil, nil, resourcePath.fileSystemRepresentation, nil, false);

        OEgraphicsContext->InitFromRenderThread(nullptr);
        
        _coreParam.graphicsContext = OEgraphicsContext;
        _coreParam.thin3d = OEgraphicsContext ? OEgraphicsContext->GetDrawContext() : nullptr;
       
        NativeInitGraphics(OEgraphicsContext);
    }

    if(_shouldReset)
        PSP_Shutdown();

    if(!_isInitialized || _shouldReset)
    {
        _isInitialized = YES;
        _shouldReset = NO;

        std::string error_string;
        if(!PSP_Init(_coreParam, &error_string))
            NSLog(@"ERROR: %s", error_string.c_str());

        host->BootDone();
		host->UpdateDisassembly();
        
        //Start the Emulator Thread
        NativeSetThreadState(OpenEmuCoreThread::EmuThreadState::START_REQUESTED);
        
    } else {
        //If Fast forward rate is detected, unthrottle the rndering
        PSP_CoreParameter().unthrottle = (self.rate > 1) ? true : false;

        //Let PPSSPP Core run a loop and return
        UpdateRunLoop();
    }
}
# pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingOpenGL2Video;
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(480, 272);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(16, 9);
}

- (NSTimeInterval)frameInterval
{
    return 59.94;
}

# pragma mark - Audio

- (NSUInteger)channelCount
{
    return AUDIO_CHANNELS;
}

- (double)audioSampleRate
{
    return AUDIO_FREQ;
}

- (id<OEAudioBuffer>)audioBufferAtIndex:(NSUInteger)index
{
    return self;
}

- (NSUInteger)read:(void *)buffer maxLength:(NSUInteger)len
{
    NativeMix((short *)buffer, (int)(len / (AUDIO_CHANNELS * sizeof(uint16_t))));
    return len;
}

- (NSUInteger)write:(const void *)buffer maxLength:(NSUInteger)length
{
    return 0;
}

- (NSUInteger)length
{
    return AUDIO_FREQ / 15;
}

# pragma mark - Save States

static void _OESaveStateCallback(bool status, std::string message, void *cbUserData)
{
    void (^block)(BOOL, NSError *) = (__bridge_transfer void(^)(BOOL, NSError *))cbUserData;
    
    //Unpause the EmuThread by requesting it to start again
    NativeSetThreadState(OpenEmuCoreThread::EmuThreadState::START_REQUESTED);
    
    block(status, nil);
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    SaveState::Save(fileName.fileSystemRepresentation, _OESaveStateCallback, (__bridge_retained void *)[block copy]);
    if(_isInitialized)
        SaveState::Process();
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    SaveState::Load(fileName.fileSystemRepresentation, _OESaveStateCallback, (__bridge_retained void *)[block copy]);
    if(_isInitialized){
        //We need to pause our EmuThread so we don't try to process the save state in the middle of a Frame Render
        NativeSetThreadState(OpenEmuCoreThread::EmuThreadState::PAUSE_REQUESTED);
        
        SaveState::Process();
    }
}

# pragma mark - Input

const int buttonMap[] = { CTRL_UP, CTRL_DOWN, CTRL_LEFT, CTRL_RIGHT, 0, 0, 0, 0, CTRL_TRIANGLE, CTRL_CIRCLE, CTRL_CROSS, CTRL_SQUARE, CTRL_LTRIGGER, CTRL_RTRIGGER, CTRL_START, CTRL_SELECT };

- (oneway void)didMovePSPJoystickDirection:(OEPSPButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    if(button == OEPSPAnalogUp || button == OEPSPAnalogDown)
        __CtrlSetAnalogY(button == OEPSPAnalogUp ? value : -value);
    else
        __CtrlSetAnalogX(button == OEPSPAnalogRight ? value : -value);
}

-(oneway void)didPushPSPButton:(OEPSPButton)button forPlayer:(NSUInteger)player
{
    __CtrlButtonDown(buttonMap[button]);
}

- (oneway void)didReleasePSPButton:(OEPSPButton)button forPlayer:(NSUInteger)player
{
    __CtrlButtonUp(buttonMap[button]);
}

@end
