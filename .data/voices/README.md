# Kyutai TTS voices

Voices available for Kyutai TTS.
To find voices you like, use the interactive widget on the [TTS project page](https://kyutai.org/next/tts).

Do you want more voices?
Help us by [donating your voice](https://unmute.sh/voice-donation)
or open an issue in the [TTS repo](https://github.com/kyutai-labs/delayed-streams-modeling/) to suggest permissively-licensed datasets of voices we could add here.

## vctk/

From the [Voice Cloning Toolkit](https://datashare.ed.ac.uk/handle/10283/3443) dataset,
licensed under the Creative Commons License: Attribution 4.0 International.

Each recording was done with two mics, here we used the `mic1` recordings.
We chose sentence 23 for every speaker because it's generally the longest one to pronounce.

## expresso/

From the [Expresso](https://speechbot.github.io/expresso/) dataset,
licensed under the Creative Commons License: Attribution-NonCommercial 4.0 International.
**Non-commercial use only.**

We select clips from the "conversational" files.
For each pair of "kind" and channel (`ex04-ex01_laughing`, channel 1),
we find one segment with at least 10 consecutive seconds of speech using `VAD_segments.txt`.
We don't include more segments per (kind, channel) to keep the number of voices manageable.

The name of the file indicates how it was selected.
For instance, `ex03-ex02_narration_001_channel1_674s.wav` 
comes from the first audio channel of `audio_48khz/conversational/ex03-ex02/narration/ex03-ex02_narration_001.wav`,
meaning it's speaker `ex03`.
It's a 10-second clip starting at 674 seconds of the original file.

## cml-tts/fr/

French voices selected from the [CML-TTS Dataset](https://openslr.org/146/),
licensed under the Creative Commons License: Attribution 4.0 International.

## ears/

From the [EARS](https://sp-uhh.github.io/ears_dataset/) dataset,
licensed under the Creative Commons License: Attribution-NonCommercial 4.0 International.
**Non-commercial use only.**

For each of the 107 speakers, we use the middle 10 seconds of the `freeform_speech_01.wav` file.
Additionally, we select two speakers, p003 (female) and p031 (male) and provide speaker embeddings for each of their `emo_*_freeform.wav` files.
This is to allow users to experiment with having a voice of a single speaker with multiple emotions.

## voice-donations/

Voices of volunteers submitted through our [Voice Donation project](https://unmute.sh/voice-donation), licensed as CC0. Thank you ❤️

## Computing voice embeddings (for Kyutai devs)

```python
uv run {root of `moshi` repo}/scripts/tts_make_voice.py \
    --model-root {path to weights dir}/moshi_1e68beda_240/ \
    --loudness-headroom 22 \
    {root of this repo}
```

