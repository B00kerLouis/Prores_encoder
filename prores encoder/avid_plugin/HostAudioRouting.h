#ifndef PRORES_ENCODER_AMA_HOST_AUDIO_ROUTING_H
#define PRORES_ENCODER_AMA_HOST_AUDIO_ROUTING_H

#include "AvidSDKUmbrella.h"

namespace prores_ama {
class ExportSession;
void RecordHostAudioRouting(IACFUnknown* host, ExportSession& session);
}
#endif
