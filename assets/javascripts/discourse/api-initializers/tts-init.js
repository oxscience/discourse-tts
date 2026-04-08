import { apiInitializer } from "discourse/lib/api";

function formatTime(seconds) {
  if (!seconds || !isFinite(seconds)) return "0:00";
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export default apiInitializer((api) => {
  api.decorateCookedElement(
    (element, helper) => {
      if (!helper) return;

      // Skip editor preview — only render in actual post view
      if (element.closest(".d-editor-preview, .composer-popup, .edit-body")) return;

      const post = helper.getModel();
      if (!post || !post.tts_upload_url) return;

      // Only show on first post of regular topics (no chat, no PMs)
      if (post.post_number !== 1) return;
      if (element.closest(".chat-message, .private-message")) return;

      // Check excluded categories
      const excluded = (api.container.lookup("service:site-settings").tts_excluded_category_ids || "").split(",").map(s => parseInt(s.trim(), 10));
      const topic = post.topic || api.container.lookup("controller:topic")?.model;
      if (topic && excluded.includes(topic.category_id)) return;

      // Don't add twice
      if (element.querySelector(".tts-audio-player")) return;

      // Server-side duration (correct for concatenated MP3s)
      const serverDuration = post.tts_duration ? parseFloat(post.tts_duration) : null;

      const player = document.createElement("div");
      player.className = "tts-audio-player";
      player.innerHTML = `
        <div class="tts-header">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
            <path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/>
          </svg>
          <span>Diesen Beitrag anhören${serverDuration ? ` (${formatTime(serverDuration)})` : ""}</span>
        </div>
        <audio controls preload="none">
          <source src="${post.tts_upload_url}" type="audio/mpeg">
        </audio>
      `;

      element.prepend(player);
    },
    { id: "discourse-tts-player" }
  );
});
