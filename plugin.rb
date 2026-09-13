# name: discourse-rumx-utm
# about: Linkifies RXID codes to rumx.com (server-side, crawlable; viewer-locale aware client-side) + adds UTM to external links + keeps AI translations fresh
# version: 2.3.0
# authors: Oliver Gerhardt
# url: https://github.com/Oliver530/discourse-rumx-utm

register_asset "stylesheets/common/rumx-translation-label.scss"

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

    # ---- Translation freshness (content localization + Discourse AI) ----
    #
    # Core shows a reader the stored translation of a post whenever one exists
    # for their locale, with NO check that it still matches the post: after an
    # edit, ContentLocalization.translated_post_cooked keeps serving the old
    # localization and only flips a tooltip ("translation may be outdated").
    # Discourse AI re-translates at most MAX_QUOTA_PER_DAY times per post and
    # locale, and its backfill only fills MISSING locales, never stale ones. On
    # bottle-split posts (participant lists edited 5-15x a day) that meant DE/FR
    # readers — including the organiser reading the forum in German — saw a
    # participant list several versions old for the rest of the day
    # (2026-09-13: 29 stale localizations on 14 posts, nearly all splits).
    #
    # Freshness is decided by the SOURCE TEXT that was translated, not by
    # post.version: PostRevisor folds small edits by the same author within
    # editing_grace_period (5 min, <= 100 chars diff) into the previous revision
    # without bumping version — exactly the "add one participant" edit. Every AI
    # translation therefore records an MD5 of the raw it translated, per
    # (post, locale), in a post custom field; a translation is fresh only while
    # that digest equals the current raw. MD5 rather than SHA1 so the
    # reconciler can evaluate the same predicate in SQL (Postgres md5()).
    # Translations made before this version carry no digest and fall back to
    # the version comparison until they are re-translated once.
    #
    # Three parts: (1) hide a stale translation and serve the original,
    # (2) record the digest under a per-post/locale lock and skip pointless
    # re-translations, (3) a scheduled job that re-translates whatever the
    # exact SQL predicate finds stale, regardless of Discourse AI's daily
    # quota, so "original until the fresh translation lands" is bounded even
    # when the author never edits again or an LLM call failed (retry: false in
    # core). Bound: QUIET_PERIOD + up to one 15-min schedule + LLM time, plus
    # backlog at MAX_PER_RUN per run — typically ~10-20 min, not seconds.
    module TranslationFreshness
      FIELD_PREFIX = "rumx_localized_src_md5_"

      def self.supported_locales
        SiteSetting.content_localization_supported_locales.to_s.split("|").map(&:strip).reject(&:blank?)
      end

      def self.field_name(locale)
        "#{FIELD_PREFIX}#{locale.to_s.sub("-", "_")}"
      end

      def self.digest(raw)
        Digest::MD5.hexdigest(raw.to_s)
      end

      def self.lock_key(post, locale)
        "rumx_localize_#{post.id}_#{locale}"
      end

      # Preload-safe: TopicView hands posts a PreloadedProxy that RAISES for
      # any key outside the allowlist (an admin-made localization in a locale
      # that is not a configured one, say). Unknown means "no digest" — the
      # version comparison then decides. Duplicate rows (a past race) come
      # back as an Array; record! keeps the oldest row, so mirror that here.
      def self.stored_digest(post, locale)
        name = field_name(locale)
        return nil if post.custom_fields_preloaded? && !post.custom_field_preloaded?(name)
        value = post.custom_fields[name]
        value = value.first if value.is_a?(Array)
        value.presence
      rescue ::HasCustomFields::NotPreloadedError
        nil
      end

      # true = digest matches the current raw, false = differs, nil = no digest
      def self.digest_state(post, locale)
        stored = stored_digest(post, locale)
        return nil if stored.nil?
        stored == digest(post.raw)
      end

      def self.fresh?(post, localization)
        state = digest_state(post, localization.locale)
        return localization.post_version == post.version if state.nil?
        state
      end

      # One row per (post, locale), written directly. NOT post.save_custom_fields:
      # that writes the whole in-memory hash back and DELETES fields it does not
      # know about, so two processes translating de and fr of the same post at
      # the same moment could wipe each other's digest. Extra rows from any
      # past race are removed here, otherwise core reads them as an Array and
      # the digest would compare unequal forever. Only the process-local cache
      # is cleared (never the TopicView preload proxy).
      def self.record!(post, locale, digest_value)
        name = field_name(locale)
        rows = ::PostCustomField.where(post_id: post.id, name: name).order(:id).to_a
        keep = rows.shift || ::PostCustomField.new(post_id: post.id, name: name)
        rows.each(&:destroy!)
        keep.value = digest_value
        keep.save!
        post.clear_custom_fields unless post.custom_fields_preloaded?
      end
    end

    # (1) Serve the original instead of a stale translation. Every consumer
    # (cooked, excerpt, is_localized flag, localized oneboxes) goes through
    # this predicate, so the UI stays consistent: an unshown translation also
    # shows no language icon. Not covered on purpose: topic-list excerpts and
    # e-mails read the topic localization / post directly in core.
    module ContentLocalizationExtension
      def show_translated_post?(post, scope)
        return false unless super

        localization = post.get_localization
        return false if localization && !TranslationFreshness.fresh?(post, localization)

        true
      end
    end

    # (2) Discourse AI's PostLocalizer.
    #
    # localize: one writer per (post, locale) at a time (DistributedMutex —
    # core's on-edit job and the reconciler below are different job classes,
    # cluster_concurrency does not serialize them against each other), the
    # post re-read inside the lock so the LLM gets what is in the DB now and
    # not what the caller loaded minutes ago, the digest computed BEFORE super
    # from that same string, and translation + digest written back to back.
    # No "already fresh, skip" short-circuit here: a forced manual
    # re-translation of a bad (e.g. truncated) translation must still run.
    #
    # has_relocalize_quota?: a localization whose digest already matches the
    # current raw needs no quota — returning false makes Jobs::DetectTranslatePost
    # skip it (`next if !force && exists && !has_quota`) without spending an
    # increment. N saves inside the grace period enqueue N re-translation jobs
    # five minutes later; only the first meets changed text. `force` and the
    # missing-localization branch are untouched, as in core. Overloaded
    # contract, kept deliberately narrow (Post instances, present locale).
    module PostLocalizerExtension
      LOCK_VALIDITY_SECONDS = 120 # an LLM call takes ~5-10 s; the lock must outlive a slow one

      # A translation shorter than half its source (for sources longer than
      # 300 chars) is discarded: Claude Haiku 4.5 reproducibly closes the
      # structured-output JSON at a German closing quote („…") and stops —
      # post 298979 came back at 17% of its length on five attempts. The
      # reader gets the original instead of a fragment. The digest is still
      # recorded, so nothing retries the same text (on-edit dedupe, backfill
      # skip, reconciler sees no row); the next real edit translates again.
      # Calibrated on 114 long translations: p5 of the length ratio was 0.9,
      # median 1.06, the truncated one 0.17.
      MIN_SOURCE_LENGTH_FOR_GUARD = 300
      MIN_LENGTH_RATIO = 0.5

      def localize(post, target_locale = I18n.locale, llm_model: nil)
        return super if post.blank?
        locale = target_locale.to_s.sub("-", "_")

        ::DistributedMutex.synchronize(
          TranslationFreshness.lock_key(post, locale),
          validity: LOCK_VALIDITY_SECONDS,
        ) do
          post.reload
          source_raw = post.raw.to_s
          source_digest = TranslationFreshness.digest(source_raw)
          localization = super(post, target_locale, llm_model: llm_model)
          next nil if localization.nil?

          TranslationFreshness.record!(post, localization.locale, source_digest)
          if implausibly_short?(source_raw, localization.raw)
            Rails.logger.warn(
              "discourse-rumx-utm: translation of post #{post.id} to #{localization.locale} is " \
                "#{localization.raw.to_s.length}/#{source_raw.length} chars of the source — discarded, " \
                "readers see the original until the post is edited",
            )
            localization.destroy!
            next nil
          end
          localization
        end
      end

      def implausibly_short?(source_raw, translated_raw)
        return false if source_raw.length <= MIN_SOURCE_LENGTH_FOR_GUARD
        translated_raw.to_s.length < MIN_LENGTH_RATIO * source_raw.length
      end

      def has_relocalize_quota?(model, locale, skip_incr: false)
        if model.is_a?(::Post) && locale.present? &&
             TranslationFreshness.digest_state(model, locale) == true
          return false
        end
        super
      end
    end
  end

  ::TopicLinkClick.singleton_class.prepend(::DiscourseRUMXUTM::TopicLinkClickExtension)
  ::ContentLocalization.singleton_class.prepend(::DiscourseRUMXUTM::ContentLocalizationExtension)

  # Digest fields: typed so values round-trip as strings, allowlisted so
  # TopicView preloads them with the posts (no per-post query in the hot
  # predicate above). The allowlist block re-reads the setting per request;
  # the type registration happens once at boot (an unregistered name would
  # default to :string anyway).
  ::DiscourseRUMXUTM::TranslationFreshness.supported_locales.each do |locale|
    register_post_custom_field_type(::DiscourseRUMXUTM::TranslationFreshness.field_name(locale), :string)
  end
  ::TopicView.add_post_custom_fields_allowlister do |_user, _topic|
    ::DiscourseRUMXUTM::TranslationFreshness.supported_locales.map do |locale|
      ::DiscourseRUMXUTM::TranslationFreshness.field_name(locale)
    end
  end

  if defined?(::DiscourseAi::Translation::PostLocalizer)
    ::DiscourseAi::Translation::PostLocalizer.singleton_class.prepend(
      ::DiscourseRUMXUTM::PostLocalizerExtension,
    )

    # Discourse AI caps re-translations at MAX_QUOTA_PER_DAY = 2 per post and
    # locale (lib/translation/localizable_quota.rb) — a constant, not a site
    # setting. The digest dedupe above keeps on-edit re-translations bounded by
    # real text changes, so 20 is a ceiling for a busy split day, not a budget:
    # a re-translation of a ~1,000-char post costs about 0.6 cent on Haiku 4.5.
    # The constant is read at call time inside has_relocalize_quota?, so
    # replacing it here (plugins load alphabetically, discourse-ai before
    # discourse-rumx-utm) is enough. It applies to topics/categories through
    # the same concern; those are re-localized rarely (title edits).
    quota = ::DiscourseAi::Translation::LocalizableQuota
    if quota.const_defined?(:MAX_QUOTA_PER_DAY, false)
      quota.send(:remove_const, :MAX_QUOTA_PER_DAY)
      quota.const_set(:MAX_QUOTA_PER_DAY, 20)
    else
      Rails.logger.warn(
        "discourse-rumx-utm: DiscourseAi::Translation::LocalizableQuota::MAX_QUOTA_PER_DAY " \
          "not found — re-translation quota left at the discourse-ai default",
      )
    end

    # (3) Reconcile stale localizations. Core has no path that refreshes an
    # existing translation except the on-edit job (quota-limited, retry:
    # false), so without this a reader could see the original indefinitely
    # once rule (1) hides a stale translation. The candidate query is the
    # EXACT staleness predicate in SQL (digest <> md5(raw), or version behind
    # for legacy rows without a digest) — no timestamp pre-filter, which would
    # miss a translation that finished after a same-version edit — ordered by
    # translation age so every stale row is reached (no starvation). Posts
    # saved in the last QUIET_PERIOD are left to the on-edit job (+5 min).
    # Eligibility follows Discourse AI's own rules per row (category scope,
    # personal messages, bot content, configured target locales) but without
    # its backfill date cutoff: any post that has a translation gets to keep it
    # fresh. MAX_PER_RUN counts ATTEMPTS, credits are checked before each one,
    # and open readers are told via the same MessageBus event core publishes.
    # `post_ids:` narrows a run (ops: refresh these now; also used by tests).
    class ::Jobs::RumxRefreshStaleLocalizations < ::Jobs::Scheduled
      every 15.minutes
      sidekiq_options retry: false
      cluster_concurrency 1

      MAX_PER_RUN = 12
      QUIET_PERIOD = 6.minutes

      STALE_SQL = <<~SQL
        SELECT pl.id
        FROM post_localizations pl
        JOIN posts p ON p.id = pl.post_id
        JOIN topics t ON t.id = p.topic_id
        WHERE p.deleted_at IS NULL
          AND t.deleted_at IS NULL
          AND p.raw IS NOT NULL AND p.raw <> ''
          AND p.updated_at < :quiet_before
          AND (:include_bots OR p.user_id > 0)
          AND (:include_pms OR t.archetype <> 'private_message')
          AND (:post_ids_filter OR p.id IN (:post_ids))
          AND split_part(replace(pl.locale, '-', '_'), '_', 1)
              <> split_part(replace(coalesce(p.locale, ''), '-', '_'), '_', 1)
          AND (
            CASE
              WHEN (SELECT value FROM post_custom_fields
                    WHERE post_id = p.id AND name = :field_prefix || replace(pl.locale, '-', '_')
                    ORDER BY id LIMIT 1) IS NULL
              THEN pl.post_version <> p.version
              ELSE (SELECT value FROM post_custom_fields
                    WHERE post_id = p.id AND name = :field_prefix || replace(pl.locale, '-', '_')
                    ORDER BY id LIMIT 1) <> md5(p.raw)
            END
          )
        ORDER BY pl.updated_at ASC, pl.id ASC
        LIMIT :limit
      SQL

      def self.stale_localization_ids(limit:, post_ids: nil)
        DB.query_single(
          STALE_SQL,
          quiet_before: QUIET_PERIOD.ago,
          include_bots: SiteSetting.ai_translation_include_bot_content,
          include_pms: SiteSetting.ai_translation_personal_messages != "none",
          post_ids_filter: post_ids.blank?,
          post_ids: Array(post_ids).presence || [-1],
          field_prefix: ::DiscourseRUMXUTM::TranslationFreshness::FIELD_PREFIX,
          limit: limit,
        )
      end

      def execute(args = {})
        return if !SiteSetting.content_localization_enabled
        return if !defined?(::DiscourseAi::Translation) || !::DiscourseAi::Translation.enabled?
        unless ::DiscourseAi::Translation.respond_to?(:credits_available_for_post_localization?)
          Rails.logger.warn("discourse-rumx-utm: credits_available_for_post_localization? missing — stale-localization refresh skipped")
          return
        end

        targets = ::DiscourseAi::Translation.locales.map { |l| l.to_s.split("_").first }
        ids = self.class.stale_localization_ids(limit: MAX_PER_RUN * 3, post_ids: args[:post_ids])
        attempts = 0
        refreshed = []

        ::PostLocalization.where(id: ids).order(:updated_at, :id).includes(post: :topic).each do |localization|
          break if attempts >= MAX_PER_RUN
          post = localization.post
          next if post.nil? || post.topic.nil?
          next if !targets.include?(localization.locale.to_s.split("_").first)
          next if !eligible?(post)
          break if !::DiscourseAi::Translation.credits_available_for_post_localization?

          attempts += 1
          begin
            result = ::DiscourseAi::Translation::PostLocalizer.localize(post, localization.locale)
            next if result.nil?
            refreshed << "#{post.id}:#{localization.locale}"
            MessageBus.publish(
              "/topic/#{post.topic_id}",
              { type: :localized, id: post.id },
              post.topic.secure_audience_publish_messages,
            )
          rescue => e
            Rails.logger.warn(
              "discourse-rumx-utm: refresh of stale localization failed for post #{post.id} " \
                "(#{localization.locale}): #{e.class}: #{e.message}",
            )
          end
        end

        if refreshed.any?
          Rails.logger.info(
            "discourse-rumx-utm: re-translated #{refreshed.size} stale localization(s) " \
              "(#{attempts} attempts): #{refreshed.join(", ")}",
          )
        end
        { attempts: attempts, refreshed: refreshed }
      end

      private

      # Mirrors the non-forced branch of Jobs::DetectTranslatePost.
      def eligible?(post)
        topic = post.topic
        if topic.archetype == Archetype.private_message
          case SiteSetting.ai_translation_personal_messages
          when "all" then true
          when "group" then ::TopicAllowedGroup.exists?(topic_id: topic.id)
          else false
          end
        else
          ::DiscourseAi::Translation.category_allowed?(topic.category)
        end
      end
    end
  else
    Rails.logger.warn("discourse-rumx-utm: discourse-ai not loaded — translation freshness runs with the version check only")
  end

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
