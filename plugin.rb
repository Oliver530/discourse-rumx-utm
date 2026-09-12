# name: discourse-rumx-utm
# about: Linkifies RXID codes to rumx.com (server-side, crawlable; viewer-locale aware client-side) + adds UTM to external links
# version: 2.1.0
# authors: Oliver Gerhardt
# url: https://github.com/Oliver530/discourse-rumx-utm

after_initialize do
  module ::DiscourseRUMXUTM
    class Engine < ::Rails::Engine
      engine_name "discourse_rumx_utm"
      isolate_namespace DiscourseRUMXUTM
    end

    class UTMProcessor
      require 'uri'
      require 'rack/utils'

      # RX + 1-5 digits, no leading zero. Catalog range verified 1..26189
      # (RX1-RX9 are real rums); {0,4} = 1-5 digits (RX1..RX99999) gives ~4x
      # growth headroom over the current max while rejecting absurd 6+ digit
      # typos that would link to a 404. Lookarounds, not \b: Ruby \b treats "_"
      # as a word char and mishandles URL/email punctuation.
      # (?<![[:alnum:]_]) / (?![[:alnum:]_]) require the match to be a
      # standalone token, so "TRX900", "BRX12", "RX9883abc", "_RX9883" do not
      # match. Case-insensitive: users type rx / Rx / RX.
      RX_REGEX = /(?<![[:alnum:]_])RX([1-9][0-9]{0,4})(?![[:alnum:]_])/i

      # Never linkify inside these. <a> guards idempotency (no nested anchors on
      # rebake); code/pre/etc are verbatim; onebox/quote are not the author's own
      # text. Class checks use token matching, not substring.
      SKIP_ANCESTOR_TAGS    = %w[a code pre script style textarea kbd samp].freeze
      SKIP_ANCESTOR_CLASSES = %w[onebox quote].freeze

      # The exact href linkify_rx_codes emits: canonical /en/, numeric id,
      # trailing slash, no query. Three consumers key on this precise shape and
      # must agree: the UTM pass below (skip), the client-side locale rewrite
      # (assets/javascripts/discourse/initializers/rumx-rx-locale.js) and the
      # click-tracking normalizer (TopicLinkClickExtension, bottom of file).
      RX_LINK_HREF = %r{\Ahttps://rumx\.com/en/rums/[1-9][0-9]{0,4}/\z}

      # ---- Pass 1: UTM on existing/author-typed external links (runs FIRST) ----
      # Because linkify runs AFTER this, the RX links we generate below are NOT
      # seen here on a fresh cook and stay clean (no UTM) — intentional, for
      # machine readability. Not every run is a fresh cook, though: a post
      # localization can be re-processed from its STORED cooked HTML
      # (Jobs::ProcessLocalizedCooked without recook, e.g. hashtag remaps), so
      # this pass can meet anchors an earlier run created. Skip them explicitly;
      # a UTM'd RX link would no longer match RX_LINK_HREF anywhere.
      def self.process(doc)
        doc.css("a").each do |link|
          href = link.get_attribute("href")
          next if href.blank?
          next if href.match?(RX_LINK_HREF)
          link.set_attribute("href", add_utm_params(href)) if external_link?(href)
        end
      end

      # ---- Pass 2: RX codes -> clean rumx.com links (runs AFTER UTM) ----
      def self.linkify_rx_codes(doc)
        # Snapshot to an Array: do not mutate a live NodeSet while iterating.
        doc.xpath(".//text()").to_a.each do |text_node|
          text = text_node.text
          next unless text.match?(RX_REGEX)
          next if skip_text_node?(text_node)

          # Deterministic scan: Regexp#match(text, pos) returns MatchData directly.
          # Do NOT use text.to_enum(:scan, RX_REGEX) + Regexp.last_match — $~ set
          # inside scan's internal block does not reliably propagate through the
          # enumerator's Fiber, so last_match can be nil/stale and skip matches
          # intermittently. (Observed: ~3/7589 posts silently unlinked on rebake.)
          replacements = []
          last = 0
          pos = 0
          while (m = RX_REGEX.match(text, pos))
            s, e = m.begin(0), m.end(0)
            replacements << Nokogiri::XML::Text.new(text[last...s], text_node.document) if s > last
            a = Nokogiri::XML::Node.new("a", text_node.document)
            a["href"] = "https://rumx.com/en/rums/#{m[1]}/" # stable ID-URL, no slug, no UTM
            a.content = m[0]                                # anchor = exactly as typed (auto-escaped)
            replacements << a
            last = e
            pos = (e == s ? e + 1 : e) # guard against zero-width (defensive)
          end
          replacements << Nokogiri::XML::Text.new(text[last..], text_node.document) if last < text.length

          # Insert siblings before the original node, then drop it. Sibling-insert
          # adopts nodes into the existing parent/document (more version-robust
          # than building a separate DocumentFragment and replacing).
          replacements.each { |node| text_node.add_previous_sibling(node) }
          text_node.remove
        end
      end

      def self.skip_text_node?(node)
        node.ancestors.any? do |anc|
          next false unless anc.element?
          classes = anc["class"].to_s.split
          SKIP_ANCESTOR_TAGS.include?(anc.name.downcase) ||
            (SKIP_ANCESTOR_CLASSES & classes).any?
        end
      end

      def self.external_link?(href)
        begin
          uri = URI.parse(href)
        rescue StandardError
          # URI.parse raises a family of errors on malformed hrefs:
          # URI::InvalidURIError AND URI::InvalidComponentError (siblings, not
          # parent/child) plus ArgumentError on some inputs. A user-posted
          # malformed mailto (e.g. "mailto:W.k,1985@gmx.de") raised an
          # uncaught InvalidComponentError here, aborting the whole
          # post_process_cooked handler and silently skipping RX linkify for
          # the entire post. Rescue broadly: an unparseable href is simply
          # treated as not-external (skip), never crashes the pipeline.
          return false
        end
        return false if uri.host.blank?
        # Only ever touch http(s). Defense-in-depth against odd schemes that
        # still carry a host (e.g. javascript://host/...). Discourse sanitizes
        # cooked hrefs, but we never want to rewrite a non-web scheme.
        return false unless %w[http https].include?(uri.scheme&.downcase)
        begin
          current_host = URI.parse(Discourse.base_url).host
        rescue
          current_host = ""
        end
        uri.host != current_host
      end

      def self.add_utm_params(url)
        # Method-level rescue covers the WHOLE body, not just URI.parse:
        # Rack::Utils.parse_nested_query raises Rack::QueryParser errors (NOT a
        # URI::Error) on malformed/adversarial query strings like
        # "?a=1&a[b]=2". An uncaught error here aborts the entire
        # post_process_cooked handler before linkify runs (same failure mode as
        # the v2.0.2 mailto bug). Any failure: return the href untouched.
        uri = URI.parse(url)
        own_site = canonicalize_rumx!(uri)
        params = Rack::Utils.parse_nested_query(uri.query)
        forum_utm = {
          "utm_source"   => "rumx",
          "utm_medium"   => "referral",
          "utm_campaign" => "rumx-forum"
        }
        if own_site
          # rumx.com links that already carry UTM were tagged on purpose by our
          # own tooling (the Market Radar bot posts utm_campaign=market_radar).
          # Overwriting those replaced the campaign with "rumx-forum" and left
          # only utm_content behind, so GA4 never saw the Market Radar traffic
          # as such. Fill in whatever is missing, never replace what is there.
          params = forum_utm.merge(params)
        else
          # External shops: the forum is the referrer, forum attribution wins.
          params.merge!(forum_utm)
        end
        uri.query = Rack::Utils.build_nested_query(params)
        uri.to_s
      rescue StandardError
        url
      end

      # Canonicalize author-typed rumx.com links to match the site's canonical
      # form (and the clean form the RX auto-linker emits): strip the "www."
      # host prefix and ensure a trailing slash on non-file paths. rumx.com
      # (Hugo) serves trailing-slash URLs and 301s www -> apex, so this only
      # removes a redirect hop and keeps forum links consistent. Mutates uri
      # in place; no-op for non-rumx hosts. Only the UTM pass calls this, so
      # the RX auto-links (created after, already canonical) are untouched.
      # Returns true when the host is rumx.com (own site), false otherwise.
      def self.canonicalize_rumx!(uri)
        return false unless uri.host
        host = uri.host.downcase
        return false unless host == "rumx.com" || host == "www.rumx.com"
        uri.host = "rumx.com"
        path = uri.path.to_s
        if path.empty?
          uri.path = "/" # https://rumx.com -> https://rumx.com/
        elsif !path.end_with?("/") && !File.basename(path).include?(".")
          uri.path = path + "/" # skip files like /sitemap.xml, /img/x.jpg
        end
        true
      end
    end

    # The client rewrites RX anchors to the viewer's locale (/de/, /fr/ — see
    # assets/javascripts/discourse/initializers/rumx-rx-locale.js), but the
    # TopicLink rows are extracted from the STORED cooked HTML and hold the
    # canonical /en/ href. TopicLinkClick.create_from looks the clicked URL up
    # by scheme/query variants only, never by path, so a /de/ click would find
    # no row and silently go uncounted: the per-link click badge in the post
    # and topic_link_clicks would stop seeing DE/FR readers (26% of RX clicks
    # in the 90 days before 2026-09-12). Normalize back to /en/ before the
    # lookup — unless the post genuinely holds that exact /de|fr/ link (an
    # author-typed one; today all of those carry UTM and never match).
    #
    # Return value: core returns the URL it matched (or nil); ClicksController
    # ignores it, so handing back the /en/ form changes nothing observable.
    # If core ever renames create_from this override becomes dead code and
    # DE/FR clicks go uncounted again — a stats regression, never a broken
    # page. Verify after major upgrades: click an RX link as a non-author with
    # DE selected, then check TopicLinkClick for that link (24h rate limit per
    # user/link applies, so use a fresh pair).
    module TopicLinkClickExtension
      RX_LOCALE_HREF = %r{\Ahttps://rumx\.com/(?:de|fr)/rums/([1-9][0-9]{0,4})/\z}

      def create_from(args = {})
        url = args[:url]
        match = url.is_a?(String) ? RX_LOCALE_HREF.match(url) : nil
        return super unless match
        if args[:post_id].present? && ::TopicLink.exists?(post_id: args[:post_id], url: url)
          return super
        end
        super(args.merge(url: "https://rumx.com/en/rums/#{match[1]}/"))
      end
    end
  end

  ::TopicLinkClick.singleton_class.prepend(::DiscourseRUMXUTM::TopicLinkClickExtension)

  # Order matters: UTM first (touches author-typed links), then RX-linkify
  # (creates clean, UTM-free identifier links).
  on(:post_process_cooked) do |doc, post|
    ::DiscourseRUMXUTM::UTMProcessor.process(doc)
    ::DiscourseRUMXUTM::UTMProcessor.linkify_rx_codes(doc)
  end

  # Translated posts (content localization / Discourse AI translation) are
  # cooked separately from the original: LocalizedCookedPostProcessor fires
  # THIS event, never :post_process_cooked. Without it every localized post
  # lost its RX links (0 of 14 linked on 2026-09-12) — exactly the posts DE/FR
  # readers see. Same two passes, same canonical /en/ href: the locale is
  # applied client-side from the viewer's setting, not from the translation's
  # language (a DE reader can be shown an untranslated EN original).
  on(:post_process_localized_cooked) do |doc, post, localization|
    ::DiscourseRUMXUTM::UTMProcessor.process(doc)
    ::DiscourseRUMXUTM::UTMProcessor.linkify_rx_codes(doc)
  end
end
