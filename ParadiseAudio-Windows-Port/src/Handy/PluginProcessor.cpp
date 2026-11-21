#include "PluginProcessor.h"
#include <cmath>

HandyProcessor::HandyProcessor()
    : AudioProcessor (BusesProperties()

        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout HandyProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hf",1}, "HF Restore", juce::NormalisableRange<float>(0.0f, 1.0f), 0.65f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"nr",1}, "Noise Rdx", juce::NormalisableRange<float>(-40.0f, 0.0f), -18.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"tr",1}, "Transient", juce::NormalisableRange<float>(-1.0f, 1.0f), 0.3f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"wa",1}, "Warmth", juce::NormalisableRange<float>(0.0f, 1.0f), 0.4f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"lv",1}, "Level", juce::NormalisableRange<float>(-24.0f, 12.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"mx",1}, "Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 1.0f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"pt",1}, "Pitch", juce::NormalisableRange<float>(-24.0f, 24.0f), 0.0f));
    return { p.begin(), p.end() };
}

void HandyProcessor::syncParams()
{
    engine.setHF(P("hf")); engine.setNoiseDB(P("nr"));
    engine.setTransient(P("tr")); engine.setWarmth(P("wa"));
    engine.setLevelDB(P("lv")); engine.setMix(P("mx"));
    engine.setTranspose(P("pt"));
}

void HandyProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
{
    juce::ScopedNoDenormals noDenormals;
    buffer.clear();
    if (auto* ph = getPlayHead())
        if (auto pos = ph->getPosition())
            if (auto bpm = pos->getBpm())
                hostBpm = (float) *bpm;

    syncParams();

    for (const auto meta : midi)
    {
        const auto m = meta.getMessage();
        if (m.isNoteOn())       engine.noteOn  (m.getNoteNumber(), m.getVelocity());
        else if (m.isNoteOff()) engine.noteOff (m.getNoteNumber());
    }

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

void HandyProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void HandyProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new HandyProcessor();
}
