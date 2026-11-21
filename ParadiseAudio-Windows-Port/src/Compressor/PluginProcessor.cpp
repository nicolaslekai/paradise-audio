#include "PluginProcessor.h"
#include <cmath>

CompressorProcessor::CompressorProcessor()
    : AudioProcessor (BusesProperties()
        .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout CompressorProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"threshold",1}, "Threshold", juce::NormalisableRange<float>(-60.0f, 0.0f), -18.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"ratio",1}, "Ratio", juce::NormalisableRange<float>(1.0f, 20.0f), 4.0f, juce::AudioParameterFloatAttributes().withLabel("ratio")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"attack",1}, "Attack", juce::NormalisableRange<float>(0.1f, 100.0f), 5.0f, juce::AudioParameterFloatAttributes().withLabel("ms")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"release",1}, "Release", juce::NormalisableRange<float>(5.0f, 2000.0f), 80.0f, juce::AudioParameterFloatAttributes().withLabel("ms")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"knee",1}, "Knee", juce::NormalisableRange<float>(0.0f, 24.0f), 6.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"mix",1}, "Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 1.0f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterBool>(juce::ParameterID{"duckOn",1}, "Duck", false));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"duckRate",1}, "Duck Rate", juce::NormalisableRange<float>(1.0f, 12.0f), 3.0f, juce::AudioParameterFloatAttributes().withLabel("indexed")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"duckDepth",1}, "Duck Depth", juce::NormalisableRange<float>(0.0f, 36.0f), 9.0f, juce::AudioParameterFloatAttributes().withLabel("dB")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"duckAttack",1}, "Duck Attack", juce::NormalisableRange<float>(0.1f, 50.0f), 3.0f, juce::AudioParameterFloatAttributes().withLabel("ms")));
    return { p.begin(), p.end() };
}

void CompressorProcessor::syncParams()
{
    engine.setThresholdDB(P("threshold"));
    engine.setRatio(P("ratio"));
    engine.setAttackMs(P("attack"));
    engine.setReleaseMs(P("release"));
    engine.setKneeDB(P("knee"));
    engine.setMix(P("mix"));
    engine.duck().setEnabled(P("duckOn") >= 0.5f);
    engine.duck().setBPM(hostBpm);
    engine.duck().setRate((int)std::round(P("duckRate")));
    engine.duck().setDepthDB(P("duckDepth"));
    engine.duck().setAttackMs(P("duckAttack"));
}

void CompressorProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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

void CompressorProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void CompressorProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new CompressorProcessor();
}
