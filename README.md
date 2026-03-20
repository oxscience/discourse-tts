# Discourse TTS Plugin

**Automatic text-to-speech audio generation for Discourse posts using OpenAI TTS.**

Adds a play button to topic posts so users can listen to content. Audio is generated automatically when posts are created or edited.

## Features

- **Auto-Generate**: TTS audio is created automatically for new topics (first post)
- **Re-Generate on Edit**: Audio is regenerated when a post is updated
- **OpenAI TTS**: Uses OpenAI's text-to-speech API for natural-sounding audio
- **Backfill**: Bulk-generate audio for existing posts
- **Category Exclusion**: Exclude specific categories from auto-generation
- **Max Length**: Configurable character limit to skip very long posts
- **Cleanup Job**: Scheduled cleanup of old audio files
- **Audio Player**: Inline audio player in the post UI via custom serializer

## Installation

Follow the [standard Discourse plugin installation](https://meta.discourse.org/t/install-plugins-in-discourse/19157):

```bash
cd /var/discourse
./launcher enter app
cd /var/www/discourse
RAILS_ENV=production bundle exec rake plugin:install repo=https://github.com/oxscience/discourse-tts.git
RAILS_ENV=production bundle exec rake assets:precompile
```

Then restart Discourse and enable the plugin in **Admin → Settings → TTS**.

## Settings

| Setting | Description |
|---------|------------|
| `tts_enabled` | Enable/disable the plugin |
| `tts_auto_generate` | Auto-generate for new posts |
| `tts_max_post_length` | Max character count for TTS |
| `tts_excluded_category_ids` | Categories to skip |

## Requirements

- Discourse 2.7.0+
- OpenAI API key

## License

MIT
