//
//  SoundboardDriver.h
//  Public entry point for the Soundboard AudioServerPlugIn.
//
//  The factory function named here must match the CFPlugInFactories entry in
//  Info.plist. coreaudiod calls it to instantiate the driver. It is declared
//  extern "C" so the symbol name stays unmangled for CFPlugIn's dlsym lookup,
//  even though the implementation is C++.
//

#ifndef SoundboardDriver_h
#define SoundboardDriver_h

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void* SoundboardDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

#ifdef __cplusplus
}
#endif

#endif /* SoundboardDriver_h */
