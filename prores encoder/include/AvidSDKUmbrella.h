// AvidSDKUmbrella.h
// The only project-owned include entry for the local Avid AMA/ACF/AAF headers.
// This file contains include guards and references. It does not restate Avid types,
// GUIDs, or implementations. Plug-in translation units include this header;
// the Swift bridging header must not.

#ifndef PRORES_ENCODER_AVID_SDK_UMBRELLA_H
#define PRORES_ENCODER_AVID_SDK_UMBRELLA_H

#ifndef __cplusplus
#error "AvidSDKUmbrella.h must be included from C++ or Objective-C++."
#endif

#if !defined(__APPLE__)
#error "ProResEncoderAMA is built for Apple platforms."
#endif

#include "acfbaseapi.h"
#include "acfuids.h"
#include "acfattributes.h"
#include "acfextras.h"
#include "acfresult.h"
#include "acfvalue.h"
#include "acftypedef.h"
#include "acfbuffer.h"
#include "acfparametersxml.h"
#include "CACFUnknown.h"
#include "CACFClassFactory.h"

#include "amatypes.hpp"
#include "amauids.hpp"
#include "amaAttributes.hpp"
#include "AMAHostParameters.hpp"
#include "AMAUtilLib.hpp"
#include "AMAString.hpp"
#include "AMALogger.hpp"
#include "IMediaWriter.hpp"
#include "IMediaContainerWriter.hpp"
#include "IMediaVolumeWriter.hpp"
#include "ISampleConsumer.hpp"
#include "IAVBuffer.hpp"
#include "SampleFormats.hpp"
#include "IParametersWriter.hpp"
#include "IWriterInteractor.hpp"
#include "IHostSettings.hpp"
#include "IClips.hpp"
#include "ISequences.hpp"
#include "IAAFClips.hpp"

// IAAFSequences.hpp includes the AAF toolkit header. Opt in from the volume
// writer only, so the rest of the plug-in does not parse that closure.
// Objective-C++ already typedefs BOOL. Make it a macro so the AAF header
// keeps its own COM typedefs and the interface keyword.
#if defined(PRORES_ENCODER_AMA_INCLUDE_AAF)
#ifndef BOOL
#define BOOL bool
#endif
#include "IAAFSequences.hpp"
#endif

#endif
