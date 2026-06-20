//
//  SoundboardControlProtocol.h
//  The control contract between the Soundboard driver (in coreaudiod's helper)
//  and any client process (SoundboardApp, tools, tests).
//
//  Clients talk to the driver across processes using the PUBLIC Core Audio HAL
//  API — AudioObjectGetPropertyData / AudioObjectSetPropertyData — addressed to
//  the device object, using the custom selectors below. The driver registers
//  these in kAudioObjectPropertyCustomPropertyInfoList so the HAL marshals the
//  CFString payloads across the XPC boundary.
//
//  This header is shared by both sides so the selector values can never drift.
//

#ifndef SoundboardControlProtocol_h
#define SoundboardControlProtocol_h

// Persistent UID of the Soundboard loopback device (constant; used to locate it).
#define kSoundboardDeviceUID "ca.borisvanin.soundboard.device"

// Custom property: output level meters (read-only).
//   data type: CFData of 4 Float32 [ levelL, levelR, peakL, peakR ], each 0..1
// FourCharCode 'sblv' == 0x73626C76.
#define kSoundboardCustomProperty_Levels 'sblv'
#define kSoundboardCustomProperty_Levels_Value 0x73626C76U

#endif /* SoundboardControlProtocol_h */
