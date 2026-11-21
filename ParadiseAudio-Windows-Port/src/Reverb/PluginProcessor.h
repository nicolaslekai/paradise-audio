#pragma once
#include <juce_audio_processors/juce_audio_processors.h>
#include "DSP/Freeverb.hpp"

// Reverb — Paradise Audio, Windows/VST3 port.
// DSP below is the ORIGINAL macOS engine, unmodified.  Engine: rvb::Freeverb
class ReverbProcessor : public juce::AudioProcessor
{
public:
    ReverbProcessor();
    ~ReverbProcessor() override = default;

    void prepareToPlay (double sr, int) override { engine.prepare ((float) sr); }
    void releaseResources() override {}
    void processBlock (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;

    juce::AudioProcessorEditor* createEditor() override
        { return new juce::GenericAudioProcessorEditor (*this); }
    bool hasEditor() const override                   { return true; }
    const juce::String getName() const override       { return "Reverb"; }
    bool acceptsMidi() const override                 { return false; }
    bool producesMidi() const override                { return false; }
    bool isMidiEffect() const override                { return false; }
    double getTailLengthSeconds() const override      { return 0.0; }
    int getNumPrograms() override                     { return 1; }
    int getCurrentProgram() override                  { return 0; }
    void setCurrentProgram (int) override             {}
    const juce::String getProgramName (int) override  { return {}; }
    void changeProgramName (int, const juce::String&) override {}
    void getStateInformation (juce::MemoryBlock&) override;
    void setStateInformation (const void*, int) override;

    static juce::AudioProcessorValueTreeState::ParameterLayout createLayout();
    juce::AudioProcessorValueTreeState apvts { *this, nullptr, "PARAMS", createLayout() };

private:
    rvb::Freeverb engine;
    float hostBpm = 120.0f;   // fed from the host playhead each block
    inline float P (const char* id) const noexcept
        { return apvts.getRawParameterValue (id)->load(); }
    void syncParams();
    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ReverbProcessor)
};
