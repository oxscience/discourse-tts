import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";

export default class TtsPlayer extends Component {
  @service messageBus;

  @tracked isVisible = false;
  @tracked isLoading = false;
  @tracked isPlaying = false;
  @tracked audioUrl = null;
  @tracked error = null;
  @tracked currentTime = 0;
  @tracked duration = 0;

  audioElement = null;
  _toggleHandler = null;
  _busChannel = null;

  constructor() {
    super(...arguments);

    // Pre-fill if audio already exists
    if (this.args.outletArgs?.post?.tts_upload_url) {
      this.audioUrl = this.args.outletArgs.post.tts_upload_url;
    }

    // Listen for toggle events from post menu button
    this._toggleHandler = (e) => {
      if (e.detail.postId === this.postId) {
        this.toggle();
      }
    };
    document.addEventListener("tts:toggle", this._toggleHandler);

    // MessageBus subscription for async generation completion
    this._busChannel = `/tts/${this.postId}`;
    if (this.postId) {
      this.messageBus.subscribe(this._busChannel, (data) => {
        if (data.upload_url) {
          this.audioUrl = data.upload_url;
          this.isLoading = false;
          this._initAudio();
        }
      });
    }
  }

  willDestroy() {
    super.willDestroy(...arguments);
    document.removeEventListener("tts:toggle", this._toggleHandler);
    this._cleanupAudio();
    if (this._busChannel) {
      this.messageBus.unsubscribe(this._busChannel);
    }
  }

  get postId() {
    return this.args.outletArgs?.post?.id;
  }

  get progressPercent() {
    if (!this.duration) return 0;
    return (this.currentTime / this.duration) * 100;
  }

  get progressStyle() {
    return `width: ${this.progressPercent}%`;
  }

  get formattedTime() {
    return `${this._fmt(this.currentTime)} / ${this._fmt(this.duration)}`;
  }

  <template>
    {{#if this.isVisible}}
      <div class="tts-player-container">
        {{#if this.error}}
          <div class="tts-player-error">
            <span>{{this.error}}</span>
            <button class="btn btn-small" type="button" {{on "click" this.retry}}>↻</button>
          </div>
        {{else if this.isLoading}}
          <div class="tts-player-loading">
            <div class="spinner small"></div>
            <span>Audio wird generiert…</span>
          </div>
        {{else if this.audioUrl}}
          <div class="tts-player-controls">
            <button
              class="btn btn-icon tts-play-pause"
              type="button"
              {{on "click" this.togglePlayback}}
            >
              {{#if this.isPlaying}}
                <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
                  <rect x="6" y="4" width="4" height="16" rx="1"></rect>
                  <rect x="14" y="4" width="4" height="16" rx="1"></rect>
                </svg>
              {{else}}
                <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
                  <polygon points="5,3 19,12 5,21"></polygon>
                </svg>
              {{/if}}
            </button>

            <div class="tts-progress-bar" role="progressbar" {{on "click" this.seek}}>
              <div class="tts-progress-fill" style={{this.progressStyle}}></div>
            </div>

            <span class="tts-time">{{this.formattedTime}}</span>

            <button
              class="btn btn-icon tts-close"
              type="button"
              {{on "click" this.close}}
            >✕</button>
          </div>
        {{else}}
          <div class="tts-player-generate">
            <button class="btn btn-default btn-small" type="button" {{on "click" this.generate}}>
              Audio generieren
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
      const result = await ajax(`/tts/generate/${this.postId}`, { type: "POST" });
      if (result.status === "exists" && result.upload_url) {
        this.audioUrl = result.upload_url;
        this.isLoading = false;
        this._initAudio();
      }
      // else: wait for MessageBus notification
    } catch {
      this.isLoading = false;
      this.error = "Fehler bei der Audio-Generierung.";
    }
  }

  @action
  togglePlayback() {
    if (!this.audioElement) this._initAudio();
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
    const percent = (event.clientX - rect.left) / rect.width;
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

  // --- Private helpers ---

  _initAudio() {
    if (this.audioElement) return;
    this.audioElement = new Audio(this.audioUrl);

    this.audioElement.addEventListener("loadedmetadata", () => {
      this.duration = this.audioElement.duration;
    });
    this.audioElement.addEventListener("timeupdate", () => {
      this.currentTime = this.audioElement.currentTime;
    });
    this.audioElement.addEventListener("play", () => (this.isPlaying = true));
    this.audioElement.addEventListener("pause", () => (this.isPlaying = false));
    this.audioElement.addEventListener("ended", () => {
      this.isPlaying = false;
      this.currentTime = 0;
    });
    this.audioElement.addEventListener("error", () => {
      this.error = "Audio konnte nicht geladen werden.";
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

  _fmt(seconds) {
    if (!seconds || isNaN(seconds)) return "0:00";
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, "0")}`;
  }
}
