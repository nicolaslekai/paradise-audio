#include "PluginProcessor.h"
#include <cmath>

DrumsProcessor::DrumsProcessor()
    : AudioProcessor (BusesProperties()

        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout DrumsProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"gain",1}, "Gain", juce::NormalisableRange<float>(-24.0f, 12.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    return { p.begin(), p.end() };
}

void DrumsProcessor::syncParams()
{
    // (no per-block parameter refresh in the original AU)
}

void DrumsProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
{
    juce::ScopedNoDenormals noDenormals;
    buffer.clear();
    if (auto* ph = getPlayHead())
        if (auto pos = ph->getPosition())
            if (auto bpm = pos->getBpm())
                hostBpm = (float) *bpm;

    syncParams();

    const float gainLin = std::pow (10.0f, P("gain") * 0.05f);
    const int n = buffer.getNumSamples();
    auto* L = buffer.getWritePointer (0);
    auto* R = buffer.getNumChannels() > 1 ? buffer.getWritePointer (1) : L;
    for (int i = 0; i < n; ++i)
    {
        float l = L[i], r = R[i];
        engine.processFrame (l, r);
            l *= gainLin; r *= gainLin;
        L[i] = l; R[i] = r;
    }
}

void DrumsProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void DrumsProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new DrumsProcessor();
}
