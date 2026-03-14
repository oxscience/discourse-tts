# frozen_string_literal: true

require "net/http"
require "json"
require "tempfile"

module Jobs
  class GenerateTtsAudio < ::Jobs::Base
    sidekiq_options retry: 3

    OPENAI_TTS_URL = "https://api.openai.com/v1/audio/speech"
    MAX_CHUNK_SIZE = 4096

    def execute(args)
      post_id = args[:post_id]
      user_id = args[:user_id] || Discourse.system_user.id

      post = Post.find_by(id: post_id)
      return unless post

      # Skip if audio already exists
      existing = PluginStore.get("discourse-tts", "post_#{post.id}_upload_id")
      if existing && Upload.exists?(id: existing)
        return
      end

      # Extract plain text from HTML
      text = extract_text(post.cooked)
      return if text.blank?
      return if text.length > SiteSetting.tts_max_post_length

      # Generate audio
      audio_data = generate_audio(text)
      return unless audio_data

      # Create Discourse upload
      upload = create_upload(post, audio_data, user_id)
      return unless upload&.persisted?

      # Store reference
      PluginStore.set("discourse-tts", "post_#{post.id}_upload_id", upload.id)

      # Notify frontend via MessageBus
      MessageBus.publish("/tts/#{post.id}", {
        upload_url: upload.url,
        post_id: post.id
      })

      Rails.logger.info("[discourse-tts] Generated audio for post #{post.id} (#{text.length} chars)")
    rescue => e
      Rails.logger.error("[discourse-tts] Failed to generate audio for post #{post_id}: #{e.message}")
      raise e # Let Sidekiq retry
    end

    private

    # Strip HTML tags, decode entities, normalize whitespace
    def extract_text(html)
      text = ActionView::Base.full_sanitizer.sanitize(html)
      text = CGI.unescapeHTML(text)
      text.gsub(/\s+/, " ").strip
    end

    # Generate audio, handling chunking for long texts
    def generate_audio(text)
      chunks = chunk_text(text)

      if chunks.length == 1
        return call_openai_tts(chunks.first)
      end

      # Multiple chunks: generate each, then concatenate
      audio_parts = chunks.map.with_index do |chunk, i|
        Rails.logger.info("[discourse-tts] Generating chunk #{i + 1}/#{chunks.length}")
        data = call_openai_tts(chunk)
        return nil unless data
        data
      end

      concatenate_audio(audio_parts)
    end

    # Split text into chunks at sentence boundaries, respecting MAX_CHUNK_SIZE
    def chunk_text(text)
      return [text] if text.length <= MAX_CHUNK_SIZE

      chunks = []
      current_chunk = ""

      # Split by sentences (period, exclamation, question mark followed by space)
      sentences = text.split(/(?<=[.!?])\s+/)

      sentences.each do |sentence|
        # If a single sentence exceeds the limit, split by words
        if sentence.length > MAX_CHUNK_SIZE
          words = sentence.split(/\s+/)
          words.each do |word|
            if (current_chunk.length + word.length + 1) > MAX_CHUNK_SIZE
              chunks << current_chunk.strip unless current_chunk.strip.empty?
              current_chunk = word
            else
              current_chunk += " " + word
            end
          end
          next
        end

        if (current_chunk.length + sentence.length + 1) > MAX_CHUNK_SIZE
          chunks << current_chunk.strip unless current_chunk.strip.empty?
          current_chunk = sentence
        else
          current_chunk += " " + sentence
        end
      end

      chunks << current_chunk.strip unless current_chunk.strip.empty?
      chunks
    end

    # Call OpenAI TTS API for a single chunk
    def call_openai_tts(text)
      uri = URI(OPENAI_TTS_URL)

      body = {
        model: SiteSetting.tts_model,
        input: text,
        voice: SiteSetting.tts_voice,
        response_format: SiteSetting.tts_audio_format,
        speed: SiteSetting.tts_speed.to_f
      }

      # Add instructions for gpt-4o-mini-tts model
      if SiteSetting.tts_model == "gpt-4o-mini-tts" && SiteSetting.tts_instructions.present?
        body[:instructions] = SiteSetting.tts_instructions
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 120
      http.open_timeout = 30

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{SiteSetting.tts_api_key}"
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = JSON.parse(response.body) rescue response.body
        Rails.logger.error("[discourse-tts] OpenAI API error: #{response.code} - #{error_body}")
        return nil
      end

      response.body
    end

    # Concatenate multiple audio chunks using ffmpeg
    def concatenate_audio(audio_parts)
      format = SiteSetting.tts_audio_format

      Dir.mktmpdir("tts_concat") do |tmpdir|
        # Write each part to a temp file
        part_files = audio_parts.each_with_index.map do |data, i|
          path = File.join(tmpdir, "part_#{i}.#{format}")
          File.binwrite(path, data)
          path
        end

        # Create ffmpeg concat file list
        list_path = File.join(tmpdir, "filelist.txt")
        File.write(list_path, part_files.map { |f| "file '#{f}'" }.join("\n"))

        # Concatenate
        output_path = File.join(tmpdir, "output.#{format}")
        result = system(
          "ffmpeg", "-y", "-f", "concat", "-safe", "0",
          "-i", list_path, "-c", "copy", output_path,
          [:out, :err] => "/dev/null"
        )

        unless result && File.exist?(output_path)
          Rails.logger.error("[discourse-tts] ffmpeg concatenation failed")
          return nil
        end

        File.binread(output_path)
      end
    end

    # Create a Discourse Upload from audio binary data
    def create_upload(post, audio_data, user_id)
      format = SiteSetting.tts_audio_format

      tempfile = Tempfile.new(["tts_post_#{post.id}", ".#{format}"])
      tempfile.binmode
      tempfile.write(audio_data)
      tempfile.rewind

      upload = UploadCreator.new(
        tempfile,
        "tts_post_#{post.id}.#{format}",
        type: "composer",
        skip_validations: true
      ).create_for(user_id)

      unless upload.persisted?
        Rails.logger.error("[discourse-tts] Upload failed for post #{post.id}: #{upload.errors.full_messages}")
      end

      upload
    ensure
      tempfile&.close!
    end
  end
end
