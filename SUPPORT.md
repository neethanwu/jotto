# jotto help

jotto records on your Apple Watch or iPhone and turns the recording into text on your iPhone.

## Get in touch

Found a bug, stuck on something, or have an idea: [open an issue](https://github.com/neethanwu/jotto/issues/new). Say what you did, what you expected and what happened, and which iPhone and Apple Watch you use. Please leave out anything private from your recordings.

Questions about privacy are answered in the [privacy policy](PRIVACY.md).

## Common questions

**I stopped recording. Where is the text?**
The watch records in parts of about a minute. It can only hand them to your iPhone and wake jotto there while its screen is on, so with your wrist down the parts wait on the watch, and they go over together when you look at the recording or stop it. A short recording is often ready a few seconds after you stop, with a notification. A longer one gets a notification saying it's saved: open jotto and it's transcribed, and it keeps going if you then lock your iPhone. If the iPhone was out of reach, the parts go over once it's back.

**The first recording is taking a long time.**
The first time, your iPhone downloads Apple's speech model for your language. Keep jotto open on Wi-Fi until it finishes.

**How do I stop a recording?**
Hold the orange dot for a second. A tap alone doesn't stop it, so a brush of the sleeve can't end a recording.

**My recordings have a time for a name instead of a title.**
Titles and the tidier formatting are written by Apple Intelligence on your iPhone. Where it isn't available or is turned off, jotto names a recording by its time and cleans the text up by rule. You can rename any recording by tapping its title.

**It gets words wrong when I mix languages.**
Apple's speech model works best when a recording stays in one language. In Settings → Processing you can download Qwen3-ASR, which hears Chinese and English mixed together, or use your own API key.

**What does "Your own API key" do?**
It has a cloud service do the transcribing and formatting instead of your iPhone: OpenRouter, or any OpenAI-compatible service. Your recordings then go straight from your iPhone to that service and you pay it directly. Turn it off in Settings → Processing and everything happens on your iPhone again.

**How long is my audio kept?**
30 days after a recording is transcribed, unless you change it in Settings → Keep audio. Transcripts stay until you delete them.

**How do I delete a recording, or everything?**
Swipe a recording to the left and tap Delete; its audio and text are removed from the iPhone. Deleting the app removes everything.
