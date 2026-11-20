# jotto privacy policy

Last updated 17 November 2026.

jotto is a recorder for Apple Watch and iPhone, published by Hallidai Inc. This policy covers the jotto apps.

## The short version

jotto has no account, no server of ours, no analytics and no ads. We don't collect anything about you. Your recordings and transcripts stay on your devices unless you send them somewhere yourself.

## What jotto keeps, and where

- **Recordings.** Audio is recorded on your Apple Watch or iPhone. The watch passes it to your iPhone over Apple's own link between the two and deletes its copy once the iPhone has it. On the iPhone, audio is removed 30 days after a recording is transcribed; you can change that to 7 days, 1 year or forever in Settings.
- **Transcripts, titles, highlights and send templates.** These stay on your iPhone until you delete them.
- **Places,** if you turn them on (see below). Each is kept with its recording on your iPhone and deleted with it.
- **Settings.** Kept on your iPhone.

All of it sits in jotto's own storage on the device. If you back up your iPhone, to iCloud or to a computer, jotto's data is part of that backup, under your Apple account and Apple's terms. Deleting a recording in jotto removes its audio and text from the iPhone. Deleting the app removes everything.

## Turning speech into text

By default, everything happens on your iPhone:

- Apple's on-device speech model transcribes the audio.
- Where Apple Intelligence is available, Apple's on-device language model writes the title and tidies the text. Where it isn't, jotto tidies by fixed rules.

Nothing is sent anywhere for this.

**The optional Qwen3-ASR model.** If you choose to download it, your iPhone fetches the model files through the App Store, the way it fetches an app. If the App Store can't supply them, and in versions built from the source, they come from Hugging Face (huggingface.co) instead; as with any download, Hugging Face then sees your IP address. The model runs on your iPhone; no audio or text is sent to anyone.

**Your own API key, if you turn it on.** You can choose to have a cloud service do the work instead: OpenRouter, or any OpenAI-compatible service whose address you enter; from the App Store in China mainland, SiliconFlow, or another service that operates there whose address you enter. While this is on:

- the audio of your recordings and the text of your transcripts go straight from your iPhone to that service, to be transcribed, titled and formatted;
- the service handles them under its own terms and privacy policy, which you agreed to when you got the key;
- your key is kept in the iPhone's Keychain and is sent only to that service.

We are not in the middle of this, and we never see your key, your audio or your text. Turn it off in Settings → Processing and everything is done on your iPhone again.

## Places

Places is off unless you turn it on, in Settings → Places → Note where you record. When it's on:

- jotto uses your iPhone's location at low accuracy. With location set to Always, it does so only while a recording goes on and until the recording is transcribed. With While Using, iOS lets jotto start only while it's open, so it keeps location on from the last time you opened jotto, and iOS shows the location arrow the whole time.
- jotto keeps the place where a recording began and each place it moved a few hundred metres to, as coordinates and a name, with the recording on your iPhone.
- To put a name to a place, jotto sends its coordinates to Apple's maps service, which answers with a name such as a park or a street. Apple handles them under its own privacy policy. Nothing else about your location leaves your iPhone.
- Turning Places off stops all of this. Places already kept stay with their recordings until you delete them.

## Sending things out

jotto sends a transcript or audio out of the app only when you ask it to: with Send, with Copy, or through a shortcut or automation you set up in Apple's Shortcuts app. Where it goes after that is up to the app or service you picked.

A recording's place goes with it only when Add the place is on as you send it. It's on unless you turn it off, and jotto remembers your choice for each template. The place is then a line in the text (and a line where it moved) and, with the audio attached, the location in the audio file.

## Permissions

- **Microphone**, to record. jotto records only after you start a recording, and the system shows its recording indicator the whole time.
- **Notifications**, to tell you when a transcript is ready. These are made on your iPhone; nothing is pushed from a server.
- **Location**, only if you turn on Places, as described above.

## What we receive

Nothing from the app. If you have agreed to share analytics with developers in your iPhone's settings, Apple may show us crash reports and usage figures for jotto with nothing in them that identifies you.

## Recording other people

You decide what to record. Laws about recording conversations differ from place to place; tell people before you record them, and follow the law where you are.

## Children

jotto isn't directed at children, and collects nothing from anyone.

## Changes

If this policy changes, the new version is published here with a new date. The history of this file is public.

## Contact

Questions about this policy: open an issue at <https://github.com/neethanwu/jotto/issues>.
