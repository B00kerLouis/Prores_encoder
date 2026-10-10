#include "ExportSession.hpp"

namespace prores_ama {

void RecordColorPolicy(ExportSession& session) {
    // Public host settings do not provide a verified project primaries, transfer,
    // matrix, range, and peak-luminance set. Leave the field unknown. Do not
    // substitute Rec.2020/PQ, the negotiated pixel format, or the first clip.
    session.setProjectColorKnown(false);
    session.addObservation("projectPrimaries=unavailable source=no public host setting");
    session.addObservation("projectTransfer=unavailable source=no public host setting");
    session.addObservation("projectMatrix=unavailable source=no public host setting");
    session.addObservation("projectRange=unavailable source=no public host setting");
    session.addObservation("requestedImageFormat=BGRA full-range progressive RGB; plug-in request, not project color");
}

}  // namespace prores_ama
