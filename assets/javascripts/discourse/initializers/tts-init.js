import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "discourse-tts",

  initialize() {
    withPluginApi("1.34.0", (api) => {
      const siteSettings = api.container.lookup("service:site-settings");
      if (!siteSettings.tts_enabled) return;

      // Dynamically import the post menu button component
      const TtsPlayButton = require("discourse/plugins/discourse-tts/discourse/components/post-menu/tts-play-button").default;

      // Register TTS button in the post menu
      api.registerValueTransformer(
        "post-menu-buttons",
        ({ value: dag, context: { firstButtonKey } }) => {
          dag.add("tts-play", TtsPlayButton, {
            before: firstButtonKey,
          });
        }
      );

      // Render audio player below each post
      const TtsPlayer = require("discourse/plugins/discourse-tts/discourse/components/tts-player").default;
      api.renderInOutlet("post-below", TtsPlayer);
    });
  },
};
