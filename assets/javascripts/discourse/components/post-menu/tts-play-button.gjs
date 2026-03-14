import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";

export default class TtsPlayButton extends Component {
  @service siteSettings;

  static shouldRender(args) {
    return args.post?.cooked && args.post?.post_type === 1;
  }

  get hasAudio() {
    return !!this.args.post?.tts_upload_url;
  }

  @action
  togglePlayer() {
    document.dispatchEvent(
      new CustomEvent("tts:toggle", {
        detail: { postId: this.args.post.id },
        bubbles: true,
      })
    );
  }

  <template>
    <DButton
      class="tts-play-btn"
      @action={{this.togglePlayer}}
      @icon={{if this.hasAudio "headphones" "volume-up"}}
      @translatedTitle="Vorlesen"
      ...attributes
    />
  </template>
}
