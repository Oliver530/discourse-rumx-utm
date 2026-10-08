import { withPluginApi } from "discourse/lib/plugin-api";
import PostStream from "discourse/models/post-stream";

// A finished translation arrives on /topic/:id as { type: "localized", id }
// without updated_at (discourse-ai DetectTranslatePost, core
// ProcessLocalizedCooked, our reconciler). discourse-ai's callback passes that
// on as triggerChangedPost(id, undefined), and core refreshes only for a
// timestamp newer than the loaded post's, so open topics never swapped in the
// translation. A call without timestamp therefore re-fetches the post; every
// other call goes to core unchanged. Drop this once upstream sends a timestamp.
//
// addModelMethod replaces the prototype method and offers no `super`, so the
// core implementation is captured first. 2.6.4 searched the prototype chain
// for it instead, found nothing and threw on every revised/rebaked/acted
// message, so open topics stopped showing edits, rebakes and post actions.
export default {
  name: "rumx-localized-refresh",

  initialize() {
    withPluginApi((api) => {
      const coreTriggerChangedPost = PostStream.prototype.triggerChangedPost;

      api.addModelMethod(
        "post-stream",
        "triggerChangedPost",
        function (postId, updatedAt, opts) {
          if (updatedAt == null) {
            // Nobody awaits this (discourse-ai drops the promise); core's own
            // message handlers swallow failed refreshes the same way.
            return this.refreshPost(postId, opts).catch(() => {});
          }
          return coreTriggerChangedPost.call(this, postId, updatedAt, opts);
        }
      );
    });
  },
};
