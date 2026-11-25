# Flicker Folio privacy note

Flicker Folio collects no user data. The maintainer receives no scripts, speech, recordings, transcripts, device identifiers, usage analytics, or crash reports from the app. There are no accounts, tracking, ads, app servers, or automatic uploads.

## What stays on your Mac

- **Scripts and private notes.** The local library is stored at `~/Library/Application Support/NotchPrompter/scripts.json`. The folder name is retained for compatibility. If enabled, the app also writes Markdown in a folder you choose. The app’s macOS iCloud sync is disabled. A folder you choose can still be synced by iCloud Drive or another service you have enabled separately.
- **Settings.** macOS stores preferences locally for the app. This includes settings, input-device choices, and a bookmark if you choose a scripts folder.
- **Live reading.** Conversational measures microphone level locally. Follow My Words and Test My Voice use Apple Speech with on-device recognition required. Live recognition text is used during the session. When the model is unavailable, the app shows a message and speech following stops or stays off. It never switches to server recognition.
- **Recorded takes.** Camera or screen recordings are saved under `~/Movies/Flicker Folio`. If you enable subtitles and local recognition is available, the app saves a matching `.srt` file in the same folder. You can delete or move files in Finder.

## Permissions

Flicker Folio requests microphone, Speech Recognition, camera, or Screen & System Audio Recording access when you use a feature that needs it or explicitly choose to enable access in onboarding. macOS can also prompt when you choose files or folders. Review or revoke access in **System Settings → Privacy & Security**. See the [feature and permission table](README.md#permissions-and-privacy).

Flicker Folio runs offline after setup. Downloading the app’s source and tools, macOS provisioning a speech language, and opening GitHub links use your connection. GitHub handles anything you choose to post in a public issue under its own privacy policy.
