// Canonical AV1 integration header for project source and Swift bridging.
//
// Project code must import this file instead of including SVT-AV1 headers
// directly. The public Objective-C bridge intentionally exposes no SVT types.

#ifndef PRORES_ENCODER_AV1_UMBRELLA_HEADER_H
#define PRORES_ENCODER_AV1_UMBRELLA_HEADER_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Keep the bundled SVT-AV1 C API confined to this project-owned umbrella.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "../../ThirdParty/SVT-AV1/include/EbSvtAv1.h"
#include "../../ThirdParty/SVT-AV1/include/EbSvtAv1Enc.h"
#include "../../ThirdParty/SVT-AV1/include/EbSvtAv1Metadata.h"
#pragma clang diagnostic pop

#import "AV1Bridge.h"

#endif /* PRORES_ENCODER_AV1_UMBRELLA_HEADER_H */
