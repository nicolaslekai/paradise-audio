#include "PluginProcessor.h"
#include <cmath>

BassMitStimmeProcessor::BassMitStimmeProcessor()
    : AudioProcessor (BusesProperties()

        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout BassMitStimmeProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"oct",1}, "OSC Oct", juce::NormalisableRange<float>(-2.0f, 2.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"det",1}, "Detune", juce::NormalisableRange<float>(-50.0f, 50.0f), 6.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"sub",1}, "Sub", juce::NormalisableRange<float>(0.0f, 1.0f), 0.7f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fmA",1}, "FM Growl", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fmR",1}, "FM Ratio", juce::NormalisableRange<float>(0.25f, 8.0f), 1.5f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"noi",1}, "Noise", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"cut",1}, "Cutoff", juce::NormalisableRange<float>(20.0f, 18000.0f), 600.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"res",1}, "Reso", juce::NormalisableRange<float>(0.0f, 1.0f), 0.25f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"env",1}, "Env Amt", juce::NormalisableRange<float>(-1.0f, 1.0f), 0.4f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"aA",1}, "Amp A", juce::NormalisableRange<float>(0.001f, 4.0f), 0.005f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"aD",1}, "Amp D", juce::NormalisableRange<float>(0.001f, 4.0f), 0.18f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"aS",1}, "Amp S", juce::NormalisableRange<float>(0.0f, 1.0f), 0.7f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"aR",1}, "Amp R", juce::NormalisableRange<float>(0.001f, 4.0f), 0.32f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fA",1}, "Filt A", juce::NormalisableRange<float>(0.001f, 4.0f), 0.002f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fD",1}, "Filt D", juce::NormalisableRange<float>(0.001f, 4.0f), 0.2f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fS",1}, "Filt S", juce::NormalisableRange<float>(0.0f, 1.0f), 0.5f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"fR",1}, "Filt R", juce::NormalisableRange<float>(0.001f, 4.0f), 0.4f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"gain",1}, "Gain", juce::NormalisableRange<float>(0.0f, 2.0f), 1.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"glide",1}, "Glide", juce::NormalisableRange<float>(0.0f, 1000.0f), 45.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"mode",1}, "Mode", juce::NormalisableRange<float>(0.0f, 2.0f), 1.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmOn",1}, "Stimme", juce::NormalisableRange<float>(0.0f, 1.0f), 1.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmPitch",1}, "Pitch", juce::NormalisableRange<float>(-24.0f, 24.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmMix",1}, "Mix", juce::NormalisableRange<float>(0.0f, 1.0f), 0.55f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmFollow",1}, "Follow", juce::NormalisableRange<float>(0.0f, 1.0f), 1.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmMode",1}, "Mode", juce::NormalisableRange<float>(0.0f, 2.0f), 2.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmDrive",1}, "Drive", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmTone",1}, "Tone", juce::NormalisableRange<float>(0.0f, 1.0f), 0.5f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmAir",1}, "Air", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmShimmer",1}, "Shimmer", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmReverb",1}, "Reverb", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    p.push_back(std::make_unique<juce::AudioParameterFloat>(juce::ParameterID{"stmDist",1}, "Distortion", juce::NormalisableRange<float>(0.0f, 1.0f), 0.0f));
    return { p.begin(), p.end() };
}

void BassMitStimmeProcessor::syncParams()
{
    engine.setOct((int)std::round(P("oct"))); engine.setDetune(P("det"));
    engine.setSub(P("sub")); engine.setFM(P("fmA"), P("fmR"));
    engine.setNoise(P("noi"));
    engine.setFilter(P("cut"), P("res"), P("env"));
    engine.setAmpADSR(P("aA"), P("aD"), P("aS"), P("aR"));
    engine.setFltADSR(P("fA"), P("fD"), P("fS"), P("fR"));
    engine.setGain(P("gain")); engine.setGlideMs(P("glide")); engine.setMode((int)std::round(P("mode")));
    engine.stimme().setEnabled(P("stmOn") >= 0.5f);
    engine.stimme().setPitchSemi(P("stmPitch"));
    engine.stimme().setMix(P("stmMix"));
    engine.stimme().setFollow(P("stmFollow") >= 0.5f);
    engine.stimme().setMode((int)std::round(P("stmMode")));
    engine.stimme().setDrive(P("stmDrive"));
    engine.stimme().setDistortion(P("stmDist"));
    engine.stimme().setTone(P("stmTone"));
    engine.stimme().setAir(P("stmAir"));
    engine.stimme().setShimmer(P("stmShimmer"));
    engine.stimme().setReverb(P("stmReverb"));
}

void BassMitStimmeProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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

void BassMitStimmeProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void BassMitStimmeProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new BassMitStimmeProcessor();
}
