#include "PluginProcessor.h"
#include <cmath>

ReverbProcessor::ReverbProcessor()
    : AudioProcessor (BusesProperties()
        .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout ReverbProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"size",1}, "Size", juce::NormalisableRange<float>(0.0f, 1.0f), 0.65f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"decay",1}, "Decay", juce::NormalisableRange<float>(0.5f, 8.0f), 2.1f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"damping",1}, "Damping", juce::NormalisableRange<float>(0.0f, 1.0f), 0.4f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"predelay",1}, "Predelay", juce::NormalisableRange<float>(0.0f, 200.0f), 12.0f, juce::AudioParameterFloatAttributes().withLabel("ms")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"loCut",1}, "EQ Lo", juce::NormalisableRange<float>(20.0f, 1000.0f), 80.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hiCut",1}, "EQ Hi", juce::NormalisableRange<float>(1000.0f, 18000.0f), 9000.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"mix",1}, "Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 0.35f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    return { p.begin(), p.end() };
}

void ReverbProcessor::syncParams()
{
    engine.setSize(P("size")); engine.setDecaySec(P("decay"));
    engine.setDamping(P("damping")); engine.setPredelayMs(P("predelay"));
    engine.setLoCut(P("loCut")); engine.setHiCut(P("hiCut"));
    engine.setMix(P("mix"));
}

void ReverbProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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

void ReverbProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void ReverbProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new ReverbProcessor();
}
