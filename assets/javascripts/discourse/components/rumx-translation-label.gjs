import Component from "@glimmer/component";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

// Visible label for translated posts, rendered into core's
// `post-language-indicator` outlet (post/meta-data/language.gjs). Core's
// default there is a bare language icon whose tooltip is the only hint that
// the reader is looking at a machine translation — three users in the
// feedback thread did not notice they were, and could not find "original".
// Behaviour stays entirely core's: on desktop a click on the indicator
// toggles original/translation, on mobile it opens the tooltip with the
// "Tap here to show original" button. This component only changes what the
// indicator looks like.
export default class RumxTranslationLabel extends Component {
  get languageCode() {
    return String(this.args.outletArgs?.post?.language || "")
      .split(/[_-]/)[0]
      .toUpperCase();
  }

  get classNames() {
    const classes = ["fk-d-tooltip__icon", "rumx-translation-label"];
    if (this.args.outletArgs?.showingOriginal) {
      classes.push("is-original");
    }
    if (this.args.outletArgs?.outdated) {
      classes.push("is-outdated");
    }
    return classes.join(" ");
  }

  get label() {
    const key = this.args.outletArgs?.showingOriginal
      ? "rumx_translation.showing_original"
      : "rumx_translation.translated_from";
    return i18n(key, { language: this.languageCode });
  }

  <template>
    <span class={{this.classNames}} title={{@outletArgs.tooltipText}}>
      {{dIcon "language"}}
      <span class="rumx-translation-label__text">{{this.label}}</span>
    </span>
  </template>
}
