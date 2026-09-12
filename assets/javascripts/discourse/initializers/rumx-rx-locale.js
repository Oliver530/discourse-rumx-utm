import { withPluginApi } from "discourse/lib/plugin-api";
import I18n from "discourse-i18n";

// Point the server-baked RX links (plugin.rb, always canonical /en/) at the
// viewer's language on rumx.com. The header language switcher is Discourse
// core content localization: logged in it stores user.locale, anonymous it
// writes the `locale` cookie, and both surface here as I18n.locale. Every
// switch hard-reloads, so a fresh decoration pass always starts from the
// stored /en/ HTML — this never has to undo its own rewrite.
//
// Crawlers, e-mails, RSS and the TopicLink rows keep the canonical /en/ href;
// only the DOM a person sees changes. The click-tracking normalizer in
// plugin.rb (TopicLinkClickExtension) maps the rewritten href back to the
// /en/ TopicLink so the per-link click badge and topic_link_clicks keep
// counting DE/FR readers.

// Locales rumx.com serves under their own subdirectory, minus "en": that is
// what the server already emits.
const REWRITE_LOCALES = new Set(["de", "fr"]);

// Must stay identical to RX_LINK_HREF in plugin.rb: canonical /en/, numeric
// id (1-5 digits, no leading zero), trailing slash, no query.
const RX_HREF = /^https:\/\/rumx\.com\/en\/rums\/([1-9][0-9]{0,4})\/$/;

function viewerLocale() {
  // de_CH / en_GB style regions collapse to the base language.
  return String(I18n.locale || "en")
    .split(/[_-]/)[0]
    .toLowerCase();
}

// Provenance check for legacy posts that were baked before any marker
// existed: the linkifier's anchor text is exactly the typed RX code, and the
// id in the text equals the id in the href. Author-typed rumx.com links carry
// UTM (so they fail RX_HREF) and free text. Read only the anchor's own text
// nodes: core may decorate the anchor with extra child elements.
function ownText(anchor) {
  return Array.from(anchor.childNodes)
    .filter((node) => node.nodeType === Node.TEXT_NODE)
    .map((node) => node.textContent)
    .join("")
    .trim()
    .toUpperCase();
}

export default {
  name: "rumx-rx-locale",

  initialize() {
    withPluginApi((api) => {
      api.decorateCookedElement(
        (element) => {
          const locale = viewerLocale();
          if (!REWRITE_LOCALES.has(locale)) {
            return;
          }

          element
            .querySelectorAll('a[href^="https://rumx.com/en/rums/"]')
            .forEach((anchor) => {
              const match = RX_HREF.exec(anchor.getAttribute("href"));
              if (!match || ownText(anchor) !== `RX${match[1]}`) {
                return;
              }
              anchor.setAttribute(
                "href",
                `https://rumx.com/${locale}/rums/${match[1]}/`
              );
            });
        },
        { id: "rumx-rx-locale" }
      );
    });
  },
};
