#include "ExportSession.hpp"

#include <cstdio>

int main() {
    const int failures = prores_ama::ExportSession::runContractSelfCheck();
    if (failures != 0) {
        std::fprintf(stderr, "ProResEncoderAMA contract self-check failed: %d\n", failures);
        return 1;
    }
    std::printf("ProResEncoderAMA contract self-check passed\n");
    return 0;
}
