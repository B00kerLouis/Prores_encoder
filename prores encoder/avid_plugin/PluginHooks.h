#ifndef PRORES_ENCODER_AMA_PLUGIN_HOOKS_H
#define PRORES_ENCODER_AMA_PLUGIN_HOOKS_H

namespace prores_ama {
class ExportSession;
void RecordColorPolicy(ExportSession& session);
void RecordDolbyMetadataMode(ExportSession& session);
}
#endif
