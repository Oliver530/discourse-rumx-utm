import { withPluginApi } from "discourse/lib/plugin-api";

// In-app (SPA) navigation to a members-only topic: the server answers 403 with
// our translated message (AnonLoginRedirect). Core's post-stream error handler
// would show the server-built "not found" HTML from extras.html, which hides
// the core "Log in" button of the topic error template. This transformer keeps
// the message and lets the core button render (topic.noRetry + no errorHtml).
// After login, auth-complete.js reloads the current URL, i.e. the topic.
export default {
  name: "rumx-anon-login",
  initialize(container) {
    withPluginApi("1.34.0", (api) => {
      const currentUser = container.lookup("service:current-user");
      api.registerBehaviorTransformer(
        "post-stream-error-loading",
        ({ context, next }) => {
          const { topic, error } = context;
          const json = error?.jqXHR?.responseJSON;
          const ours =
            !currentUser &&
            error?.jqXHR?.status === 403 &&
            json?.error_type === "invalid_access" &&
            json?.errors?.length;
          if (!ours) {
            return next();
          }
          topic.errorLoading = true;
          topic.errorHtml = null;
          topic.errorMessage = json.errors[0];
          topic.noRetry = true;
        }
      );
    });
  },
};
