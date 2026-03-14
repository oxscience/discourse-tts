# frozen_string_literal: true

module Jobs
  class BackfillTtsAudio < ::Jobs::Base
    sidekiq_options retry: 0

    def execute(args)
      user_id = args[:user_id] || Discourse.system_user.id
      count = 0
      skipped = 0

      Rails.logger.info("[discourse-tts] Starting backfill...")

      # Find all regular posts within the character limit
      scope = Post.where(post_type: Post.types[:regular])
                   .where(deleted_at: nil)

      # Optionally only first posts
      if SiteSetting.tts_auto_generate_first_post_only
        scope = scope.where(post_number: 1)
      end

      scope.find_each do |post|
        # Skip if audio already exists
        existing = PluginStore.get("discourse-tts", "post_#{post.id}_upload_id")
        if existing && Upload.exists?(id: existing)
          skipped += 1
          next
        end

        # Skip if post is too long
        text = ActionView::Base.full_sanitizer.sanitize(post.cooked)
        if text.blank? || text.length > SiteSetting.tts_max_post_length
          skipped += 1
          next
        end

        # Enqueue individual generation jobs with a small delay to avoid
        # hammering the API
        Jobs.enqueue_in(count * 5.seconds, :generate_tts_audio,
          post_id: post.id,
          user_id: user_id
        )

        count += 1
      end

      Rails.logger.info(
        "[discourse-tts] Backfill queued #{count} posts for generation (#{skipped} skipped)"
      )

      # Notify admin via MessageBus
      MessageBus.publish("/tts/backfill", {
        status: "queued",
        count: count,
        skipped: skipped
      }, user_ids: [user_id])
    end
  end
end
