# frozen_string_literal: true

require "net/http"
require "json"
require "tempfile"
require "base64"

module Jobs
  class GenerateTtsAudio < ::Jobs::Base
    sidekiq_options retry: 3

    OPENAI_TTS_URL = "https://api.openai.com/v1/audio/speech"
    GOOGLE_TTS_URL = "https://texttospeech.googleapis.com/v1/text:synthesize"
    MAX_CHUNK_OPENAI = 4096
    MAX_CHUNK_GOOGLE = 5000  # Google allows up to 5000 bytes of input

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

      # Generate audio via selected provider
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

      Rails.logger.info("[discourse-tts] Generated audio for post #{post.id} via #{SiteSetting.tts_provider} (#{text.length} chars)")
    rescue => e
      Rails.logger.error("[discourse-tts] Failed to generate audio for post #{post_id}: #{e.message}")
      raise e
    end

    private

    def extract_text(html)
      text = ActionView::Base.full_sanitizer.sanitize(html)
      text = CGI.unescapeHTML(text)
      text.gsub(/\s+/, " ").strip
    end

    def generate_audio(text)
      provider = SiteSetting.tts_provider

      max_chunk = provider == "google" ? MAX_CHUNK_GOOGLE : MAX_CHUNK_OPENAI
      chunks = chunk_text(text, max_chunk)

      if chunks.length == 1
        return call_tts(chunks.first, provider)
      end

      # Multiple chunks: generate each, then concatenate
      audio_parts = chunks.map.with_index do |chunk, i|
        Rails.logger.info("[discourse-tts] Generating chunk #{i + 1}/#{chunks.length} via #{provider}")
        data = call_tts(chunk, provider)
        return nil unless data
        data
      end

      concatenate_audio(audio_parts)
    end

    def call_tts(text, provider)
      case provider
      when "google"
        call_google_tts(text)
      when "openai"
        call_openai_tts(text)
      else
        Rails.logger.error("[discourse-tts] Unknown provider: #{provider}")
        nil
      end
    end

    # ===== Google Cloud TTS =====

    def call_google_tts(text)
      uri = URI("#{GOOGLE_TTS_URL}?key=#{SiteSetting.tts_api_key}")

      voice_name = SiteSetting.tts_google_voice
      language = SiteSetting.tts_google_language

      # Determine audio encoding
      audio_encoding = case SiteSetting.tts_audio_format
                       when "mp3" then "MP3"
                       when "opus" then "OGG_OPUS"
                       when "aac" then "MP3" # Google doesn't support AAC, fallback to MP3
                       else "MP3"
                       end

      body = {
        input: { text: text },
        voice: {
          languageCode: language,
          name: voice_name
        },
        audioConfig: {
          audioEncoding: audio_encoding,
          speakingRate: SiteSetting.tts_speed.to_f,
          pitch: 0.0
        }
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 120
      http.open_timeout = 30

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = JSON.parse(response.body) rescue response.body
        Rails.logger.error("[discourse-tts] Google TTS API error: #{response.code} - #{error_body}")
        return nil
      end

      result = JSON.parse(response.body)
      audio_content = result["audioContent"]

      unless audio_content
        Rails.logger.error("[discourse-tts] Google TTS: no audioContent in response")
        return nil
      end

      Base64.decode64(audio_content)
    end

    # ===== OpenAI TTS =====

    def call_openai_tts(text)
      uri = URI(OPENAI_TTS_URL)

      body = {
        model: SiteSetting.tts_openai_model,
        input: text,
        voice: SiteSetting.tts_openai_voice,
        response_format: SiteSetting.tts_audio_format,
        speed: SiteSetting.tts_speed.to_f
      }

      if SiteSetting.tts_openai_model == "gpt-4o-mini-tts" && SiteSetting.tts_instructions.present?
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

    # ===== Shared helpers =====

    def chunk_text(text, max_size)
      return [text] if text.length <= max_size

      chunks = []
      current_chunk = ""

      sentences = text.split(/(?<=[.!?])\s+/)

      sentences.each do |sentence|
        if sentence.length > max_size
          words = sentence.split(/\s+/)
          words.each do |word|
            if (current_chunk.length + word.length + 1) > max_size
              chunks << current_chunk.strip unless current_chunk.strip.empty?
              current_chunk = word
            else
              current_chunk += " " + word
            end
          end
          next
        end

        if (current_chunk.length + sentence.length + 1) > max_size
          chunks << current_chunk.strip unless current_chunk.strip.empty?
          current_chunk = sentence
        else
          current_chunk += " " + sentence
        end
      end

      chunks << current_chunk.strip unless current_chunk.strip.empty?
      chunks
    end

    def concatenate_audio(audio_parts)
      format = SiteSetting.tts_audio_format

      Dir.mktmpdir("tts_concat") do |tmpdir|
        part_files = audio_parts.each_with_index.map do |data, i|
          path = File.join(tmpdir, "part_#{i}.#{format}")
          File.binwrite(path, data)
          path
        end

        list_path = File.join(tmpdir, "filelist.txt")
        File.write(list_path, part_files.map { |f| "file '#{f}'" }.join("\n"))

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
