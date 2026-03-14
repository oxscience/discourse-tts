import { apiInitializer } from "discourse/lib/api";
import TtsPlayButton from "../components/post-menu/tts-play-button";
import TtsPlayer from "../components/tts-player";

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.tts_enabled) return;

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
  api.renderInOutlet("post-below", TtsPlayer);
});
