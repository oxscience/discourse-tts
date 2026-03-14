# frozen_string_literal: true

class TtsController < ApplicationController
  requires_plugin "discourse-tts"

  skip_before_action :check_xhr, only: [:show]
  before_action :ensure_logged_in, only: [:generate, :backfill]

  # GET /tts/audio/:post_id
  # Serves the cached TTS audio file for a post
  def show
    post = Post.find_by(id: params[:post_id])
    raise Discourse::NotFound unless post

    guardian.ensure_can_see!(post)

    upload_id = PluginStore.get("discourse-tts", "post_#{post.id}_upload_id")
    raise Discourse::NotFound unless upload_id

    upload = Upload.find_by(id: upload_id)
    raise Discourse::NotFound unless upload

    redirect_to upload.url, allow_other_host: true
  end

  # POST /tts/generate/:post_id
  # Queues TTS audio generation for a single post
  def generate
    post = Post.find_by(id: params[:post_id])
    raise Discourse::NotFound unless post

    guardian.ensure_can_see!(post)

    # Check if audio already exists
    existing = PluginStore.get("discourse-tts", "post_#{post.id}_upload_id")
    if existing && Upload.exists?(id: existing)
      return render json: {
        success: true,
        status: "exists",
        upload_url: Upload.find(existing).url
      }
    end

    # Validate post length
    text = ActionView::Base.full_sanitizer.sanitize(post.cooked)
    if text.length > SiteSetting.tts_max_post_length
      return render json: {
        success: false,
        error: I18n.t("js.tts.too_long")
      }, status: 422
    end

    # Enqueue generation job
    Jobs.enqueue(:generate_tts_audio,
      post_id: post.id,
      user_id: current_user.id
    )

    render json: { success: true, status: "queued" }
  end

  # POST /tts/backfill
  # Queues TTS generation for all existing posts without audio (admin only)
  def backfill
    guardian.ensure_is_admin!

    Jobs.enqueue(:backfill_tts_audio, user_id: current_user.id)

    render json: { success: true, status: "backfill_queued" }
  end
end
