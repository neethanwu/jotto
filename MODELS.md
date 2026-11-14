# Speech models compared

A rough feel for how the speech models jotto can use differ from one another. This isn't a recommendation: your voice, your languages, your microphone and the room you're in will matter more than any of these numbers.

## What we tested

- 12 two-minute parts, about 23 minutes in all, of real conversations recorded on an Apple Watch the way jotto records them (16 kHz mono AAC). Mostly Mandarin, with English words mixed in (product names and technical terms), one to three people, indoors.
- The recordings are private, so neither the audio nor any transcript is published here, only the numbers.
- Cloud models were called through [OpenRouter](https://openrouter.ai) in October 2026. The two on-device models ran on a Mac (M3 Max) in November 2026, with the same code jotto uses on the iPhone.

## How to read it

Nobody wrote out a checked transcript, so there is no true error rate. Instead, every model is compared with the two cloud models that agreed with each other most closely, Microsoft MAI-Transcribe-2 and ElevenLabs Scribe v2.

- **Difference**: how many characters differ from that model's text, as a share of its length, ignoring punctuation and spaces. Lower means closer to it, which usually but not always means more correct.
- **English words**: of the 95 English words both reference models heard, the share this model got. This is how well it copes with English inside Chinese sentences.
- **Time**: the median time to transcribe one two-minute part.

## Results

| Model | Runs | Difference from MAI-2 | Difference from Scribe | English words | Time per part | Price per minute |
|-------|------|----:|----:|----:|----:|----:|
| Apple, built in | On the iPhone | 11.1% | 13.3% | 61% | 2.6 s¹ | Free |
| Qwen3-ASR 0.6B | On the iPhone | 8.2% | 9.2% | 74% | 20 s¹ | Free |
| Microsoft MAI-Transcribe-2 | Cloud | (reference) | 7.1% | (reference) | 6.7 s | $0.0017 ($0.10/h)² |
| ElevenLabs Scribe v2 | Cloud | 7.1% | (reference) | (reference) | 5.5 s | $0.0037 ($0.22/h) |
| Qwen3-ASR 1.7B | Cloud | 6.9% | 8.7% | 81% | 10.8 s | $0.00045 ($0.03/h) |
| AssemblyAI Universal-3.6 Pro | Cloud | 8.2% | 9.4% | 84% | 2.8 s | $0.0050 ($0.30/h) |
| Mistral Voxtral Small Transcribe | Cloud | 9.8% | 11.7% | 94% | 4.7 s | $0.0040 ($0.24/h) |
| Meta Muse Voice Transcribe 1.0 | Cloud | 10.9% | 11.7% | 96% | 22.1 s | $0.0030 ($0.18/h) |
| OpenAI GPT Transcribe | Cloud | 12.1% | 11.7% | 94% | 6.1 s | $0.0045 ($0.27/h) |
| xAI Grok STT 1.0 | Cloud | 12.2% | 13.5% | 87% | 2.4 s | $0.0017 ($0.10/h) |
| OpenAI Whisper large-v3 turbo | Cloud | 15.8% | 16.6% | 75% | 2.4 s | $0.0002–0.0007 ($0.01–0.04/h) |
| Google Gemini 3.5 Transcribe | Cloud | 18.0% | 18.4% | 38% | 9.5 s | about $0.005 (about $0.30/h)³ |
| Fish Audio Transcribe 1 Pro | Cloud | 27.4% | 29.2% | 98% | 4.3 s | $0.0060 ($0.36/h) |
| Deepgram Nova-3 | Cloud | ⁴ | ⁴ | ⁴ | 1.7 s | $0.0052 ($0.31/h) |

¹ On a Mac. An iPhone is slower, and slower again with the screen locked.

² An introductory price until 31 December 2026; Azure's list price is about $0.009 a minute.

³ Billed by tokens ($2 per million in, $12 per million out); this is Google's own estimate per minute.

⁴ Returned almost nothing for this Mandarin audio.

Prices are per minute of audio, with an hour in brackets, as OpenRouter listed them in November 2026. Most are the same on the vendor's own API; ElevenLabs is a little cheaper direct ($0.0033), and Whisper large-v3 turbo is $0.0007 on Groq. OpenRouter adds a small fee when you buy credits. An hour-long meeting costs between about 1 and 36 cents to transcribe, depending on the model. Prices change; check the service before you rely on them.

## What the numbers don't show

- **Speakers.** In our run, only MAI-Transcribe-2 and Scribe v2 said who was speaking. For some of the others we may not have asked in the way that service expects, so treat this as unknown rather than missing. Neither on-device model tells speakers apart.
- **Punctuation.** Apple's model puts in very little. jotto adds punctuation and breaks the text into sentences and paragraphs afterwards, whichever model heard it.
- **Length.** Gemini's text came out about 17% shorter than the reference models', and Fish Audio's about 22% longer; that accounts for much of their difference.
- **Other languages.** This was mostly Mandarin. A model that trails here may lead in English, and the other way round.
- **Titles and tidying.** Writing the title and taking out fillers is a separate step and isn't measured here.

## In jotto

- **Apple** is the default: built into iOS, nothing to download, and best when a recording stays in one language.
- **Qwen3-ASR 0.6B** is a 950 MB download in Settings → Processing. It's much better with English words inside Chinese sentences, and takes longer.
- **Your own API key** lets you use any of the cloud models above, through OpenRouter or any OpenAI-compatible service. Audio goes straight from your iPhone to that service, and you pay it directly.
