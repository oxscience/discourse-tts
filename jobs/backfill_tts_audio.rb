# frozen_string_literal: true

module Jobs
  class BackfillTtsAudio < ::Jobs::Base
    sidekiq_options retry: 0

    # ElevenLabs Creator Plan: 100k credits/month, ~1 credit per character
    MONTHLY_CREDIT_BUDGET = 100_000
    BUDGET_SAFETY_MARGIN = 0.10  # 10% buffer
    DELAY_BETWEEN_JOBS = 45  # seconds between API calls

    def execute(args)
      user_id = args[:user_id] || Discourse.system_user.id
      count = 0
      skipped = 0
      estimated_credits = 0
      max_credits = (MONTHLY_CREDIT_BUDGET * (1 - BUDGET_SAFETY_MARGIN)).to_i

      Rails.logger.info("[discourse-tts] Starting budget-aware backfill (max #{max_credits} credits)...")

      # Only active TTS categories (exclude the excluded ones)
      excluded = SiteSetting.tts_excluded_category_ids.to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)

      scope = Post.joins(:topic)
                   .where(post_type: Post.types[:regular])
                   .where(post_number: 1)
                   .where(topics: { archetype: Archetype.default })
                   .where(deleted_at: nil)

      # Exclude categories
      scope = scope.where.not(topics: { category_id: excluded }) if excluded.any?

      # Collect eligible posts with their text length
      candidates = []
      scope.find_each do |post|
        # Skip if audio already exists
        existing = PluginStore.get("discourse-tts", "post_#{post.id}_upload_id")
        if existing && Upload.exists?(id: existing)
          skipped += 1
          next
        end

        # Extract text with HR cutoff (same as generate job)
        html = post.cooked.split(/<hr\s*\/?>/).first || post.cooked
        text = ActionView::Base.full_sanitizer.sanitize(html)

        if text.blank? || text.length > SiteSetting.tts_max_post_length
          skipped += 1
          next
        end

        candidates << { post_id: post.id, chars: text.length }
      end

      # Sort by length: shortest first to maximize posts per budget
      candidates.sort_by! { |c| c[:chars] }

      candidates.each do |candidate|
        break if (estimated_credits + candidate[:chars]) > max_credits

        Jobs.enqueue_in(count * DELAY_BETWEEN_JOBS, :generate_tts_audio,
          post_id: candidate[:post_id],
          user_id: user_id
        )

        estimated_credits += candidate[:chars]
        count += 1
      end

      remaining = candidates.length - count

      Rails.logger.info(
        "[discourse-tts] Backfill queued #{count} posts (~#{estimated_credits} credits), " \
        "#{skipped} skipped, #{remaining} remaining for next month"
      )

      MessageBus.publish("/tts/backfill", {
        status: "queued",
        count: count,
        skipped: skipped,
        estimated_credits: estimated_credits,
        remaining: remaining
      }, user_ids: [user_id])
    end
  end
end
