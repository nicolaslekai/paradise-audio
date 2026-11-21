#!/bin/bash
# Build the offline test tools with the Command Line Tools (no Xcode licence needed).
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK=$DEVELOPER_DIR/SDKs/MacOSX.sdk
FC=../UltraReverseExtension/DSP/third_party/FFTConvolver
mkdir -p bin
clang++ -isysroot $SDK -std=c++17 -O2 -DAUDIOFFT_APPLE_ACCELERATE=1 -I ../UltraReverseExtension/DSP \
  urv_cli.cpp $FC/AudioFFT.cpp $FC/FFTConvolver.cpp $FC/TwoStageFFTConvolver.cpp $FC/Utilities.cpp \
  -framework Accelerate -o bin/urv_cli
clang++ -isysroot $SDK -std=c++17 -O2 -I . bloom_old.cpp -o bin/bloom_old
echo built
