juce_add_plugin(SynthThing
    COMPANY_NAME        "Paradise Audio"
    PLUGIN_MANUFACTURER_CODE Prdz
    PLUGIN_CODE         Snt1
    FORMATS             VST3
    IS_SYNTH            TRUE
    NEEDS_MIDI_INPUT    TRUE
    PRODUCT_NAME        "SynthThing")

target_sources(SynthThing PRIVATE PluginProcessor.cpp)
target_compile_features(SynthThing PRIVATE cxx_std_17)
target_include_directories(SynthThing PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(SynthThing PUBLIC
    JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0 JUCE_VST3_CAN_REPLACE_VST2=0)
target_link_libraries(SynthThing PRIVATE
    juce::juce_audio_utils
    PRIVATE juce::juce_recommended_config_flags juce::juce_recommended_warning_flags)
