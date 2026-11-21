juce_add_plugin(Deesser
    COMPANY_NAME        "Paradise Audio"
    PLUGIN_MANUFACTURER_CODE Prdz
    PLUGIN_CODE         Dsr1
    FORMATS             VST3
    IS_SYNTH            FALSE
    NEEDS_MIDI_INPUT    FALSE
    PRODUCT_NAME        "Deesser")

target_sources(Deesser PRIVATE PluginProcessor.cpp)
target_compile_features(Deesser PRIVATE cxx_std_17)
target_include_directories(Deesser PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(Deesser PUBLIC
    JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0 JUCE_VST3_CAN_REPLACE_VST2=0)
target_link_libraries(Deesser PRIVATE
    juce::juce_audio_utils
    PRIVATE juce::juce_recommended_config_flags juce::juce_recommended_warning_flags)
