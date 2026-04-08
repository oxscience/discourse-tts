# frozen_string_literal: true

# Runs on the 2nd of every month to backfill TTS audio for posts
# that don't have audio yet. Runs on the 2nd (not 1st) to ensure
# ElevenLabs credits have fully reset.

module Jobs
  class ScheduledTtsBackfill < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      return unless SiteSetting.tts_enabled
      return unless Date.today.day == 2  # Only run on the 2nd of each month

      Rails.logger.info("[discourse-tts] Monthly TTS backfill triggered")
      Jobs.enqueue(:backfill_tts_audio)
    end
  end
end
