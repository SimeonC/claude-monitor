# Configuration Reference

All configuration lives in `~/.claude/monitor/config.json`. Changes are picked up by the hook script on the next event and by the SwiftUI app when it re-reads config.

## Full Default Config

```json
{
  "tts_provider": "say",
  "elevenlabs": {
    "env_file": "~/path/to/.env",
    "voice_id": "D3R2bb2JNcN2aFfwe3S0",
    "model": "eleven_multilingual_v2",
    "stability": 0.5,
    "similarity_boost": 0.75
  },
  "say": {
    "voice": "Zoe (Premium)",
    "rate": 200
  },
  "announce": {
    "enabled": true,
    "on_done": true,
    "on_attention": true,
    "on_start": false,
    "volume": 0.5
  },
  "voices": [
    { "id": "D3R2bb2JNcN2aFfwe3S0", "name": "human robot" }
  ]
}
```

## Fields

### `tts_provider`

Which TTS engine to use for voice announcements.

| Value | Description |
|-------|-------------|
| `"say"` | macOS built-in speech synthesizer (default, no setup needed) |
| `"elevenlabs"` | ElevenLabs API (requires API key) |

### `elevenlabs`

ElevenLabs configuration. Only used when `tts_provider` is `"elevenlabs"`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `env_file` | string | — | Path to `.env` file containing `ELEVENLABS_API_KEY` (supports `~`) |
| `voice_id` | string | — | ElevenLabs voice ID to use. Overrides any `ELEVENLABS_VOICE_ID` in the env file |
| `model` | string | `"eleven_multilingual_v2"` | ElevenLabs model ID |
| `stability` | number | `0.5` | Voice stability (0.0–1.0) |
| `similarity_boost` | number | `0.75` | Voice similarity boost (0.0–1.0) |

### `say`

macOS `say` command configuration. Only used when `tts_provider` is `"say"`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `voice` | string | `"Zoe (Premium)"` | macOS voice name. Run `say -v '?'` to list all installed voices. Install premium voices in System Settings → Accessibility → Spoken Content → Manage Voices |
| `rate` | number | `200` | Speaking rate in words per minute |

### `announce`

Controls when and how voice announcements are made.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Master toggle. Also controllable from the settings popover |
| `on_done` | boolean | `true` | Announce when a session finishes |
| `on_attention` | boolean | `true` | Announce when a session needs permission |
| `on_start` | boolean | `false` | Announce when a new session starts |
| `volume` | number | `0.5` | Announcement volume from `0.0` (silent) to `1.0` (full system volume) |

### `voices`

Array of saved voices that appear in the settings voice picker. Voices are added here automatically when you paste a voice ID from the clipboard.

```json
{
  "voices": [
    { "id": "D3R2bb2JNcN2aFfwe3S0", "name": "human robot" },
    { "id": "another-voice-id", "name": "my custom voice" }
  ]
}
```

The voice picker shows these saved voices **plus** any voices from your ElevenLabs library (fetched via API on launch). Saved voices always appear first.

## ElevenLabs `.env` File

Copy the included [`.env.example`](../.env.example) and add your key:

```bash
cp .env.example ~/.env
# edit ~/.env and paste your API key
```

Point to it with `elevenlabs.env_file` in config.json. The path supports `~` for home directory.

The API key is used for:
- Voice announcements (text-to-speech)
- Fetching your voice library (for the voice picker in settings)
- Resolving voice names when pasting a voice ID

## Settings Popover

Click the gear icon in the panel header to access settings at runtime:

- **Voice on/off** — toggles `announce.enabled`
- **Voice picker** — select from saved + library voices
- **Paste voice ID** — reads your clipboard, resolves the voice name via API, saves it to the `voices` array
- **Refresh sessions** — scans for running Claude processes and creates session files for any that aren't tracked

Changes made through the popover are persisted to `config.json` immediately.
