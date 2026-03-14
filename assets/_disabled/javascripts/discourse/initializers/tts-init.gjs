import { apiInitializer } from "discourse/lib/api";
import TtsButton from "../components/tts-button";
import TtsPlayer from "../components/tts-player";

export default apiInitializer("1.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");

  // Only register if TTS is enabled
  if (!siteSettings.tts_enabled) return;

  // Add "Listen" button to the post menu (next to Like, Share, etc.)
  api.registerValueTransformer(
    "post-menu-buttons",
    ({ value: dag, context: { post, buttonKeys } }) => {
      // Only show for regular posts with content
      if (!post.cooked) return;

      dag.add("tts-play", TtsButton, {
        after: buttonKeys.LIKE,
      });
    }
  );

  // Render audio player below each post using a plugin outlet
  api.renderInOutlet("post-below", TtsPlayer);
});
