# Local Avid SDK layout

Maintained by B00kerLouis. This directory contains first-party placement
instructions only. Obtain the macOS AMA SDK separately from Avid under its
license. No Avid headers, implementation files, libraries or SDK documentation
are distributed here.

The plug-in was built locally with AMA SDK 3.5.11. Keep the licensed package's
directory structure when populating this tree:

```text
ThirdParty/AvidSDK/
├── amasdk/
│   ├── include/          AMA headers
│   └── lib/
│       ├── debug/        libamautillib_sd.a
│       └── release/      libamautillib_s.a
├── acfsdk/
│   ├── inc/              ACF headers
│   ├── utils/            ACF utility headers and C++ implementation files
│   └── schema/           ACF schema/include dependencies
└── aafsdk/
    └── include/          AAF headers and their nested includes
```

Copy the complete include directories and their transitive dependencies, not
just the headers directly named by the plug-in. The Xcode AMA target also
compiles the licensed `acfsdk/utils/CACFUnknown.cpp` and
`acfsdk/utils/CACFClassFactory.cpp` in place. These files must be supplied from
your own SDK. The AMA utility libraries must contain an arm64 macOS slice.

From the repository root, with Xcode 26.3 selected:

```sh
xcodebuild -project "prores encoder.xcodeproj" -scheme "Build All" \
  -configuration Release -destination "generic/platform=macOS" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  SYMROOT="$PWD/Build" OBJROOT="$PWD/Build/Intermediates" build
```

The AMA runtime target supports arm64 and macOS 14 or later. Building the CLI,
framework or Avid-free contract target individually does not require this SDK.
Public GitHub Actions validate those targets and the checked-in prebuilt AVX;
they do not inject the SDK, compile the AMA target or run Media Composer.

Only the eight specifically allowlisted `README.md` files in this tree may be
committed. All SDK payload, `SOURCE.txt` and the local SHA256 manifest remain
ignored. Do not force-add SDK files, archive this populated tree into a release,
or upload it in CI artifacts.
