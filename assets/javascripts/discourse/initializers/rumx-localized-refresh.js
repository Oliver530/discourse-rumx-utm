import { withPluginApi } from "discourse/lib/plugin-api";

// Open topics never switched a post to its translation when it arrived.
//
// Discourse AI (Jobs::DetectTranslatePost) and our reconciler
// (Jobs::RumxRefreshStaleLocalizations) announce a finished translation on
// /topic/:id as { type: "localized", id } — WITHOUT updated_at. Discourse AI's
// client callback passes that missing value on to
// postStream.triggerChangedPost(id, undefined), and core only refreshes when
// comparePostTimestamps(candidate, existing.updated_at) > 0: an invalid
// candidate against a valid reference returns -1, so the refresh never ran.
// (A translation also does not touch post.updated_at, so sending the post's
// timestamp would not help either.)
//
// Effect (2026-10-08, reported by a member): a reply that arrives live in an
// open topic stays in its original language until the page is reloaded, while
// the DE translation existed 3 s after posting (279/279 checked). Same after
// an edit: the stale translation is hidden, the fresh one never swapped in.
//
// Fix: a changed-post trigger without a timestamp means "something about this
// post changed, re-fetch it". Only the localized callback calls it that way;
// every core caller passes the post's updated_at and keeps core behaviour.
//
// Uses addModelMethod (modifyClass on "model:*" is deprecated since 2026.8,
// discourse.modify-class-model). addModelMethod installs the method in a
// subclass without `super`, so the core implementation is reached by walking
// the prototype chain past our own function.
function triggerChangedPost(postId, updatedAt, opts = {}) {
  if (updatedAt == null && this.findLoadedPost(postId)) {
    return this.refreshPost(postId, opts);
  }

  let proto = Object.getPrototypeOf(this);
  while (proto && proto.triggerChangedPost === triggerChangedPost) {
    proto = Object.getPrototypeOf(proto);
  }
  return proto.triggerChangedPost.call(this, postId, updatedAt, opts);
}

export default {
  name: "rumx-localized-refresh",

  initialize() {
    withPluginApi((api) => {
      api.addModelMethod("post-stream", "triggerChangedPost", triggerChangedPost);
    });
  },
};
