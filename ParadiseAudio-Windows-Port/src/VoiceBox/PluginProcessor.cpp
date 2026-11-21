#include "PluginProcessor.h"
#include <cmath>

VoiceBoxProcessor::VoiceBoxProcessor()
    : AudioProcessor (BusesProperties()
        .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout VoiceBoxProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"atOn",1}, "Tune On", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"atSpeed",1}, "Retune Spd", juce::NormalisableRange<float>(0.0f, 1.0f), 0.3f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"atAmt",1}, "Tune Amount", juce::NormalisableRange<float>(0.0f, 1.0f), 1.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hmOn",1}, "Harm On", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hmSemi",1}, "Harm Semis", juce::NormalisableRange<float>(-24.0f, 24.0f), 7.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hmMix",1}, "Harm Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 0.4f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"skOn",1}, "Skip On", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"skRate",1}, "Skip Rate", juce::NormalisableRange<float>(0.5f, 16.0f), 4.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"skAmt",1}, "Skip Amt", juce::NormalisableRange<float>(0.0f, 1.0f), 0.5f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"dlOn",1}, "Delay On", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"dlTime",1}, "Delay Time", juce::NormalisableRange<float>(1.0f, 1000.0f), 250.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"dlFb",1}, "Delay FB", juce::NormalisableRange<float>(0.0f, 0.95f), 0.35f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"chOn",1}, "Chop On", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"chRate",1}, "Chop Rate", juce::NormalisableRange<float>(0.1f, 24.0f), 8.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"chDepth",1}, "Chop Depth", juce::NormalisableRange<float>(0.0f, 1.0f), 0.8f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"vcOn",1}, "Vocoder On", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"vcTone",1}, "Voc Tone", juce::NormalisableRange<float>(0.0f, 1.0f), 0.5f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"vcMix",1}, "Voc Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 0.7f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"rvOn",1}, "Reverb On", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"rvSize",1}, "Verb Size", juce::NormalisableRange<float>(0.0f, 1.0f), 0.5f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"rvMix",1}, "Verb Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 0.3f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"hmAuto",1}, "Harm Auto", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"atScale",1}, "Tune Scale", juce::NormalisableRange<float>(0.0f, 2.0f), 0.0f));
    return { p.begin(), p.end() };
}

void VoiceBoxProcessor::syncParams()
{
    engine.setAutotune (P("atOn")  > 0.5f, P("atSpeed"),  P("atAmt"), P("atScale"));
    engine.setHarmonizer(P("hmOn") > 0.5f, P("hmSemi"),  P("hmMix"), P("hmAuto") > 0.5f);
    engine.setSkip     (P("skOn")  > 0.5f, P("skRate"),  P("skAmt"));
    engine.setDelay    (P("dlOn")  > 0.5f, P("dlTime"), P("dlFb"));
    engine.setChop     (P("chOn") > 0.5f, P("chRate"), P("chDepth"));
    engine.setVocoder  (P("vcOn") > 0.5f, P("vcTone"), P("vcMix"));
    engine.setReverb   (P("rvOn") > 0.5f, P("rvSize"), P("rvMix"));
}

void VoiceBoxProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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

void VoiceBoxProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void VoiceBoxProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new VoiceBoxProcessor();
}
