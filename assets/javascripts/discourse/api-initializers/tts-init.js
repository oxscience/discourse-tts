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
        <div class="tts-custom-player">
          <button class="tts-play-btn" type="button" aria-label="Abspielen">
            <svg class="tts-icon-play" width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>
            <svg class="tts-icon-pause" width="20" height="20" viewBox="0 0 24 24" fill="currentColor" style="display:none"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>
          </button>
          <div class="tts-progress-wrap">
            <div class="tts-progress-bar">
              <div class="tts-progress-fill"></div>
            </div>
          </div>
          <span class="tts-time">${formatTime(0)} / ${serverDuration ? formatTime(serverDuration) : "—"}</span>
        </div>
        <audio preload="none">
          <source src="${post.tts_upload_url}" type="audio/mpeg">
        </audio>
      `;

      element.prepend(player);

      // Wire up custom player
      const audioEl = player.querySelector("audio");
      const playBtn = player.querySelector(".tts-play-btn");
      const iconPlay = player.querySelector(".tts-icon-play");
      const iconPause = player.querySelector(".tts-icon-pause");
      const progressWrap = player.querySelector(".tts-progress-wrap");
      const progressFill = player.querySelector(".tts-progress-fill");
      const timeEl = player.querySelector(".tts-time");

      const getDuration = () => serverDuration || audioEl.duration || 0;

      playBtn.addEventListener("click", () => {
        if (audioEl.paused) {
          audioEl.play();
        } else {
          audioEl.pause();
        }
      });

      audioEl.addEventListener("play", () => {
        iconPlay.style.display = "none";
        iconPause.style.display = "block";
      });

      audioEl.addEventListener("pause", () => {
        iconPlay.style.display = "block";
        iconPause.style.display = "none";
      });

      audioEl.addEventListener("ended", () => {
        iconPlay.style.display = "block";
        iconPause.style.display = "none";
        progressFill.style.width = "0%";
        timeEl.textContent = `${formatTime(0)} / ${formatTime(getDuration())}`;
      });

      audioEl.addEventListener("timeupdate", () => {
        const dur = getDuration();
        if (dur > 0) {
          const pct = Math.min((audioEl.currentTime / dur) * 100, 100);
          progressFill.style.width = pct + "%";
        }
        timeEl.textContent = `${formatTime(audioEl.currentTime)} / ${formatTime(getDuration())}`;
      });

      // Click on progress bar to seek
      progressWrap.addEventListener("click", (e) => {
        const rect = progressWrap.getBoundingClientRect();
        const pct = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
        const dur = getDuration();
        if (dur > 0) {
          audioEl.currentTime = pct * dur;
        }
      });
    },
    { id: "discourse-tts-player" }
  );
});
