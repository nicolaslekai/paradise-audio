juce_add_plugin(BassMitStimme
    COMPANY_NAME        "Paradise Audio"
    PLUGIN_MANUFACTURER_CODE Prdz
    PLUGIN_CODE         Bms1
    FORMATS             VST3
    IS_SYNTH            TRUE
    NEEDS_MIDI_INPUT    TRUE
    PRODUCT_NAME        "BassMitStimme")

target_sources(BassMitStimme PRIVATE PluginProcessor.cpp)
target_compile_features(BassMitStimme PRIVATE cxx_std_17)
target_include_directories(BassMitStimme PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(BassMitStimme PUBLIC
    JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0 JUCE_VST3_CAN_REPLACE_VST2=0)
target_link_libraries(BassMitStimme PRIVATE
    juce::juce_audio_utils
    PRIVATE juce::juce_recommended_config_flags juce::juce_recommended_warning_flags)
