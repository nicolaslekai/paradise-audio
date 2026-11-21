#include "PluginProcessor.h"
#include <cmath>

SynthThingProcessor::SynthThingProcessor()
    : AudioProcessor (BusesProperties()

        .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
}

juce::AudioProcessorValueTreeState::ParameterLayout SynthThingProcessor::createLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> p;
    // NOTE: this plugin exposed NO host-automatable AU parameters.
    return { p.begin(), p.end() };
}

void SynthThingProcessor::syncParams()
{
    // (no per-block parameter refresh in the original AU)
}

void SynthThingProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi)
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

void SynthThingProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto s = apvts.copyState().createXml())
        copyXmlToBinary (*s, dest);
}

void SynthThingProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new SynthThingProcessor();
}
