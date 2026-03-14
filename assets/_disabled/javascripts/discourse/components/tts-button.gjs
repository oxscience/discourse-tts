import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";

export default class TtsButton extends Component {
  @service siteSettings;

  // Hide if TTS is disabled or post has no content
  static hidden(args) {
    return !args.post.cooked;
  }

  get hasAudio() {
    return !!this.args.post.tts_upload_url;
  }

  <template>
    <DButton
      class="tts-play-btn"
      ...attributes
      @action={{this.openPlayer}}
      @icon={{if this.hasAudio "headphones" "volume-up"}}
      @title="tts.play_button_title"
    />
  </template>

  @action
  openPlayer() {
    // Dispatch custom event that the tts-player component listens for
    const event = new CustomEvent("tts:toggle", {
      detail: { postId: this.args.post.id },
      bubbles: true,
    });
    document.dispatchEvent(event);
  }
}
