# Configuration Reference

All configuration lives in `~/.claude/monitor/config.json`. Changes are picked up by the hook script on the next event and by the SwiftUI app when it re-reads config.

## Full Default Config

```json
{
  "tts_provider": "say",
  "elevenlabs": {
    "env_file": "~/.env",
    "model": "eleven_multilingual_v2",
    "stability": 0.5,
    "similarity_boost": 0.75,
    "voice_design_prompt": "Soft, androgynous male voice with a clear synthetic quality...",
    "voice_design_name": "claude-monitor"
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
  "voices": []
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
| `voice_id` | string | — | ElevenLabs voice ID to use for TTS. Set automatically when you generate or select a voice |
| `model` | string | `"eleven_multilingual_v2"` | ElevenLabs model ID |
| `stability` | number | `0.5` | Voice stability (0.0–1.0) |
| `similarity_boost` | number | `0.75` | Voice similarity boost (0.0–1.0) |
| `voice_design_prompt` | string | *(included)* | Text prompt describing the voice to generate. Used by the "Generate voice" button in settings |
| `voice_design_name` | string | `"claude-monitor"` | Name for the generated voice in your ElevenLabs account |

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

Array of saved voices that appear in the settings voice picker. Voices are added here automatically when you generate a voice, paste a voice ID, or select from your library.

```json
{
  "voices": [
    { "id": "some-voice-id", "name": "my custom voice" }
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
- Generating a custom voice from the design prompt
- Fetching your voice library (for the voice picker in settings)
- Resolving voice names when pasting a voice ID

## Settings Popover

Click the gear icon in the panel header to access settings at runtime:

- **Refresh sessions** — scans for running Claude processes and creates session files for any that aren't tracked
- **Voice on/off** — toggles `announce.enabled`
- **Voice picker** — select from saved + library voices
- **Paste voice ID** — reads your clipboard, resolves the voice name via API, saves it to the `voices` array
- **Generate voice** — designs a custom AI voice from `voice_design_prompt`, saves it to your ElevenLabs account, and sets it as the active voice. Only appears when a design prompt is configured.

Changes made through the popover are persisted to `config.json` immediately.
