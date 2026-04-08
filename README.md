# Discourse TTS Plugin

**Automatic text-to-speech audio generation for Discourse posts with multi-provider support.**

Adds an inline audio player to topic posts so users can listen to content. Audio is generated automatically when posts are created.

## Features

- **Multi-Provider**: ElevenLabs, OpenAI, Gemini (Google AI Studio), Google Cloud TTS
- **Auto-Generate**: TTS audio is created automatically for new topics (first post)
- **Smart Re-Generate**: Audio is only regenerated on edit when text changes by more than 10%
- **Monthly Auto-Backfill**: Scheduled job on the 2nd of each month generates audio for posts without it, respecting the monthly credit budget
- **Budget-Aware**: Backfill sorts posts by length (shortest first) and stops before exceeding the credit limit
- **Category Exclusion**: Exclude specific categories from auto-generation
- **HR Stop-Marker**: Text after the first `<hr>` (e.g. source references) is excluded from audio
- **Chunked Generation**: Long posts are split into sentence-based chunks and concatenated
- **Duration Fix**: Player forces full-file scan for correct duration display on concatenated MP3s
- **Cleanup Job**: Scheduled cleanup of old audio files

## Providers

| Provider | Auth | Output | Notes |
|----------|------|--------|-------|
| **ElevenLabs** | API Key + Voice ID | MP3 | Voice cloning, multilingual, best for custom voices |
| **OpenAI** | API Key | MP3/Opus/AAC | Voice instructions with gpt-4o-mini-tts |
| **Gemini** | API Key (AI Studio) | WAV | 30 voices, requires paid tier for TTS |
| **Google Cloud** | API Key | MP3/Opus | Studio & Neural2 voices, pay-as-you-go |

## Installation

Add to your `app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/oxscience/discourse-tts.git
```

Then rebuild:

```bash
cd /var/discourse
./launcher rebuild app
```

Enable the plugin in **Admin → Settings → TTS**.

## Settings

### General

| Setting | Default | Description |
|---------|---------|-------------|
| `tts_enabled` | `false` | Enable/disable the plugin |
| `tts_provider` | `gemini` | TTS provider (gemini, openai, elevenlabs, google) |
| `tts_api_key` | — | API key for the selected provider |
| `tts_speed` | `1.0` | Playback speed (0.75–1.5) |
| `tts_audio_format` | `mp3` | Output format (mp3, opus, aac) |
| `tts_max_post_length` | `15000` | Max character count for TTS |
| `tts_auto_generate` | `true` | Auto-generate for new posts |
| `tts_auto_generate_first_post_only` | `false` | Only generate for the first post in a topic |
| `tts_excluded_category_ids` | — | Comma-separated category IDs to skip |
| `tts_instructions` | — | Voice instructions (Gemini & gpt-4o-mini-tts) |

### ElevenLabs

| Setting | Default | Description |
|---------|---------|-------------|
| `tts_elevenlabs_model` | `eleven_multilingual_v2` | Model (v3, multilingual_v2, flash_v2.5) |
| `tts_elevenlabs_voice_id` | — | Voice ID from ElevenLabs dashboard |
| `tts_elevenlabs_stability` | `0.5` | Voice consistency (0.3–0.9) |
| `tts_elevenlabs_similarity` | `0.75` | Similarity to original voice (0.5–1.0) |

### OpenAI

| Setting | Default | Description |
|---------|---------|-------------|
| `tts_openai_model` | `tts-1-hd` | Model (tts-1, tts-1-hd, gpt-4o-mini-tts) |
| `tts_openai_voice` | `nova` | Voice (alloy, ash, coral, echo, fable, nova, onyx, sage, shimmer) |

### Gemini

| Setting | Default | Description |
|---------|---------|-------------|
| `tts_gemini_model` | `gemini-2.5-flash-preview-tts` | Model (flash or pro) |
| `tts_gemini_voice` | `Kore` | Voice (30 available, preview in AI Studio) |

### Google Cloud

| Setting | Default | Description |
|---------|---------|-------------|
| `tts_google_voice` | `de-DE-Studio-B` | Voice name |
| `tts_google_language` | `de-DE` | Language code |

## Monthly Backfill

The plugin includes a scheduled job that runs on the **2nd of each month**. It:

1. Finds all posts in active categories without audio
2. Sorts by text length (shortest first) to maximize posts per budget
3. Enqueues generation jobs with 45s delay between API calls
4. Stops at 90% of the monthly credit budget (default: 90,000 of 100,000)

This is designed for ElevenLabs Creator Plan (100k credits/month) but works with any provider.

Manual backfill is also available via **POST /tts/backfill** (admin only).

## Requirements

- Discourse 2.7.0+
- API key for at least one supported provider

## License

MIT
