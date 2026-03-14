# frozen_string_literal: true

module Jobs
  class CleanupOldTtsAudio < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      cleaned = 0

      # Find all TTS plugin store entries
      PluginStoreRow.where(plugin_name: "discourse-tts")
                     .where("key LIKE 'post_%_upload_id'")
                     .find_each do |row|
        # Extract post_id from key (format: "post_123_upload_id")
        post_id = row.key.match(/post_(\d+)_upload_id/)&.captures&.first&.to_i
        next unless post_id

        # Check if the post still exists
        post = Post.find_by(id: post_id)

        # Check if the upload still exists
        upload = Upload.find_by(id: row.typed_value) if row.typed_value.present?

        # Clean up if post is deleted or upload is missing
        if post.nil? || upload.nil?
          PluginStore.remove("discourse-tts", row.key)
          cleaned += 1
        end
      end

      Rails.logger.info("[discourse-tts] Cleanup: removed #{cleaned} orphaned TTS entries") if cleaned > 0
    end
  end
end
