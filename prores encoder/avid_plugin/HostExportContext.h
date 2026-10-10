#ifndef PRORES_ENCODER_AMA_HOST_EXPORT_CONTEXT_H
#define PRORES_ENCODER_AMA_HOST_EXPORT_CONTEXT_H

#include "AvidSDKUmbrella.h"

namespace prores_ama {
class ExportSession;
ACFRESULT AcquireHostSettings(IACFUnknown* host, AMA::IHostSettings** settings);
void RecordHostExportContext(IACFUnknown* host, ExportSession& session);
}
#endif
