# jotto help

jotto records on your Apple Watch or iPhone and turns the recording into text on your iPhone.

## Get in touch

Found a bug, stuck on something, or have an idea: [open an issue](https://github.com/neethanwu/jotto/issues/new). Say what you did, what you expected and what happened, and which iPhone and Apple Watch you use. Please leave out anything private from your recordings.

Questions about privacy are answered in the [privacy policy](PRIVACY.md).

## Common questions

**I stopped recording. Where is the text?**
The watch records in parts of about a minute and sends each to your iPhone. They're heard as soon as jotto is running there; iOS doesn't keep it running by itself, so otherwise they wait until the watch wakes jotto, which it does when you look at the recording and when you stop. A short recording is often ready a few seconds after you stop, with a notification. A longer one gets a notification saying it's saved: open jotto and it's transcribed, and it keeps going if you then lock your iPhone. With Places on (below), jotto keeps running while you record, so each part turns into text as it arrives and the recording is ready moments after you stop. If the iPhone was out of reach, the parts go over once it's back.

**The first recording is taking a long time.**
The first time, your iPhone downloads Apple's speech model for your language. Keep jotto open on Wi-Fi until it finishes.

**How do I stop a recording?**
Hold the orange dot for a second. A tap alone doesn't stop it, so a brush of the sleeve can't end a recording.

**My recordings have a time for a name instead of a title.**
Titles and the tidier formatting are written by Apple Intelligence on your iPhone. Where it isn't available or is turned off, jotto names a recording by its time and cleans the text up by rule. You can rename any recording by tapping its title.

**It gets words wrong when I mix languages.**
Apple's speech model works best when a recording stays in one language. In Settings → Processing you can download Qwen3-ASR, which hears Chinese and English mixed together, or use your own API key.

**What does "Your own API key" do?**
It has a cloud service do the transcribing and formatting instead of your iPhone: OpenRouter, or any OpenAI-compatible service (from the App Store in China mainland: SiliconFlow, or another service that operates there). Your recordings then go straight from your iPhone to that service and you pay it directly. Turn it off in Settings → Processing and everything happens on your iPhone again.

**What does Places do?**
Settings → Places → Note where you record keeps the place each recording was made, and each place it moved a few hundred metres to, and shows them on the recording. Following your location also keeps jotto running while your watch records, which is what lets the text arrive as you go. Choose Always when iOS asks: jotto then uses location only while a recording goes on and until it's transcribed. With While Using, iOS only lets jotto start following while it's open, so it keeps going from the last time you opened jotto and iOS shows the location arrow. Places stay on your iPhone; when you send a recording, Add the place decides whether its place goes with it.

**How long is my audio kept?**
30 days after a recording is transcribed, unless you change it in Settings → Keep audio. Transcripts stay until you delete them.

**How do I delete a recording, or everything?**
Swipe a recording to the left and tap Delete; its audio and text are removed from the iPhone. Deleting the app removes everything.
