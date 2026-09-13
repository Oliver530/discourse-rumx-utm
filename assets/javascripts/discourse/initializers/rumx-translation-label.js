import { withPluginApi } from "discourse/lib/plugin-api";
import RumxTranslationLabel from "../components/rumx-translation-label";

// Replace the icon-only translated-post indicator with a visible label.
// See components/rumx-translation-label.gjs.
export default {
  name: "rumx-translation-label",

  initialize() {
    withPluginApi((api) => {
      api.renderInOutlet("post-language-indicator", RumxTranslationLabel);
    });
  },
};
