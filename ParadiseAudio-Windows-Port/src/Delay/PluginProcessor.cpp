#include "PluginProcessor.h"
#include <cmath>

DelayProcessor::DelayProcessor()
    : AudioProcessor (BusesProperties()
        .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout DelayProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"timeL",1}, "Time L", juce::NormalisableRange<float>(1.0f, 2000.0f), 250.0f, juce::AudioParameterFloatAttributes().withLabel("ms")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"timeR",1}, "Time R", juce::NormalisableRange<float>(1.0f, 2000.0f), 375.0f, juce::AudioParameterFloatAttributes().withLabel("ms")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"feedback",1}, "Feedback", juce::NormalisableRange<float>(0.0f, 0.95f), 0.42f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"filter",1}, "Filter", juce::NormalisableRange<float>(200.0f, 18000.0f), 3200.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"mix",1}, "Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 0.28f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterBool>(juce::ParameterID{"pingpong",1}, "Ping-Pong", true));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"bass",1}, "Bass Cut", juce::NormalisableRange<float>(20.0f, 1200.0f), 120.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"wobble",1}, "Wobble", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"wobrate",1}, "Wob Rate", juce::NormalisableRange<float>(0.02f, 12.0f), 1.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"warmth",1}, "Warmth", juce::NormalisableRange<float>(0.0f, 1.0f), 0.35f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    return { p.begin(), p.end() };
}

void DelayProcessor::syncParams()
{
    engine.setTimes(P("timeL"), P("timeR"));
    engine.setFeedback(P("feedback"));
    engine.setFilterFreq(P("filter"));
    engine.setMix(P("mix"));
    engine.setPingPong(P("pingpong") > 0.5f);
    engine.setBass(P("bass"));
    engine.setWobble(P("wobble"));
    engine.setWobbleRate(P("wobrate"));
    engine.setWarmth(P("warmth"));
}

void DelayProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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

void DelayProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void DelayProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new DelayProcessor();
}
