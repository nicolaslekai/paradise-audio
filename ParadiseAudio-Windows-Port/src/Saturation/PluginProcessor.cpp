#include "PluginProcessor.h"
#include <cmath>

SaturationProcessor::SaturationProcessor()
    : AudioProcessor (BusesProperties()
        .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout SaturationProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"drive",1}, "Drive", juce::NormalisableRange<float>(-12.0f, 24.0f), 8.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"bias",1}, "Bias", juce::NormalisableRange<float>(-1.0f, 1.0f), 0.15f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"tone",1}, "Tone", juce::NormalisableRange<float>(-1.0f, 1.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"mix",1}, "Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 1.0f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"out",1}, "Output", juce::NormalisableRange<float>(-12.0f, 12.0f), -2.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    return { p.begin(), p.end() };
}

void SaturationProcessor::syncParams()
{
    engine.setDriveDB(P("drive")); engine.setBias(P("bias"));
    engine.setTone(P("tone"));    engine.setMix(P("mix"));
    engine.setOutputDB(P("out"));
}

void SaturationProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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

void SaturationProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void SaturationProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new SaturationProcessor();
}
