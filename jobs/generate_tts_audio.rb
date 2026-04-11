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
    ELEVENLABS_TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech"
    GEMINI_TTS_URL = "https://generativelanguage.googleapis.com/v1beta/models"
    MAX_CHUNK_OPENAI = 4096
    MAX_CHUNK_GOOGLE = 3500  # Google limit is 5000 bytes; use 3500 chars to be safe with multi-byte (ä, ö, ü)
    MAX_CHUNK_ELEVENLABS = 4500  # Starter plan allows 5000, keep buffer for multi-byte chars
    MAX_CHUNK_GEMINI = 7000  # Gemini input limit is 8192 tokens; ~7000 chars to be safe

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

      # Store reference, text length (for edit-change detection), and audio duration
      PluginStore.set("discourse-tts", "post_#{post.id}_upload_id", upload.id)
      PluginStore.set("discourse-tts", "post_#{post.id}_text_length", text.length)

      # Bind the upload to the post so Jobs::CleanUpUploads does not hard-delete
      # it as an orphan after the grace period (48h by default).
      UploadReference.ensure_exist!(upload_ids: [upload.id], target: post)

      # Calculate MP3 duration from file size and bitrate (128kbps default)
      duration = estimate_mp3_duration(audio_data)
      PluginStore.set("discourse-tts", "post_#{post.id}_duration", duration) if duration

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
      # Cut at first <hr> — everything after (e.g. sources) is excluded
      html = html.split(/<hr\s*\/?>/).first || html

      # Remove links, images, code blocks (not useful for audio)
      html = html.gsub(/<a [^>]*href=[^>]*>([^<]*)<\/a>/i, '\1')  # keep link text
      html = html.gsub(/<img[^>]*>/i, '')
      html = html.gsub(/<pre[^>]*>.*?<\/pre>/im, '')
      html = html.gsub(/<code[^>]*>.*?<\/code>/im, '')

      # Add pauses after headings: period + newlines so TTS takes a breath
      html = html.gsub(%r{</h[1-6]>}i, '. ')

      # Ensure sentence breaks after block elements
      html = html.gsub(%r{</p>}i, '. ')
      html = html.gsub(%r{</li>}i, '. ')
      html = html.gsub(%r{</blockquote>}i, '. ')
      html = html.gsub(%r{<br\s*/?>}i, '. ')

      text = ActionView::Base.full_sanitizer.sanitize(html)
      text = CGI.unescapeHTML(text)

      # Clean up: duplicate periods, orphaned punctuation
      text = text.gsub(/\.{2,}/, '.')
      text = text.gsub(/\.\s*,/, '.')
      text = text.gsub(/:\s*\./, '.')

      text.gsub(/\s+/, " ").strip
    end

    def generate_audio(text)
      provider = SiteSetting.tts_provider

      max_chunk = case provider
                  when "google" then MAX_CHUNK_GOOGLE
                  when "elevenlabs" then MAX_CHUNK_ELEVENLABS
                  when "gemini" then MAX_CHUNK_GEMINI
                  else MAX_CHUNK_OPENAI
                  end
      chunks = chunk_text(text, max_chunk)

      if chunks.length == 1
        return call_tts(chunks.first, provider, first_chunk: true)
      end

      # Multiple chunks: generate each, then concatenate
      audio_parts = chunks.map.with_index do |chunk, i|
        Rails.logger.info("[discourse-tts] Generating chunk #{i + 1}/#{chunks.length} via #{provider}")
        data = call_tts(chunk, provider, first_chunk: i == 0)
        return nil unless data
        data
      end

      concatenate_audio(audio_parts)
    end

    def call_tts(text, provider, first_chunk: false)
      case provider
      when "google"
        call_google_tts(text, first_chunk: first_chunk)
      when "openai"
        call_openai_tts(text)
      when "elevenlabs"
        call_elevenlabs_tts(text)
      when "gemini"
        call_gemini_tts(text)
      else
        Rails.logger.error("[discourse-tts] Unknown provider: #{provider}")
        nil
      end
    end

    # ===== Google Cloud TTS =====

    def call_google_tts(text, first_chunk: false)
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

      # Prepend 1.5s silence on the first chunk so the first word isn't clipped
      input =
        if first_chunk
          escaped = text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
          { ssml: "<speak><break time=\"1500ms\"/>#{escaped}</speak>" }
        else
          { text: text }
        end

      body = {
        input: input,
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

    # ===== Gemini TTS (Google AI Studio) =====

    def call_gemini_tts(text)
      model = SiteSetting.tts_gemini_model
      uri = URI("#{GEMINI_TTS_URL}/#{model}:generateContent?key=#{SiteSetting.tts_api_key}")

      # Gemini supports natural language instructions prepended to the text
      input_text = if SiteSetting.tts_instructions.present?
                     "#{SiteSetting.tts_instructions}\n\n#{text}"
                   else
                     text
                   end

      body = {
        contents: [{
          parts: [{
            text: input_text
          }]
        }],
        generationConfig: {
          responseModalities: ["AUDIO"],
          speechConfig: {
            voiceConfig: {
              prebuiltVoiceConfig: {
                voiceName: SiteSetting.tts_gemini_voice
              }
            }
          }
        }
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 180
      http.open_timeout = 30

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = JSON.parse(response.body) rescue response.body
        Rails.logger.error("[discourse-tts] Gemini TTS API error: #{response.code} - #{error_body}")
        return nil
      end

      result = JSON.parse(response.body)
      audio_data_b64 = result.dig("candidates", 0, "content", "parts", 0, "inlineData", "data")

      unless audio_data_b64
        Rails.logger.error("[discourse-tts] Gemini TTS: no audio data in response")
        return nil
      end

      # Gemini returns raw PCM (24kHz, 16-bit, mono) — convert to WAV
      pcm_data = Base64.decode64(audio_data_b64)
      pcm_to_wav(pcm_data, sample_rate: 24000, bits_per_sample: 16, channels: 1)
    end

    # Build a WAV file from raw PCM data (no ffmpeg needed)
    def pcm_to_wav(pcm_data, sample_rate:, bits_per_sample:, channels:)
      byte_rate = sample_rate * channels * (bits_per_sample / 8)
      block_align = channels * (bits_per_sample / 8)
      data_size = pcm_data.bytesize

      # 44-byte WAV header
      header = "RIFF"
      header += [36 + data_size].pack("V")          # file size - 8
      header += "WAVE"
      header += "fmt "
      header += [16].pack("V")                       # fmt chunk size
      header += [1].pack("v")                         # PCM format
      header += [channels].pack("v")
      header += [sample_rate].pack("V")
      header += [byte_rate].pack("V")
      header += [block_align].pack("v")
      header += [bits_per_sample].pack("v")
      header += "data"
      header += [data_size].pack("V")

      header + pcm_data
    end

    # ===== ElevenLabs TTS =====

    def call_elevenlabs_tts(text)
      voice_id = SiteSetting.tts_elevenlabs_voice_id
      if voice_id.blank?
        Rails.logger.error("[discourse-tts] ElevenLabs voice ID is not configured")
        return nil
      end

      # Map audio format to ElevenLabs output_format parameter
      output_format = case SiteSetting.tts_audio_format
                      when "mp3" then "mp3_44100_128"
                      when "opus" then "mp3_44100_128" # ElevenLabs doesn't support raw Opus, use MP3
                      when "aac" then "mp3_44100_128"
                      else "mp3_44100_128"
                      end

      uri = URI("#{ELEVENLABS_TTS_URL}/#{voice_id}?output_format=#{output_format}")

      body = {
        text: text,
        model_id: SiteSetting.tts_elevenlabs_model,
        voice_settings: {
          stability: SiteSetting.tts_elevenlabs_stability.to_f,
          similarity_boost: SiteSetting.tts_elevenlabs_similarity.to_f,
          speed: SiteSetting.tts_speed.to_f
        }
      }

      # Language hint for German content
      body[:language_code] = "de" if SiteSetting.tts_google_language.to_s.start_with?("de")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 120
      http.open_timeout = 30

      request = Net::HTTP::Post.new(uri)
      request["xi-api-key"] = SiteSetting.tts_api_key
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = JSON.parse(response.body) rescue response.body
        Rails.logger.error("[discourse-tts] ElevenLabs API error: #{response.code} - #{error_body}")
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

    # Simple binary concatenation — works for MP3 and OGG_OPUS streams.
    # No ffmpeg needed.
    def concatenate_audio(audio_parts)
      audio_parts.join
    end

    # Estimate MP3 duration by parsing frame headers for bitrate.
    # Falls back to assuming 128kbps if parsing fails.
    def estimate_mp3_duration(audio_data)
      bytes = audio_data.bytes
      bitrate = nil

      # MP3 bitrate lookup table (MPEG1 Layer III)
      bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]

      # Scan first 4KB for a sync word (0xFF 0xFB/0xFA/0xF3/0xF2)
      limit = [bytes.length, 4096].min
      (0...limit - 1).each do |i|
        if bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0
          # Found sync word — extract bitrate index (bits 12-15 of header)
          bitrate_index = (bytes[i + 2] >> 4) & 0x0F
          br = bitrates[bitrate_index]
          if br > 0
            bitrate = br
            break
          end
        end
      end

      bitrate ||= 128  # fallback
      duration_seconds = (audio_data.bytesize * 8.0) / (bitrate * 1000)
      duration_seconds.round(1)
    rescue => e
      Rails.logger.warn("[discourse-tts] Could not estimate MP3 duration: #{e.message}")
      nil
    end

    def create_upload(post, audio_data, user_id)
      # Gemini outputs WAV regardless of the audio_format setting
      format = SiteSetting.tts_provider == "gemini" ? "wav" : SiteSetting.tts_audio_format

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
