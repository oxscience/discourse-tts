import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

export default class TtsPlayer extends Component {
  @service siteSettings;
  @service messageBus;

  @tracked isVisible = false;
  @tracked isLoading = false;
  @tracked isPlaying = false;
  @tracked audioUrl = null;
  @tracked error = null;
  @tracked currentTime = 0;
  @tracked duration = 0;

  audioElement = null;
  messageBusSubscription = null;

  constructor() {
    super(...arguments);

    // Check if audio already exists from serializer
    if (this.args.outletArgs?.post?.tts_upload_url) {
      this.audioUrl = this.args.outletArgs.post.tts_upload_url;
    }

    // Listen for toggle events from the post menu button
    this._onToggle = (e) => {
      if (e.detail.postId === this.postId) {
        this.toggle();
      }
    };
    document.addEventListener("tts:toggle", this._onToggle);

    // Subscribe to MessageBus for generation completion
    this._subscribeMessageBus();
  }

  willDestroy() {
    super.willDestroy(...arguments);
    document.removeEventListener("tts:toggle", this._onToggle);
    this._cleanupAudio();
    this._unsubscribeMessageBus();
  }

  get postId() {
    return this.args.outletArgs?.post?.id;
  }

  get post() {
    return this.args.outletArgs?.post;
  }

  get progressPercent() {
    if (!this.duration) return 0;
    return (this.currentTime / this.duration) * 100;
  }

  get formattedTime() {
    return `${this._formatTime(this.currentTime)} / ${this._formatTime(this.duration)}`;
  }

  <template>
    {{#if this.isVisible}}
      <div class="tts-player-container">
        {{#if this.error}}
          <div class="tts-player-error">
            <span>{{this.error}}</span>
            <button class="btn btn-small" {{on "click" this.retry}}>↻</button>
          </div>
        {{else if this.isLoading}}
          <div class="tts-player-loading">
            <div class="spinner small"></div>
            <span>{{i18n "tts.generating"}}</span>
          </div>
        {{else if this.audioUrl}}
          <div class="tts-player-controls">
            <button
              class="btn btn-icon tts-play-pause"
              {{on "click" this.togglePlayback}}
              title={{if this.isPlaying (i18n "tts.pause") (i18n "tts.play")}}
            >
              {{#if this.isPlaying}}
                <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
                  <rect x="6" y="4" width="4" height="16" rx="1" />
                  <rect x="14" y="4" width="4" height="16" rx="1" />
                </svg>
              {{else}}
                <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
                  <polygon points="5,3 19,12 5,21" />
                </svg>
              {{/if}}
            </button>

            <div class="tts-progress-bar" {{on "click" this.seek}}>
              <div class="tts-progress-fill" style="width: {{this.progressPercent}}%"></div>
            </div>

            <span class="tts-time">{{this.formattedTime}}</span>

            <button
              class="btn btn-icon tts-close"
              {{on "click" this.close}}
              title="Close"
            >✕</button>
          </div>
        {{else}}
          <div class="tts-player-generate">
            <button class="btn btn-default btn-small" {{on "click" this.generate}}>
              {{i18n "tts.generate_button"}}
            </button>
          </div>
        {{/if}}
      </div>
    {{/if}}
  </template>

  @action
  toggle() {
    this.isVisible = !this.isVisible;
    if (this.isVisible && this.audioUrl && !this.audioElement) {
      this._initAudio();
    }
    if (!this.isVisible) {
      this._cleanupAudio();
    }
  }

  @action
  async generate() {
    this.isLoading = true;
    this.error = null;

    try {
      const result = await ajax(`/tts/generate/${this.postId}`, {
        type: "POST",
      });

      if (result.status === "exists" && result.upload_url) {
        this.audioUrl = result.upload_url;
        this.isLoading = false;
        this._initAudio();
      }
      // Otherwise wait for MessageBus notification
    } catch (e) {
      this.isLoading = false;
      this.error = i18n("tts.error");
    }
  }

  @action
  togglePlayback() {
    if (!this.audioElement) {
      this._initAudio();
    }

    if (this.isPlaying) {
      this.audioElement.pause();
    } else {
      this.audioElement.play();
    }
  }

  @action
  seek(event) {
    if (!this.audioElement || !this.duration) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const percent = x / rect.width;
    this.audioElement.currentTime = percent * this.duration;
  }

  @action
  close() {
    this._cleanupAudio();
    this.isVisible = false;
    this.isPlaying = false;
    this.currentTime = 0;
  }

  @action
  retry() {
    this.error = null;
    this.generate();
  }

  // --- Private ---

  _initAudio() {
    if (this.audioElement) return;

    this.audioElement = new Audio(this.audioUrl);

    this.audioElement.addEventListener("loadedmetadata", () => {
      this.duration = this.audioElement.duration;
    });

    this.audioElement.addEventListener("timeupdate", () => {
      this.currentTime = this.audioElement.currentTime;
    });

    this.audioElement.addEventListener("play", () => {
      this.isPlaying = true;
    });

    this.audioElement.addEventListener("pause", () => {
      this.isPlaying = false;
    });

    this.audioElement.addEventListener("ended", () => {
      this.isPlaying = false;
      this.currentTime = 0;
    });

    this.audioElement.addEventListener("error", () => {
      this.error = i18n("tts.error");
      this.isPlaying = false;
    });
  }

  _cleanupAudio() {
    if (this.audioElement) {
      this.audioElement.pause();
      this.audioElement.src = "";
      this.audioElement = null;
    }
  }

  _subscribeMessageBus() {
    if (!this.postId) return;

    this.messageBus.subscribe(`/tts/${this.postId}`, (data) => {
      if (data.upload_url) {
        this.audioUrl = data.upload_url;
        this.isLoading = false;
        this._initAudio();
      }
    });
  }

  _unsubscribeMessageBus() {
    if (this.postId) {
      this.messageBus.unsubscribe(`/tts/${this.postId}`);
    }
  }

  _formatTime(seconds) {
    if (!seconds || isNaN(seconds)) return "0:00";
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, "0")}`;
  }
}
