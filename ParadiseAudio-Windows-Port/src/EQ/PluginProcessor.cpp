#include "PluginProcessor.h"
#include <cmath>

EQProcessor::EQProcessor()
    : AudioProcessor (BusesProperties()
        .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout EQProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hp",1}, "HP", juce::NormalisableRange<float>(20.0f, 1000.0f), 40.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"loFreq",1}, "Lo Freq", juce::NormalisableRange<float>(40.0f, 800.0f), 120.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"loGain",1}, "Lo Gain", juce::NormalisableRange<float>(-18.0f, 18.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hiFreq",1}, "Hi Freq", juce::NormalisableRange<float>(1000.0f, 16000.0f), 6000.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hiGain",1}, "Hi Gain", juce::NormalisableRange<float>(-18.0f, 18.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"lp",1}, "LP", juce::NormalisableRange<float>(2000.0f, 20000.0f), 18000.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"lmFreq",1}, "LM Freq", juce::NormalisableRange<float>(200.0f, 2000.0f), 500.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"lmGain",1}, "LM Gain", juce::NormalisableRange<float>(-18.0f, 18.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hmFreq",1}, "HM Freq", juce::NormalisableRange<float>(1000.0f, 8000.0f), 2500.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hmGain",1}, "HM Gain", juce::NormalisableRange<float>(-18.0f, 18.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"loQ",1}, "Lo Q", juce::NormalisableRange<float>(0.2f, 8.0f), 0.9f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"lmQ",1}, "LM Q", juce::NormalisableRange<float>(0.2f, 8.0f), 1.2f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hmQ",1}, "HM Q", juce::NormalisableRange<float>(0.2f, 8.0f), 1.2f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hiQ",1}, "Hi Q", juce::NormalisableRange<float>(0.2f, 8.0f), 0.9f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hpSlope",1}, "HP Slope", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("indexed")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"lpSlope",1}, "LP Slope", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("indexed")));
    return { p.begin(), p.end() };
}

void EQProcessor::syncParams()
{
    engine.setHPFreq(P("hp"));
    engine.setLowFreq(P("loFreq"));
    engine.setLowGainDB(P("loGain"));
    engine.setHighFreq(P("hiFreq"));
    engine.setHighGainDB(P("hiGain"));
    engine.setLPFreq(P("lp"));
    engine.setLowMidFreq(P("lmFreq"));
    engine.setLowMidGainDB(P("lmGain"));
    engine.setHighMidFreq(P("hmFreq"));
    engine.setHighMidGainDB(P("hmGain"));
    engine.setLowQ(P("loQ"));
    engine.setLowMidQ(P("lmQ"));
    engine.setHighMidQ(P("hmQ"));
    engine.setHighQ(P("hiQ"));
    engine.setHPSlope24(P("hpSlope") >= 0.5f);
    engine.setLPSlope24(P("lpSlope") >= 0.5f);
}

void EQProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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

void EQProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void EQProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new EQProcessor();
}
