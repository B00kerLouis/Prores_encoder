#include "ExportSession.hpp"

namespace prores_ama {

void RecordDolbyMetadataMode(ExportSession& session) {
    switch (session.dolby()) {
        case DolbyChoice::Off:
            session.addObservation("dolbyMetadata=off");
            break;
        case DolbyChoice::Generate:
            session.addObservation("dolbyMetadata=generate source=CMU request; blocked unless project color is known");
            break;
        case DolbyChoice::ExternalXML:
            session.addObservation("dolbyMetadata=external XML source=user parameter; not the first source clip");
            break;
    }
}

}  // namespace prores_ama
