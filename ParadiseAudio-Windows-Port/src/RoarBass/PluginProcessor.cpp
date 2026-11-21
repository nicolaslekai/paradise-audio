#include "PluginProcessor.h"
#include <cmath>

RoarBassProcessor::RoarBassProcessor()
    : AudioProcessor (BusesProperties()

        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout RoarBassProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"osc1Oct",1}, "OSC1 Octave", juce::NormalisableRange<float>(-2.0f, 2.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("oct")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"osc2Oct",1}, "OSC2 Octave", juce::NormalisableRange<float>(-2.0f, 2.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("oct")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"osc2Det",1}, "OSC2 Detune", juce::NormalisableRange<float>(-50.0f, 50.0f), 7.0f, juce::AudioParameterFloatAttributes().withLabel("cents")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"oscMix",1}, "OSC Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 0.5f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"sub",1}, "Sub Level", juce::NormalisableRange<float>(0.0f, 1.0f), 0.7f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fmAmt",1}, "FM Growl", juce::NormalisableRange<float>(0.0f, 1.0f), 0.25f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fmRatio",1}, "FM Ratio", juce::NormalisableRange<float>(0.25f, 8.0f), 1.0f, juce::AudioParameterFloatAttributes().withLabel("ratio")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fmFb",1}, "FM Feedback", juce::NormalisableRange<float>(0.0f, 1.0f), 0.2f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"nz",1}, "Noise Level", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"nzColor",1}, "Noise Colour", juce::NormalisableRange<float>(0.0f, 1.0f), 0.7f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"cut",1}, "Filter Cutoff", juce::NormalisableRange<float>(20.0f, 18000.0f), 700.0f, juce::AudioParameterFloatAttributes().withLabel("Hz")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"res",1}, "Resonance", juce::NormalisableRange<float>(0.0f, 1.0f), 0.25f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"drv",1}, "Filter Drive", juce::NormalisableRange<float>(0.0f, 1.0f), 0.2f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fEnv",1}, "Filter Env Amt", juce::NormalisableRange<float>(-1.0f, 1.0f), 0.4f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"aA",1}, "Amp Attack", juce::NormalisableRange<float>(0.001f, 4.0f), 0.005f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"aD",1}, "Amp Decay", juce::NormalisableRange<float>(0.001f, 4.0f), 0.2f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"aS",1}, "Amp Sustain", juce::NormalisableRange<float>(0.0f, 1.0f), 0.85f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"aR",1}, "Amp Release", juce::NormalisableRange<float>(0.001f, 4.0f), 0.3f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fA",1}, "Filter Attack", juce::NormalisableRange<float>(0.001f, 4.0f), 0.005f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fD",1}, "Filter Decay", juce::NormalisableRange<float>(0.001f, 4.0f), 0.4f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fS",1}, "Filter Sustain", juce::NormalisableRange<float>(0.0f, 1.0f), 0.4f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fR",1}, "Filter Release", juce::NormalisableRange<float>(0.001f, 4.0f), 0.3f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"glide",1}, "Glide", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("s")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"vmode",1}, "Voice Mode", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f, juce::AudioParameterFloatAttributes().withLabel("indexed")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"mg",1}, "Master Gain", juce::NormalisableRange<float>(0.0f, 2.0f), 0.9f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"dOut",1}, "Output Drive", juce::NormalisableRange<float>(0.0f, 1.0f), 0.1f, juce::AudioParameterFloatAttributes().withLabel("gain")));
    return { p.begin(), p.end() };
}

void RoarBassProcessor::syncParams()
{
    engine.setParameter(0, P("osc1Oct"));
    engine.setParameter(1, P("osc2Oct"));
    engine.setParameter(2, P("osc2Det"));
    engine.setParameter(3, P("oscMix"));
    engine.setParameter(4, P("sub"));
    engine.setParameter(5, P("fmAmt"));
    engine.setParameter(6, P("fmRatio"));
    engine.setParameter(7, P("fmFb"));
    engine.setParameter(8, P("nz"));
    engine.setParameter(9, P("nzColor"));
    engine.setParameter(10, P("cut"));
    engine.setParameter(11, P("res"));
    engine.setParameter(12, P("drv"));
    engine.setParameter(13, P("fEnv"));
    engine.setParameter(14, P("aA"));
    engine.setParameter(15, P("aD"));
    engine.setParameter(16, P("aS"));
    engine.setParameter(17, P("aR"));
    engine.setParameter(18, P("fA"));
    engine.setParameter(19, P("fD"));
    engine.setParameter(20, P("fS"));
    engine.setParameter(21, P("fR"));
    engine.setParameter(22, P("glide"));
    engine.setParameter(23, P("vmode"));
    engine.setParameter(24, P("mg"));
    engine.setParameter(25, P("dOut"));
}

void RoarBassProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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
    engine.render (n, L, R);
}

void RoarBassProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void RoarBassProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new RoarBassProcessor();
}
