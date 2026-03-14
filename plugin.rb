# frozen_string_literal: true

# name: discourse-tts
# about: Automatische Text-to-Speech Audio-Generierung für Posts (OpenAI TTS)
# version: 0.1.0
# authors: Your Name
# url: https://github.com/your-org/discourse-tts
# required_version: 2.7.0

enabled_site_setting :tts_enabled

# register_asset "stylesheets/tts.scss"

after_initialize do
  # ----- Load files -----
  %w[
    ../app/controllers/tts_controller.rb
    ../jobs/generate_tts_audio.rb
    ../jobs/backfill_tts_audio.rb
    ../jobs/cleanup_old_tts_audio.rb
  ].each { |path| load File.expand_path(path, __FILE__) }

  # ----- Routes -----
  Discourse::Application.routes.append do
    get  "/tts/audio/:post_id" => "tts#show"
    post "/tts/generate/:post_id" => "tts#generate"
    post "/tts/backfill" => "tts#backfill"
  end

  # ----- Class extensions -----

  # Convenience method on Post to check if TTS audio exists
  add_to_class(:post, :tts_upload_id) do
    PluginStore.get("discourse-tts", "post_#{id}_upload_id")
  end

  add_to_class(:post, :has_tts_audio?) do
    tts_upload_id.present?
  end

  # Expose tts_upload_url in the post serializer so the frontend knows about it
  add_to_serializer(
    :post,
    :tts_upload_url,
    include_condition: -> { SiteSetting.tts_enabled rescue false }
  ) do
    upload_id = PluginStore.get("discourse-tts", "post_#{object.id}_upload_id") rescue nil
    next nil unless upload_id
    upload = Upload.find_by(id: upload_id)
    upload&.url
  end

  # ----- Event hooks -----

  # Auto-generate TTS for new posts (if enabled)
  on(:post_created) do |post, _opts, _user|
    if SiteSetting.tts_enabled &&
       SiteSetting.tts_auto_generate &&
       post.post_type == Post.types[:regular] &&
       post.raw.length <= SiteSetting.tts_max_post_length
      Jobs.enqueue(:generate_tts_audio, post_id: post.id)
    end
  end

  # Re-generate TTS when a post is edited
  on(:post_edited) do |post, _topic_changed|
    if SiteSetting.tts_enabled &&
       SiteSetting.tts_auto_generate &&
       post.post_type == Post.types[:regular] &&
       post.raw.length <= SiteSetting.tts_max_post_length
      # Remove old audio reference (upload itself gets cleaned up by scheduled job)
      PluginStore.remove("discourse-tts", "post_#{post.id}_upload_id")
      Jobs.enqueue(:generate_tts_audio, post_id: post.id)
    end
  end

  # Clean up when a post is destroyed
  on(:post_destroyed) do |post, _opts, _user|
    PluginStore.remove("discourse-tts", "post_#{post.id}_upload_id")
  end
end
