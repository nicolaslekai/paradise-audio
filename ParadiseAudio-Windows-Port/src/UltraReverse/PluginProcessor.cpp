#include "PluginProcessor.h"
#include <cmath>

UltraReverseProcessor::UltraReverseProcessor()
    : AudioProcessor (BusesProperties()
        .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout UltraReverseProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"reverse",1}, "Reverse", juce::NormalisableRange<float>(0.1f, 4.0f), 0.6f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"size",1}, "Size", juce::NormalisableRange<float>(0.0f, 1.0f), 0.7f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"decay",1}, "Decay", juce::NormalisableRange<float>(0.3f, 30.0f), 4.0f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"shimmer",1}, "Shimmer", juce::NormalisableRange<float>(0.0f, 1.0f), 0.3f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"diffusion",1}, "Diffusion", juce::NormalisableRange<float>(0.0f, 1.0f), 0.6f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"texture",1}, "Texture", juce::NormalisableRange<float>(0.0f, 1.0f), 0.7f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"predelay",1}, "Predelay", juce::NormalisableRange<float>(0.0f, 300.0f), 20.0f, juce::AudioParameterFloatAttributes().withLabel("ms")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"tone",1}, "Tone", juce::NormalisableRange<float>(0.0f, 1.0f), 0.5f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"mix",1}, "Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 0.4f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    return { p.begin(), p.end() };
}

void UltraReverseProcessor::syncParams()
{
    engine.setReverse(P("reverse"));     engine.setSize(P("size"));
    engine.setDecaySec(P("decay"));    engine.setShimmer(P("shimmer"));
    engine.setDiffusion(P("diffusion"));   engine.setTexture(P("texture"));
    engine.setPredelayMs(P("predelay"));  engine.setTone(P("tone"));
    engine.setMix(P("mix"));
}

void UltraReverseProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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

void UltraReverseProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void UltraReverseProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new UltraReverseProcessor();
}
