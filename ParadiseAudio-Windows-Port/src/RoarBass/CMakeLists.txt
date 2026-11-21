juce_add_plugin(RoarBass
    COMPANY_NAME        "Paradise Audio"
    PLUGIN_MANUFACTURER_CODE Prdz
    PLUGIN_CODE         Roar
    FORMATS             VST3
    IS_SYNTH            TRUE
    NEEDS_MIDI_INPUT    TRUE
    PRODUCT_NAME        "RoarBass")

target_sources(RoarBass PRIVATE PluginProcessor.cpp)
target_compile_features(RoarBass PRIVATE cxx_std_17)
target_include_directories(RoarBass PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(RoarBass PUBLIC
    JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0 JUCE_VST3_CAN_REPLACE_VST2=0)
target_link_libraries(RoarBass PRIVATE
    juce::juce_audio_utils
    PRIVATE juce::juce_recommended_config_flags juce::juce_recommended_warning_flags)
