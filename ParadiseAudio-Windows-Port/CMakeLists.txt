cmake_minimum_required(VERSION 3.22)
project(ParadiseAudio VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- JUCE -------------------------------------------------------------------
# Either drop JUCE into ./JUCE (git clone https://github.com/juce-framework/JUCE)
# or point CMake at an existing copy with -DJUCE_PATH=/path/to/JUCE
if(DEFINED JUCE_PATH)
    add_subdirectory(${JUCE_PATH} JUCE)
elseif(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/JUCE/CMakeLists.txt)
    add_subdirectory(JUCE)
else()
    include(FetchContent)
    FetchContent_Declare(JUCE
        GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
        GIT_TAG        8.0.4
        GIT_SHALLOW    TRUE)
    FetchContent_MakeAvailable(JUCE)
endif()

# --- Plugins ----------------------------------------------------------------
set(PARADISE_PLUGINS
    Compressor EQ Reverb Saturation Deesser Delay Limiter
    BigKnob PitchKnob UltraReverse VoiceBox
    Drums SynthThing StringThing BassMitStimme Handy RoarBass)

foreach(P IN LISTS PARADISE_PLUGINS)
    add_subdirectory(src/${P})
endforeach()
