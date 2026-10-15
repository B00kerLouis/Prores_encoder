#include "ExportSession.hpp"
#include "../../prores encoder/avid_plugin/AMAWorkerProtocol.h"
#import "AMAHDRToneMapper.h"

#include <cstdio>
#include <thread>
#include <array>
#include <cmath>

// Independent ST 2084 decode and CIE chromaticity checks. The GPU code must
// map declared SDR white to the requested peak and preserve source primaries
// through a real Rec.709 -> Rec.2020 conversion. Local Metal opt-in only.
static double pqNits(unsigned char code) {
    const double p = std::pow(code / 255.0, 32.0 / 2523.0);
    return 10000 * std::pow(std::max(p - 3424.0 / 4096.0, 0.0) /
        (2413.0 / 128.0 - 2392.0 / 128.0 * p), 16384.0 / 2610.0);
}
static int checkHDRPixels() {
    int failures = 0;
    @autoreleasepool {
        const unsigned char bgra[] = {
            0,0,0,255, 64,64,64,255, 128,128,128,255, 192,192,192,255,
            255,255,255,255, 0,0,255,255, 0,255,0,255, 255,0,0,255};
        for (float peak : {100.f, 1000.f, 4000.f}) {
            NSError* error = nil;
            AMAHDRToneMapper* mapper = [[AMAHDRToneMapper alloc] initWithWidth:8 height:1 inputColor:1 peakNits:peak error:&error];
            NSData* output = [mapper mapBGRA:[NSData dataWithBytes:bgra length:sizeof(bgra)] stride:32 error:&error];
            if (!output || output.length != sizeof(bgra)) {
                std::fprintf(stderr, "HDR GPU check unavailable: %s\n", error.localizedDescription.UTF8String ?: "Metal initialization failed");
                [mapper release]; return failures + 1;
            }
            const auto* bytes = static_cast<const unsigned char*>(output.bytes);
            double last = -1;
            for (int index=0; index<5; ++index) {
                const double nits = pqNits(bytes[index*4+2]);
                if (index == 0 && nits > 0.001) ++failures;
                if (nits <= last) ++failures;
                if (bytes[index*4+3] != 255) ++failures;
                last = nits;
            }
            if (std::abs(last-peak) > peak*0.05) ++failures; // 8-bit PQ carrier quantization
            std::printf("HDR SDR white target %.0f nits -> GPU %.3f nits\n", peak, last);
            const double expected[][2]={{0.64,0.33},{0.30,0.60},{0.15,0.06}};
            for (int index=0; index<3; ++index) {
                const auto* pixel=bytes+(index+5)*4;
                const double r=pqNits(pixel[2]),g=pqNits(pixel[1]),b=pqNits(pixel[0]);
                const double X=.63695805*r+.14461690*g+.16888098*b;
                const double Y=.26270021*r+.67799807*g+.05930172*b;
                const double Z=.02807269*g+1.06098506*b;
                const double sum=X+Y+Z;
                if (std::abs(X/sum-expected[index][0])>.015 || std::abs(Y/sum-expected[index][1])>.015) ++failures;
            }
            [mapper release];
        }
        // PQ input already represents absolute nits; it must not get SDR gain.
        NSError* error=nil;
        AMAHDRToneMapper* pq=[[AMAHDRToneMapper alloc] initWithWidth:1 height:1 inputColor:2 peakNits:1000 error:&error];
        const unsigned char input[]={130,130,130,255};
        NSData* output=[pq mapBGRA:[NSData dataWithBytes:input length:4] stride:4 error:&error];
        if (!output || std::memcmp(output.bytes,input,4)!=0) ++failures;
        [pq release];
        // The live input keeps every SDR grey distinguishable. Rounding PQ to
        // BGRA8 used to merge adjacent values before the 10-bit HEVC encoder.
        unsigned char ramp[256*4];
        for (int i=0; i<256; ++i) {
            ramp[4*i]=ramp[4*i+1]=ramp[4*i+2]=i; ramp[4*i+3]=255;
        }
        AMAHDRToneMapper* mapper=[[AMAHDRToneMapper alloc] initWithWidth:256 height:1 inputColor:1 peakNits:1000 error:&error];
        NSData* half=[mapper mapRGBAHalf:[NSData dataWithBytes:ramp length:sizeof(ramp)] stride:sizeof(ramp) error:&error];
        if (!half || half.length != 256*8) ++failures;
        else {
            const uint16_t* codes=static_cast<const uint16_t*>(half.bytes);
            for(int i=1;i<256;++i) if(codes[i*4]<=codes[(i-1)*4]) ++failures;
            for(int i=0;i<256;++i) if(codes[i*4+3]!=0x3c00) ++failures;
            // Independent IEEE 754 half and ST 2084 EOTF.
            uint16_t white=codes[255*4];
            double signal=std::ldexp(1.0+(white&1023)/1024.0, ((white>>10)&31)-15);
            double powered=std::pow(signal,32.0/2523.0);
            double nits=10000*std::pow(std::max(powered-3424.0/4096.0,0.0)/
                (2413.0/128.0-2392.0/128.0*powered),16384.0/2610.0);
            if(std::abs(nits-1000)>5) ++failures;
            std::printf("HDR half precision: 256 distinct greys, white %.3f nits\n",nits);
        }
        [mapper release];
    }
    std::printf("AMA HDR pixel checks: %s\n", failures ? "FAILED" : "passed");
    return failures;
}

// A peer that keeps sending partial replies must not restart the RPC deadline.
// This also exercises fragmented replies and a worker exiting mid-response.
static int checkWorkerTransport() {
    int failures = 0;
    int descriptors[2];
    if (pipe(descriptors) != 0) return 1;
    std::thread slowPeer([&] {
        const char byte = 'x';
        for (int index = 0; index < 4; ++index) {
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
            (void)write(descriptors[1], &byte, 1);
        }
    });
    std::array<char, 4> response{};
    const bool received = ama_worker::transfer(descriptors[0], response.data(), response.size(), false, 150);
    const int failureCode = errno;
    if (received || failureCode != ETIMEDOUT) ++failures;
    slowPeer.join();
    close(descriptors[0]); close(descriptors[1]);

    if (pipe(descriptors) != 0) return failures + 1;
    std::thread fragmentedPeer([&] {
        (void)write(descriptors[1], "ab", 2);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        (void)write(descriptors[1], "cd", 2);
        close(descriptors[1]);
    });
    if (!ama_worker::transfer(descriptors[0], response.data(), response.size(), false, 1000) ||
        std::memcmp(response.data(), "abcd", 4) != 0) ++failures;
    fragmentedPeer.join();
    if (ama_worker::transfer(descriptors[0], response.data(), 1, false, 1000) || errno != EPIPE) ++failures;
    close(descriptors[0]);
    std::printf("AMA worker transport checks: %s\n", failures ? "FAILED" : "passed");
    return failures;
}

int main(int argc, const char** argv) {
    const int failures = prores_ama::ExportSession::runContractSelfCheck() + checkWorkerTransport() +
        (argc > 1 && std::strcmp(argv[1], "--hdr") == 0 ? checkHDRPixels() : 0);
    if (failures != 0) {
        std::fprintf(stderr, "ProResEncoderAMA contract self-check failed: %d\n", failures);
        return 1;
    }
    std::printf("ProResEncoderAMA contract self-check passed\n");
    return 0;
}
