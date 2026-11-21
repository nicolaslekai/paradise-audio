#include "PluginProcessor.h"
#include <cmath>

DeesserProcessor::DeesserProcessor()
    : AudioProcessor (BusesProperties()
        .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout DeesserProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"freq",1}, "Frequency", juce::NormalisableRange<float>(1000.0f, 12000.0f), 6500.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"threshold",1}, "Threshold", juce::NormalisableRange<float>(-60.0f, 0.0f), -32.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"range",1}, "Range", juce::NormalisableRange<float>(-36.0f, 0.0f), -18.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"release",1}, "Release", juce::NormalisableRange<float>(10.0f, 500.0f), 80.0f, juce::AudioParameterFloatAttributes().withLabel("ms")));
    p.push_back(std::make_unique<juce::AudioParameterBool>(juce::ParameterID{"listen",1}, "Listen", false));
    return { p.begin(), p.end() };
}

void DeesserProcessor::syncParams()
{
    engine.setFrequency(P("freq")); engine.setThresholdDB(P("threshold"));
    engine.setRangeDB(P("range"));   engine.setReleaseMs(P("release"));
    engine.setListen(P("listen") > 0.5f);
}

void DeesserProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
{
    juce::ScopedNoDenormals noDenormals;
    if (auto* ph = getPlayHead())
        if (auto pos = ph->getPosition())
            if (auto bpm = pos->getBpm())
                hostBpm = (float) *bpm;

    syncParams();

    const int n = buffer.getNumSamples();
    auto* L = buffer.getWritePointer (0);
    auto* R = buffer.getNumChannels() > 1 ? buffer.getWritePointer (1) : L;
    for (int i = 0; i < n; ++i)
    {
        float l = L[i], r = R[i];
        engine.processFrame (l, r);
        L[i] = l; R[i] = r;
    }
}

void DeesserProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void DeesserProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new DeesserProcessor();
}
